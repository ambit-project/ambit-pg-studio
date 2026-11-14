// Completion while typing (2.0 spec 002): what fits at the cursor, from the index - no database.
import '../index/project_index.dart';
import '../model.dart';

enum CompletionKind { schema, table, view, function, procedure, type, sequence, column, keyword }

final class CompletionItem {
  const CompletionItem(this.label, this.insert, this.kind, {this.detail = ''});

  final String label;

  /// The text that replaces the typed prefix.
  final String insert;
  final CompletionKind kind;
  final String detail;

  @override
  String toString() => '$label ($kind)';
}

/// Inside the parentheses of a call: the routine(s) and the parameter the cursor is in (0-based).
final class SignatureHelp {
  const SignatureHelp(this.signatures, this.activeParameter);

  final List<DbObject> signatures;
  final int activeParameter;
}

final class Completion {
  const Completion(this.prefixStart, this.prefix, this.items, this.signature);

  /// Where the typed word starts; items replace [prefix].
  final int prefixStart;
  final String prefix;
  final List<CompletionItem> items;
  final SignatureHelp? signature;
}

const keywords = [
  'SELECT',
  'FROM',
  'WHERE',
  'JOIN',
  'LEFT JOIN',
  'INNER JOIN',
  'ON',
  'AND',
  'OR',
  'NOT',
  'NULL',
  'IS',
  'IN',
  'EXISTS',
  'GROUP BY',
  'ORDER BY',
  'HAVING',
  'LIMIT',
  'OFFSET',
  'UNION ALL',
  'INSERT INTO',
  'VALUES',
  'UPDATE',
  'SET',
  'DELETE',
  'RETURNING',
  'WITH',
  'AS',
  'CASE',
  'WHEN',
  'THEN',
  'ELSE',
  'END',
  'DISTINCT',
  'COALESCE',
  'FOR UPDATE',
  'CREATE OR REPLACE',
  'FUNCTION',
  'PROCEDURE',
  'VIEW',
  'TABLE',
  'INDEX',
  'TRIGGER',
  'RETURNS',
  'RETURNS TABLE',
  'LANGUAGE',
  'plpgsql',
  'SECURITY DEFINER',
  'STABLE',
  'IMMUTABLE',
  'BEGIN',
  'DECLARE',
  'IF',
  'ELSIF',
  'LOOP',
  'FOREACH',
  'RAISE EXCEPTION',
  'USING ERRCODE',
  'PERFORM',
  'CALL',
  'RETURN',
  'RETURN QUERY',
  'FOUND',
  'INTO',
  'STRICT',
  'GET DIAGNOSTICS',
  'SET LOCAL ROLE',
  'RESET ROLE',
  'GRANT',
  'REVOKE',
  'PRIMARY KEY',
  'REFERENCES',
  'NOT NULL',
  'DEFAULT',
  'CHECK',
  'UNIQUE',
  'CONSTRAINT',
  'timestamptz',
  'uuid',
  'text',
  'bigint',
  'integer',
  'numeric',
  'boolean',
  'jsonb',
  'date',
];

const _relationContext = {'FROM', 'JOIN', 'UPDATE', 'INTO', 'TABLE', 'ON'};

final _ident = RegExp(r'[A-Za-z0-9_$]');

/// What to offer at [offset] of [text] (the editor's text of [path]).
Completion complete(ProjectIndex index, String text, int offset) {
  offset = offset.clamp(0, text.length);
  var start = offset;
  while (start > 0 && _ident.hasMatch(text[start - 1])) {
    start--;
  }
  final prefix = text.substring(start, offset);
  final lower = prefix.toLowerCase();
  bool matches(String name) => name.toLowerCase().startsWith(lower);
  final statement = _statementAround(text, offset);
  final signature = _signature(index, text, start);

  // `qualifier.` before the prefix: a schema (its objects) or an alias / table of the statement (its columns).
  if (start > 0 && text[start - 1] == '.') {
    var q = start - 1;
    while (q > 0 && _ident.hasMatch(text[q - 1])) {
      q--;
    }
    final qualifier = text.substring(q, start - 1).toLowerCase();
    final items = <CompletionItem>[];
    if (index.schemas.contains(qualifier)) {
      for (final o in index.objects.values) {
        if (o.key.schema != qualifier || !o.isDefinedHere || !matches(o.key.name)) continue;
        final kind = _kindOf(o);
        if (kind == null) continue;
        if (items.any((i) => i.label == o.key.name && i.kind == kind)) continue; // overloads: one item
        items.add(CompletionItem(o.key.name, o.key.name, kind, detail: o.signature));
      }
    } else {
      final relation = _aliases(statement.$1, index)[qualifier];
      if (relation != null) {
        for (final c in relation.columns) {
          if (matches(c.name)) {
            items.add(
              CompletionItem(
                c.name,
                c.name,
                CompletionKind.column,
                detail: '${c.type} - ${relation.key.qualified}'.trim(),
              ),
            );
          }
        }
      }
    }
    items.sort((a, b) => a.label.compareTo(b.label));
    return Completion(start, prefix, items, signature);
  }

  // Unqualified: the clause decides - relations after FROM/JOIN/..., procedures after CALL, else everything.
  final before = text.substring(statement.$2 < start ? statement.$2 : start, start).trimRight();
  final lastWord = RegExp(r'([A-Za-z_]+)\s*$').firstMatch(before)?.group(1)?.toUpperCase() ?? '';
  final items = <CompletionItem>[];
  final seen = <String>{};
  void addObject(DbObject o) {
    final kind = _kindOf(o);
    if (kind == null || !o.isDefinedHere) return;
    final label = o.key.qualified;
    if (!seen.add('$label/${kind.name}')) return;
    if (!matches(o.key.name) && !matches(label)) return;
    items.add(CompletionItem(label, label, kind, detail: o.signature));
  }

  if (prefix.isEmpty && !_relationContext.contains(lastWord) && lastWord != 'CALL' && lastWord != 'PERFORM') {
    return Completion(start, prefix, const [], signature);
  }
  for (final s in index.schemas.toList()..sort()) {
    if (matches(s)) items.add(CompletionItem(s, s, CompletionKind.schema));
  }
  for (final o in index.objects.values) {
    if (_relationContext.contains(lastWord)) {
      if (o.key.space == ObjectSpace.relation && o.kind != ObjectKind.tableIndex && o.kind != ObjectKind.sequence) {
        addObject(o);
      }
    } else if (lastWord == 'CALL') {
      if (o.kind == ObjectKind.procedure) addObject(o);
    } else if (lastWord == 'PERFORM') {
      if (o.kind == ObjectKind.function) addObject(o);
    } else if (o.kind != ObjectKind.tableIndex && o.kind != ObjectKind.trigger) {
      addObject(o);
    }
  }
  if (!_relationContext.contains(lastWord) && lastWord != 'CALL' && prefix.isNotEmpty) {
    final upper = prefix == prefix.toUpperCase();
    for (final k in keywords) {
      if (k.toLowerCase().startsWith(lower) && k.toLowerCase() != lower) {
        final insert = k == k.toLowerCase() ? k : (upper ? k : k.toLowerCase());
        items.add(CompletionItem(insert, insert, CompletionKind.keyword));
      }
    }
  }
  items.sort((a, b) {
    final ak = a.kind == CompletionKind.keyword ? 1 : 0;
    final bk = b.kind == CompletionKind.keyword ? 1 : 0;
    if (ak != bk) return ak - bk;
    final an = a.label.split('.').last.toLowerCase().startsWith(lower) ? 0 : 1;
    final bn = b.label.split('.').last.toLowerCase().startsWith(lower) ? 0 : 1;
    return an != bn ? an - bn : a.label.compareTo(b.label);
  });
  return Completion(start, prefix, items.take(200).toList(), signature);
}

CompletionKind? _kindOf(DbObject o) => switch (o.kind) {
  ObjectKind.table => CompletionKind.table,
  ObjectKind.view || ObjectKind.materializedView => CompletionKind.view,
  ObjectKind.function => CompletionKind.function,
  ObjectKind.procedure => CompletionKind.procedure,
  ObjectKind.type || ObjectKind.domain => CompletionKind.type,
  ObjectKind.sequence => CompletionKind.sequence,
  ObjectKind.schema => CompletionKind.schema,
  _ => null,
};

/// The statement around the cursor: from the previous `;`/`$$`/BEGIN/THEN... to the next `;` (good enough for
/// aliases, which live in one statement). Returns (text, start offset).
(String, int) _statementAround(String text, int offset) {
  var start = offset;
  while (start > 0) {
    final c = text[start - 1];
    if (c == ';') break;
    if (c == r'$' && start >= 2 && text[start - 2] == r'$') break;
    start--;
  }
  var end = offset;
  while (end < text.length && text[end] != ';') {
    end++;
  }
  return (text.substring(start, end), start);
}

// An alias is never a keyword: in `INTO v_x FROM s.t AS a` the FROM must stay for the next match.
final _aliasPattern = RegExp(
  r'\b(?:FROM|JOIN|UPDATE|INTO|USING|,)\s+([A-Za-z_][\w$]*(?:\.[A-Za-z_][\w$]*)?)'
  r'(?:\s+(?:AS\s+)?(?!(?:from|join|where|on|using|set|group|order|limit|offset|for|left|right|inner|full|cross|'
  r'natural|union|having|window|returning|values|select|into|and|or|lateral)\b)([A-Za-z_][\w$]*))?',
  caseSensitive: false,
);

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
};

/// alias (or table name) -> relation, for `FROM s.t AS a`, `JOIN s.t a`, `UPDATE s.t`, `s.t` itself.
Map<String, DbObject> _aliases(String statement, ProjectIndex index) {
  final map = <String, DbObject>{};
  for (final m in _aliasPattern.allMatches(statement)) {
    final name = m.group(1)!.toLowerCase();
    final parts = name.split('.');
    DbObject? relation;
    for (final o in index.objects.values) {
      if (o.key.space != ObjectSpace.relation || o.columns.isEmpty) continue;
      if (parts.length == 2 ? o.key.qualified == name : o.key.name == name) {
        relation = o;
        break;
      }
    }
    if (relation == null) continue;
    map[parts.last] = relation;
    map[name] = relation;
    final alias = m.group(2)?.toLowerCase();
    if (alias != null && !_notAliases.contains(alias)) map[alias] = relation;
  }
  return map;
}

/// The routine whose argument list the cursor is in, and which argument.
SignatureHelp? _signature(ProjectIndex index, String text, int offset) {
  var depth = 0;
  var commas = 0;
  var inString = false;
  for (var i = offset - 1; i >= 0 && offset - i < 4000; i--) {
    final c = text[i];
    if (c == "'") inString = !inString;
    if (inString) continue;
    if (c == ';') return null;
    if (c == ')') depth++;
    if (c == '(') {
      if (depth == 0) {
        var e = i;
        while (e > 0 && text[e - 1] == ' ') {
          e--;
        }
        var s = e;
        while (s > 0 && (_ident.hasMatch(text[s - 1]) || text[s - 1] == '.')) {
          s--;
        }
        final name = text.substring(s, e).toLowerCase();
        if (!name.contains('.')) return null;
        final found = [
          for (final o in index.objects.values)
            if (o.key.space == ObjectSpace.routine && o.key.qualified == name) o,
        ];
        return found.isEmpty ? null : SignatureHelp(found, commas);
      }
      depth--;
    }
    if (c == ',' && depth == 0) commas++;
  }
  return null;
}
