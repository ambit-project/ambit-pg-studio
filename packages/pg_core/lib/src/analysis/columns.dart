// Column uses (2.0 spec 005): which column of which table or view a name in a statement means, from the tokens of
// each statement and its FROM/JOIN/UPDATE/INTO aliases. Runs after linking (it needs the columns of relations).
import '../index/project_index.dart';
import '../liquibase.dart';
import '../model.dart';
import '../pg_query/pg_query.dart';
import 'tokens.dart';

final class ColumnUse {
  const ColumnUse(this.relation, this.column, this.span, this.kind, this.from);

  /// The table or view the column belongs to.
  final ObjectKey relation;
  final String column;
  final SourceSpan span;

  /// read or write (INSERT column lists, UPDATE ... SET targets).
  final RefKind kind;

  /// The object whose definition contains the use.
  final ObjectKey? from;
}

const _relationStarts = {'from', 'join', 'update', 'into', 'using'};
const _fromEnds = {
  'where',
  'group',
  'order',
  'limit',
  'offset',
  'having',
  'window',
  'union',
  'returning',
  'on',
  'set',
  'for',
  'values',
  'select',
  'intersect',
  'except',
};
const _notAliases = {
  'where',
  'join',
  'left',
  'right',
  'inner',
  'full',
  'cross',
  'on',
  'using',
  'set',
  'group',
  'order',
  'limit',
  'for',
  'values',
  'returning',
  'natural',
  'select',
  'union',
  'having',
  'window',
  'with',
  'default',
  'as',
  'offset',
  'lateral',
  'and',
  'or',
  'not',
  'into',
  'from',
  'outer',
  'intersect',
  'except',
};

/// Every column use of the project.
List<ColumnUse> findColumnUses(ProjectIndex index) {
  final byName = <String, List<DbObject>>{};
  for (final o in index.objects.values) {
    if (o.key.space != ObjectSpace.relation || o.columns.isEmpty) continue;
    (byName[o.key.qualified] ??= []).add(o);
    (byName[o.key.name] ??= []).add(o);
  }
  final out = <ColumnUse>[];
  for (final path in index.order) {
    final file = index.files[path];
    if (file == null || file.text.isEmpty) continue;
    final prepared = prepareSql(file.text).sql;
    _region(index, byName, path, prepared, 0, out, const {}, 0);
  }
  return out;
}

void _region(
  ProjectIndex index,
  Map<String, List<DbObject>> byName,
  String path,
  String text,
  int base,
  List<ColumnUse> out,
  Set<String> outerVariables,
  int depth,
) {
  String? error;
  final all = PgQuery.scan(text, onError: (e) => error = e.message);
  if (error != null) return;
  final tt = TokenText(text, all);
  final tokens = tt.tokens;
  // Variables of a PL/pgSQL body: DECLARE names, FOR/FOREACH loop names (never columns).
  final variables = {...outerVariables};
  var inDeclare = false;
  var statementStart = true;
  for (var i = 0; i < tokens.length; i++) {
    final w = tt.textOf(tokens[i]).toLowerCase();
    if (w == 'declare') inDeclare = true;
    if (w == 'begin') inDeclare = false;
    if (inDeclare && statementStart && tokens[i].name == 'IDENT') variables.add(tt.nameOf(tokens[i]));
    if ((w == 'for' || w == 'foreach') && i + 1 < tokens.length && tokens[i + 1].name == 'IDENT') {
      variables.add(tt.nameOf(tokens[i + 1]));
    }
    statementStart = w == ';' || w == 'declare';
  }
  // Dollar-quoted bodies are regions of their own (with the routine's parameters as variables).
  for (final t in tokens) {
    final raw = tt.textOf(t);
    if (t.name == 'SCONST' && raw.startsWith(r'$') && depth < 3) {
      final tag = raw.substring(0, raw.indexOf(r'$', 1) + 1);
      if (raw.length < tag.length * 2) continue;
      final bodyStart = base + t.start + tag.length;
      final def = index.enclosingDefinition(path, bodyStart);
      final params = {for (final p in def?.parameters ?? const <ParameterInfo>[]) ?p.name};
      _region(
        index,
        byName,
        path,
        raw.substring(tag.length, raw.length - tag.length),
        bodyStart,
        out,
        params,
        depth + 1,
      );
    }
  }
  // Statements: split at ';' (and at PL/pgSQL block words, which are never inside a SQL statement).
  var start = 0;
  for (var i = 0; i <= tokens.length; i++) {
    final end =
        i == tokens.length ||
        tt.textOf(tokens[i]) == ';' ||
        const {'begin', 'then', 'loop', 'else', 'declare', 'exception'}.contains(tt.textOf(tokens[i]).toLowerCase());
    if (!end) continue;
    if (i > start) _statement(index, byName, path, tt, start, i, base, out, variables);
    start = i + 1;
  }
}

void _statement(
  ProjectIndex index,
  Map<String, List<DbObject>> byName,
  String path,
  TokenText tt,
  int from,
  int to,
  int base,
  List<ColumnUse> out,
  Set<String> variables,
) {
  final tokens = tt.tokens;
  String word(int i) => i < to && i >= from ? tt.textOf(tokens[i]).toLowerCase() : '';
  DbObject? resolve(List<String> parts) {
    final key = parts.join('.');
    final found = byName[key];
    if (found == null || found.isEmpty) return null;
    if (parts.length == 1 && found.length > 1) return null; // the same name in two schemas: ambiguous
    return found.first;
  }

  // 1. Relations of the statement and their aliases.
  final aliases = <String, DbObject>{};
  final relations = <DbObject>{};
  final consumed = <int>{};
  var inFrom = false;
  var verb = '';
  for (var i = from; i < to; i++) {
    final w = word(i);
    if (verb.isEmpty &&
        const {'select', 'insert', 'update', 'delete', 'merge', 'with', 'perform', 'return'}.contains(w)) {
      verb = w;
    }
    if (_fromEnds.contains(w)) inFrom = false;
    final opens = _relationStarts.contains(w) || (w == ',' && inFrom);
    if (w == 'from') inFrom = true;
    if (!opens) continue;
    final run = tt.qualifiedAt(i + 1);
    if (run == null || run.last >= to) continue;
    final rel = resolve(run.parts);
    if (rel == null) continue;
    relations.add(rel);
    for (var k = run.first; k <= run.last; k++) {
      consumed.add(k);
    }
    aliases[run.parts.last] = rel;
    aliases[run.parts.join('.')] = rel;
    var a = run.last + 1;
    if (word(a) == 'as') a++;
    if (a < to && tt.isName(tokens[a]) && !_notAliases.contains(word(a)) && tt.textOf(tokens[a]) != '(') {
      aliases[tt.nameOf(tokens[a])] = rel;
      consumed.add(a);
      if (a > run.last + 1) consumed.add(a - 1);
    }
    // INSERT INTO t (a, b): the columns written.
    if (w == 'into' && verb == 'insert' && run.last + 1 < to && tt.textOf(tokens[run.last + 1]) == '(') {
      final close = tt.matchingParen(run.last + 1);
      for (var k = run.last + 2; k < close && k < to; k++) {
        if (tokens[k].name == 'IDENT' || tt.isName(tokens[k])) {
          _add(out, rel, tt.nameOf(tokens[k]), path, base, tokens[k], RefKind.write, index);
          consumed.add(k);
        }
      }
    }
  }
  if (relations.isEmpty) return;

  // 2. UPDATE ... SET a = ..., b = ...: the columns written.
  if (verb == 'update') {
    final target = relations.first;
    var inSet = false;
    var depth = 0;
    for (var i = from; i < to; i++) {
      final s = tt.textOf(tokens[i]);
      final w = s.toLowerCase();
      if (s == '(') depth++;
      if (s == ')') depth--;
      if (w == 'set' && depth == 0) {
        inSet = true;
        continue;
      }
      if (depth == 0 && const {'where', 'from', 'returning'}.contains(w)) inSet = false;
      if (!inSet || depth != 0 || !tt.isName(tokens[i])) continue;
      final prev = i > from ? tt.textOf(tokens[i - 1]) : '';
      if ((prev == ',' || word(i - 1) == 'set') && word(i + 1) == '=') {
        _add(out, target, tt.nameOf(tokens[i]), path, base, tokens[i], RefKind.write, index);
        consumed.add(i);
      }
    }
  }

  // 3. alias.column and schema.table.column; 4. bare names when one relation of the statement has that column.
  for (var i = from; i < to; i++) {
    if (consumed.contains(i) || !tt.isName(tokens[i])) continue;
    if (i > from && tt.isSymbol(tokens[i - 1], '.')) continue;
    final run = tt.qualifiedAt(i);
    if (run == null || run.last >= to) continue;
    final next = run.last + 1 < to ? tt.textOf(tokens[run.last + 1]) : '';
    if (next == '(' || next == '%') {
      i = run.last;
      continue;
    }
    if (run.parts.length >= 2) {
      final rel = aliases[run.parts.sublist(0, run.parts.length - 1).join('.')];
      if (rel != null) _add(out, rel, run.parts.last, path, base, tokens[run.last], RefKind.read, index);
      i = run.last;
      continue;
    }
    final name = run.parts.single;
    if (tokens[i].name != 'IDENT' || variables.contains(name) || aliases.containsKey(name)) continue;
    if (i > from && word(i - 1) == 'as') continue; // an output name
    final owners = [
      for (final r in relations)
        if (r.columns.any((c) => c.name == name)) r,
    ];
    if (owners.length == 1) _add(out, owners.single, name, path, base, tokens[i], RefKind.read, index);
  }
}

void _add(
  List<ColumnUse> out,
  DbObject rel,
  String column,
  String path,
  int base,
  PgToken t,
  RefKind kind,
  ProjectIndex index,
) {
  if (!rel.columns.any((c) => c.name == column)) return;
  final span = SourceSpan(path, base + t.start, base + t.end);
  out.add(ColumnUse(rel.key, column, span, kind, index.enclosingDefinition(path, span.start)?.key));
}
