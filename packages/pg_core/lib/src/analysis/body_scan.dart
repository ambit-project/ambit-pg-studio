// References and error codes in a PL/pgSQL body from its tokens. The PL/pgSQL tree of libpg_query has no positions
// of expressions, so the body is read token by token with the clause it is in (ADR 0002).
import '../model.dart';
import 'tokens.dart';

const _keywords = {
  'select',
  'insert',
  'update',
  'delete',
  'merge',
  'truncate',
  'perform',
  'call',
  'from',
  'join',
  'into',
  'table',
  'only',
  'using',
  'declare',
  'begin',
  'then',
  'else',
  'elsif',
  'loop',
  'end',
  'for',
  'return',
  'returning',
  'set',
  'where',
  'values',
  'on',
  'and',
  'or',
  'not',
  'in',
  'is',
  'as',
  'with',
  'exception',
  'when',
  'raise',
  'if',
  'case',
  'lateral',
  'exists',
  'distinct',
  'group',
  'order',
  'by',
  'having',
  'limit',
  'offset',
  'union',
  'except',
  'intersect',
  'execute',
  'foreach',
  'while',
  'array',
  'get',
  'diagnostics',
  'null',
  'true',
  'false',
  'constant',
  'default',
  'strict',
  'left',
  'right',
  'inner',
  'outer',
  'full',
  'cross',
  'natural',
  'any',
  'all',
  'some',
};

const _verbs = {'select', 'insert', 'update', 'delete', 'merge', 'truncate', 'perform', 'call', 'return'};
const _statementBreaks = {';', 'begin', 'then', 'else', 'elsif', 'loop', 'declare'};
const _relationClauses = {'from', 'join', 'into', 'update', 'table', 'only', 'using', 'truncate'};

final class BodyScanResult {
  final List<Reference> references = [];
  final List<ErrorCodeUse> errorCodes = [];
}

/// Scans [body] (the text between the dollar quotes) whose first character is at [bodyOffset] of [file].
BodyScanResult scanPlpgsqlBody({
  required String body,
  required int bodyOffset,
  required String file,
  required ObjectKey? from,
  required List<String> searchPath,
  bool dynamic = false,
}) {
  final result = BodyScanResult();
  final tt = TokenText.scan(body);
  final tokens = tt.tokens;
  String? verb;
  String? prevWord;
  var inDeclare = false;
  var lastErrcodeEnd = 0;

  SourceSpan span(int start, int end) => SourceSpan(file, bodyOffset + start, bodyOffset + end);

  void add(QualifiedName name, ObjectSpace space, RefKind kind, int start, int end, {bool strict = false, int? args}) {
    if (name.schema == 'pg_catalog' || name.schema == 'information_schema') return;
    result.references.add(
      Reference(
        name: name,
        space: space,
        kind: kind,
        span: span(start, end),
        from: from,
        argCount: args,
        searchPath: searchPath,
        reportUnresolved: !dynamic && strict && name.schema != null,
        dynamic: dynamic,
      ),
    );
  }

  // Dynamic SQL (2.0 spec 012): the constant text of a literal is scanned as SQL at its offsets in the file.
  final scanned = <int>{};
  void scanLiteral(int k) {
    if (dynamic || !scanned.add(k)) return;
    final lit = _literalSql(tt.textOf(tokens[k]));
    if (lit == null) return;
    final inner = scanPlpgsqlBody(
      body: lit.sql,
      bodyOffset: bodyOffset + tokens[k].start + lit.offset,
      file: file,
      from: from,
      searchPath: searchPath,
      dynamic: true,
    );
    result.references.addAll(inner.references);
  }

  var i = 0;
  while (i < tokens.length) {
    final t = tokens[i];
    final word = tt.textOf(t).toLowerCase();

    if (word == 'errcode' &&
        i + 2 < tokens.length &&
        tt.textOf(tokens[i + 1]) == '=' &&
        tokens[i + 2].name == 'SCONST') {
      final literal = tt.textOf(tokens[i + 2]);
      final code = literal.length >= 2 ? literal.substring(1, literal.length - 1) : literal;
      result.errorCodes.add(
        ErrorCodeUse(
          code,
          span(tokens[i + 2].start, tokens[i + 2].end),
          _describe(tt, code, lastErrcodeEnd, t.start),
          from,
        ),
      );
      lastErrcodeEnd = tokens[i + 2].end;
      i += 3;
      continue;
    }

    if (!dynamic && word == 'execute') {
      // EXECUTE 'text' || ... / EXECUTE format('text', ...): every literal up to INTO, USING or the end.
      var depth = 0;
      for (var k = i + 1; k < tokens.length; k++) {
        final s = tt.textOf(tokens[k]);
        final lower = s.toLowerCase();
        if (s == '(') depth++;
        if (s == ')') depth--;
        if (s == ';' || depth < 0 || (depth == 0 && (lower == 'into' || lower == 'using'))) break;
        if (tokens[k].name == 'SCONST' && (depth == 0 || _isFormatArg(tt, k))) scanLiteral(k);
      }
    } else if (!dynamic &&
        word == 'format' &&
        i + 2 < tokens.length &&
        tt.textOf(tokens[i + 1]) == '(' &&
        tokens[i + 2].name == 'SCONST') {
      scanLiteral(i + 2);
    }

    if (_keywords.contains(word) || !tt.isName(t)) {
      if (_statementBreaks.contains(word)) verb = null;
      if (word == 'declare') inDeclare = true;
      if (word == 'begin') inDeclare = false;
      if (_verbs.contains(word) && !(word == 'update' && prevWord == 'for')) verb ??= word;
      if (word == 'insert' || word == 'delete' || word == 'merge' || word == 'truncate') verb = word;
      if (word == 'update' && prevWord != 'for') verb = 'update';
      prevWord = word;
      i++;
      continue;
    }

    if (i > 0 && tt.isSymbol(tokens[i - 1], '.')) {
      prevWord = word;
      i++;
      continue;
    }

    final run = tt.qualifiedAt(i)!;
    final next = run.last + 1 < tokens.length ? tokens[run.last + 1] : null;
    final nextText = next == null ? '' : tt.textOf(next);
    final parts = run.parts;
    final firstPartEnd = parts.length >= 2 ? tokens[run.first + 2].end : tokens[run.first].end;

    // INSERT INTO s.t (columns) / MERGE INTO: a relation with a column list, not a call.
    // `schema.%I` in dynamic SQL: the object name is a parameter.
    if (dynamic && nextText == '.') {
      prevWord = null;
      i = run.last + 1;
      continue;
    }

    final insertTarget = prevWord == 'into' && (verb == 'insert' || verb == 'merge');
    if (nextText == '(' && parts.length <= 2 && !insertTarget) {
      final close = tt.matchingParen(run.last + 1);
      add(
        parts.length == 2 ? QualifiedName(parts[0], parts[1]) : QualifiedName(null, parts[0]),
        ObjectSpace.routine,
        RefKind.call,
        run.start,
        run.end,
        strict: true,
        args: _argCount(tt, run.last + 1, close),
      );
    } else if (nextText == '%' && run.last + 2 < tokens.length) {
      final what = tt.textOf(tokens[run.last + 2]).toLowerCase();
      if (what == 'rowtype' && parts.length >= 2) {
        add(QualifiedName(parts[0], parts[1]), ObjectSpace.type, RefKind.type, run.start, firstPartEnd, strict: true);
      } else if (what == 'type' && parts.length == 3) {
        add(
          QualifiedName(parts[0], parts[1]),
          ObjectSpace.relation,
          RefKind.type,
          run.start,
          firstPartEnd,
          strict: true,
        );
      } else if (what == 'type' && parts.length == 2) {
        add(QualifiedName(null, parts[0]), ObjectSpace.relation, RefKind.type, run.start, tokens[run.first].end);
      }
    } else if (parts.length >= 2 && (prevWord == '::' || inDeclare)) {
      add(QualifiedName(parts[0], parts[1]), ObjectSpace.type, RefKind.type, run.start, firstPartEnd, strict: true);
    } else if (prevWord != null && _relationClauses.contains(prevWord)) {
      final write =
          (prevWord == 'into' && (verb == 'insert' || verb == 'merge')) ||
          (prevWord == 'update' && verb == 'update') ||
          (prevWord == 'from' && verb == 'delete') ||
          verb == 'truncate';
      // SELECT ... INTO target: a variable, not a relation.
      final selectInto = prevWord == 'into' && verb != 'insert' && verb != 'merge';
      if (!selectInto) {
        final name = parts.length >= 2 ? QualifiedName(parts[0], parts[1]) : QualifiedName(null, parts[0]);
        add(name, ObjectSpace.relation, write ? RefKind.write : RefKind.read, run.start, firstPartEnd, strict: true);
      }
    } else if (parts.length >= 2) {
      // alias.column, record.field or schema.object in an expression: only a known schema makes it a reference.
      add(QualifiedName(parts[0], parts[1]), ObjectSpace.relation, RefKind.read, run.start, firstPartEnd);
    }

    prevWord = parts.length == 1 ? word : null;
    i = run.last + 1;
  }
  return result;
}

/// The literal at token [k] is the first argument of `format(`.
bool _isFormatArg(TokenText tt, int k) =>
    k >= 2 && tt.textOf(tt.tokens[k - 1]) == '(' && tt.textOf(tt.tokens[k - 2]).toLowerCase() == 'format';

final _formatSpec = RegExp(r'%(?:%|(?:\d+\$)?-?(?:\d+|\*(?:\d+\$)?)?[sIL])');
final _dollarTag = RegExp(r'^\$([A-Za-z_][A-Za-z0-9_]*)?\$');

/// The SQL inside a string literal with the same length as its text (so offsets map 1:1): `''` becomes `' `
/// (a nested literal stays a literal) and format placeholders (`%I`, `%1$L`, `%s`) become parameters (`$1`).
/// Null for literals that are not plain or dollar quoted (E'...', U&'...').
({String sql, int offset})? _literalSql(String literal) {
  String content;
  int offset;
  if (literal.length >= 2 && literal.startsWith("'") && literal.endsWith("'")) {
    content = literal.substring(1, literal.length - 1).replaceAll("''", "' ");
    offset = 1;
  } else {
    final tag = _dollarTag.firstMatch(literal);
    if (tag == null) return null;
    final open = tag.group(0)!;
    if (literal.length < open.length * 2 || !literal.endsWith(open)) return null;
    content = literal.substring(open.length, literal.length - open.length);
    offset = open.length;
  }
  final sql = content.replaceAllMapped(_formatSpec, (m) {
    final spec = m.group(0)!;
    return spec == '%%' ? '  ' : r'$1'.padRight(spec.length);
  });
  return (sql: sql, offset: offset);
}

int _argCount(TokenText tt, int open, int close) {
  if (close <= open + 1) return 0;
  var depth = 0;
  var count = 1;
  for (var j = open + 1; j < close; j++) {
    final s = tt.textOf(tt.tokens[j]);
    if (s == '(' || s == '[') depth++;
    if (s == ')' || s == ']') depth--;
    if (s == ',' && depth == 0) count++;
  }
  return count;
}

/// The nearest comment before [before] (and after the previous ERRCODE) that mentions [code], e.g.
/// `-- U1445 (404): brak zamówienia ...` or `-- Brak id = wspólny kod U1012 (400).`: its text without the comment marks.
String _describe(TokenText tt, String code, int after, int before) {
  for (final c in tt.comments.reversed) {
    if (c.start >= before || c.end <= after) continue;
    final text = tt.textOf(c);
    if (!text.contains(code)) continue;
    return text.replaceFirst(RegExp(r'^(--|/\*)\s*'), '').replaceFirst(RegExp(r'\s*\*/$'), '').trim();
  }
  return '';
}
