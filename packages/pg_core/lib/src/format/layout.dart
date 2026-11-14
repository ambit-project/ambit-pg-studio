// Layout of a SQL statement (ADR 0004): the author's line breaks stay, indentation follows the structure, lines
// over the limit are broken before clauses (then after the items of a SELECT list). Only whitespace changes.
import '../pg_query/pg_query.dart';
import 'formatter.dart' show FormatOptions;

const _clauses = {
  'SELECT',
  'FROM',
  'WHERE',
  'GROUP',
  'ORDER',
  'HAVING',
  'LIMIT',
  'OFFSET',
  'UNION',
  'INTERSECT',
  'EXCEPT',
  'WINDOW',
  'RETURNING',
  'VALUES',
  'INSERT',
  'UPDATE',
  'DELETE',
  'WITH',
  'JOIN',
  'LEFT',
  'RIGHT',
  'FULL',
  'INNER',
  'CROSS',
  'NATURAL',
  'SET',
  'FOR',
  'FETCH',
  'MERGE',
  'USING',
};

const _queryStarts = {'SELECT', 'WITH', 'VALUES', 'INSERT', 'UPDATE', 'DELETE'};

bool _isComment(PgToken t) => t.name == 'SQL_COMMENT' || t.name == 'C_COMMENT';

/// Lays [sql] (one statement starting at its first token) out; null when it cannot be scanned.
String? layoutSql(String sql, FormatOptions o) {
  final broken = _breakLongLines(sql, o);
  if (broken == null) return null;
  return _reindent(broken, o);
}

bool _clauseAt(String sql, List<PgToken> tokens, int i) {
  final t = tokens[i];
  if (!t.isKeyword) return false;
  final word = sql.substring(t.start, t.end).toUpperCase();
  if (!_clauses.contains(word)) return false;
  // left(...) / right(...) are functions; FOR inside "FOR UPDATE" is a clause, SET only starts a line in UPDATE.
  final next = i + 1 < tokens.length ? sql.substring(tokens[i + 1].start, tokens[i + 1].end) : '';
  if ((word == 'LEFT' || word == 'RIGHT') && next == '(') return false;
  if (i > 0) {
    final prev = sql.substring(tokens[i - 1].start, tokens[i - 1].end).toUpperCase();
    // the JOIN of LEFT JOIN, the BY of ORDER BY and UNION ALL stay on the line of their first word
    if (word == 'JOIN' && {'LEFT', 'RIGHT', 'FULL', 'INNER', 'CROSS', 'NATURAL', 'OUTER'}.contains(prev)) return false;
    if ({'LEFT', 'RIGHT', 'FULL'}.contains(word) && prev == 'NATURAL') return false;
    if (word == 'SELECT' && {'UNION', 'ALL', 'INTERSECT', 'EXCEPT', 'DISTINCT'}.contains(prev)) return false;
    if (word == 'UPDATE' && {'FOR', 'NO', 'KEY', 'DO', 'ON'}.contains(prev)) return false;
    if (word == 'SET' && prev != ')' && !RegExp(r'^[A-Za-z_"]').hasMatch(prev)) return false;
    if (word == 'DELETE' && prev == 'ON') return false;
    if (word == 'FROM' && {'DISTINCT', 'IS'}.contains(prev)) return false;
    if (word == 'WITH' && {'WITHOUT', 'TIME', 'ORDINALITY', 'NO'}.contains(prev)) return false;
    if (word == 'USING' && prev != ')' && !RegExp(r'^[A-Za-z_"]').hasMatch(prev)) return false;
  }
  if (word == 'FOR' && !{'UPDATE', 'SHARE', 'NO', 'KEY'}.contains(next.toUpperCase())) return false;
  return true;
}

String? _breakLongLines(String sql, FormatOptions o) {
  if (!sql.split('\n').any((l) => l.length > o.maxLineLength)) return sql;
  String? error;
  final tokens = PgQuery.scan(sql, onError: (e) => error = e.message);
  if (error != null) return null;
  final code = [
    for (final t in tokens)
      if (!_isComment(t)) t,
  ];
  // Paren depth before each code token.
  final depth = List<int>.filled(code.length, 0);
  var d = 0;
  for (var i = 0; i < code.length; i++) {
    final s = sql.substring(code[i].start, code[i].end);
    if (s == ')') d--;
    depth[i] = d;
    if (s == '(') d++;
  }
  final lineOf = <int>[];
  var line = 0;
  var pos = 0;
  for (final t in code) {
    line += '\n'.allMatches(sql.substring(pos, t.start)).length;
    pos = t.start;
    lineOf.add(line);
  }
  final lines = sql.split('\n');
  final breaks = <int>{};
  var i = 0;
  while (i < code.length) {
    final l = lineOf[i];
    var j = i;
    while (j < code.length && lineOf[j] == l) {
      j++;
    }
    if (lines[l].length > o.maxLineLength) {
      final base = depth[i];
      var selectFrom = -1;
      for (var k = i; k < j; k++) {
        if (depth[k] != base || !_clauseAt(sql, code, k)) continue;
        if (k > i) breaks.add(code[k].start);
        final w = sql.substring(code[k].start, code[k].end).toUpperCase();
        if (w == 'SELECT') selectFrom = k;
      }
      // Still long: the items of the SELECT list one per line.
      if (selectFrom >= 0) {
        var listEnd = j;
        for (var k = selectFrom + 1; k < j; k++) {
          if (depth[k] == base && _clauseAt(sql, code, k)) {
            listEnd = k;
            break;
          }
        }
        final head = sql.substring(code[selectFrom].start, code[listEnd - 1].end);
        if (head.length > o.maxLineLength - o.indent) {
          breaks.add(code[selectFrom + 1].start);
          for (var k = selectFrom + 1; k < listEnd; k++) {
            if (depth[k] == base && sql.substring(code[k].start, code[k].end) == ',' && k + 1 < listEnd) {
              breaks.add(code[k + 1].start);
            }
          }
        }
      }
    }
    i = j;
  }
  if (breaks.isEmpty) return sql;
  final b = StringBuffer();
  var last = 0;
  for (final at in breaks.toList()..sort()) {
    b.write(sql.substring(last, at).trimRight());
    b.write('\n');
    last = at;
  }
  b.write(sql.substring(last));
  return b.toString();
}

final class _Group {
  _Group(this.kind, this.base);

  /// query (clauses at base + indent, items one more), list (items at base + indent), case (WHEN/ELSE at base +
  /// indent).
  final String kind;
  final int base;
}

String? _reindent(String sql, FormatOptions o) {
  String? error;
  final tokens = PgQuery.scan(sql, onError: (e) => error = e.message);
  if (error != null) return null;
  final lines = sql.split('\n');
  final starts = <int>[];
  var pos = 0;
  for (final l in lines) {
    starts.add(pos);
    pos += l.length + 1;
  }
  // Tokens by line; lines that start inside a multi-line token stay as they are.
  final byLine = List.generate(lines.length, (_) => <int>[]);
  final inside = List<bool>.filled(lines.length, false);
  var li = 0;
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    while (li + 1 < lines.length && starts[li + 1] <= t.start) {
      li++;
    }
    byLine[li].add(i);
    for (var k = li + 1; k < lines.length && starts[k] < t.end; k++) {
      inside[k] = true;
    }
  }
  final unit = o.indent;
  final stack = <_Group>[_Group('query', -unit)];
  final pending = <int>[]; // comment-only lines waiting for the indentation of the next code line
  String text(int i) => sql.substring(tokens[i].start, tokens[i].end);
  final code = <PgToken>[];
  final codeIndex = <int, int>{};
  for (var i = 0; i < tokens.length; i++) {
    if (_isComment(tokens[i])) continue;
    codeIndex[i] = code.length;
    code.add(tokens[i]);
  }

  final result = List<String?>.filled(lines.length, null);
  for (var l = 0; l < lines.length; l++) {
    if (inside[l]) {
      result[l] = lines[l];
      continue;
    }
    final ids = byLine[l];
    if (ids.isEmpty) {
      result[l] = lines[l].trim().isEmpty ? '' : lines[l];
      continue;
    }
    if (ids.every((i) => _isComment(tokens[i]))) {
      pending.add(l);
      continue;
    }
    final first = ids.firstWhere((i) => !_isComment(tokens[i]));
    final firstText = text(first).toUpperCase();
    final g = stack.last;
    int indent;
    if (l == 0) {
      indent = 0;
    } else if (firstText == ')' && stack.length > 1) {
      indent = g.base;
    } else if (firstText == 'END' && g.kind == 'case') {
      indent = g.base;
    } else if (g.kind == 'query') {
      indent = g.base + unit + (_clauseAt(sql, code, codeIndex[first]!) ? 0 : unit);
    } else {
      indent = g.base + unit;
    }
    for (final c in pending) {
      result[c] = '${' ' * (indent < 0 ? 0 : indent)}${lines[c].trim()}';
    }
    pending.clear();
    result[l] = '${' ' * (indent < 0 ? 0 : indent)}${lines[l].trim()}';
    // Groups opened and closed on this line.
    for (final i in ids) {
      if (_isComment(tokens[i])) continue;
      final s = text(i);
      final upper = s.toUpperCase();
      if (s == '(') {
        final ci = codeIndex[i]! + 1;
        final nextWord = ci < code.length ? sql.substring(code[ci].start, code[ci].end).toUpperCase() : '';
        stack.add(_Group(_queryStarts.contains(nextWord) ? 'query' : 'list', indent));
      } else if (s == ')' && stack.length > 1) {
        stack.removeLast();
      } else if (upper == 'CASE' && tokens[i].isKeyword) {
        stack.add(_Group('case', indent));
      } else if (upper == 'END' && stack.last.kind == 'case') {
        stack.removeLast();
      }
    }
  }
  for (final c in pending) {
    result[c] = lines[c].trim();
  }
  return [for (var l = 0; l < lines.length; l++) (result[l] ?? lines[l]).trimRight()].join('\n');
}
