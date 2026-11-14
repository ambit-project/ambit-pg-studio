// Helpers over scanner tokens of one text: identifiers, qualified names, spans.
import '../pg_query/pg_query.dart';

/// Keywords that may follow an object keyword before its name (CREATE INDEX CONCURRENTLY IF NOT EXISTS name).
const _nameNoise = {'IF_P', 'NOT', 'EXISTS', 'CONCURRENTLY', 'ONLY', 'OR', 'REPLACE'};

/// Tokens of a text without comments, with lookups by offset.
final class TokenText {
  TokenText(this.text, List<PgToken> all)
    : tokens = all.where((t) => t.name != 'SQL_COMMENT' && t.name != 'C_COMMENT').toList(growable: false),
      comments = all.where((t) => t.name == 'SQL_COMMENT' || t.name == 'C_COMMENT').toList(growable: false);

  factory TokenText.scan(String text) => TokenText(text, PgQuery.scan(text));

  final String text;
  final List<PgToken> tokens;
  final List<PgToken> comments;

  String textOf(PgToken t) => text.substring(t.start, t.end);

  /// An identifier token: IDENT or a non-reserved keyword (keywords 1-3 can be names).
  bool isName(PgToken t) => t.name == 'IDENT' || (t.keywordKind >= 1 && t.keywordKind <= 3);

  bool isSymbol(PgToken t, String symbol) => textOf(t) == symbol && !isName(t);

  /// The name a token stands for: unquoted names fold to lower case, quoted ones keep their case.
  String nameOf(PgToken t) {
    final raw = textOf(t);
    if (raw.startsWith('"') && raw.endsWith('"') && raw.length >= 2) {
      return raw.substring(1, raw.length - 1).replaceAll('""', '"');
    }
    return raw.toLowerCase();
  }

  /// Index of the first token starting at or after [offset].
  int indexAt(int offset) {
    var low = 0;
    var high = tokens.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (tokens[mid].start < offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  /// Reads `name(.name)*` starting at token [i]; null when [i] is not a name.
  QualifiedRun? qualifiedAt(int i) {
    if (i < 0 || i >= tokens.length || !isName(tokens[i])) return null;
    final parts = [nameOf(tokens[i])];
    var last = i;
    while (last + 2 < tokens.length && isSymbol(tokens[last + 1], '.') && isName(tokens[last + 2])) {
      // `a . b` with spaces is still a qualified name; `a.*` is not (handled by isName).
      parts.add(nameOf(tokens[last + 2]));
      last += 2;
    }
    return QualifiedRun(parts, i, last, tokens[i].start, tokens[last].end);
  }

  /// The qualified name whose first token starts exactly at [offset].
  QualifiedRun? qualifiedStartingAt(int offset) {
    final i = indexAt(offset);
    if (i >= tokens.length || tokens[i].start != offset) return null;
    return qualifiedAt(i);
  }

  /// The first qualified name after one of [keywords] (upper case) within [start, end), skipping IF NOT EXISTS etc.
  QualifiedRun? nameAfter(Set<String> keywords, int start, int end) {
    for (var i = indexAt(start); i < tokens.length && tokens[i].start < end; i++) {
      if (!keywords.contains(tokens[i].name)) continue;
      var j = i + 1;
      while (j < tokens.length && _nameNoise.contains(tokens[j].name)) {
        j++;
      }
      final run = qualifiedAt(j);
      if (run != null) return run;
    }
    return null;
  }

  /// The first run of tokens spelling [parts] (or its last part alone when [allowUnqualified]) within [start, end).
  QualifiedRun? find(List<String> parts, int start, int end, {bool allowUnqualified = true}) {
    for (var i = indexAt(start); i < tokens.length && tokens[i].start < end; i++) {
      if (i > 0 && isSymbol(tokens[i - 1], '.')) continue;
      final run = qualifiedAt(i);
      if (run == null) continue;
      if (_endsWith(run.parts, parts) || (allowUnqualified && run.parts.length == 1 && run.parts.last == parts.last)) {
        return run;
      }
    }
    return null;
  }

  static bool _endsWith(List<String> run, List<String> parts) {
    if (run.length != parts.length) return false;
    for (var i = 0; i < parts.length; i++) {
      if (run[i] != parts[i]) return false;
    }
    return true;
  }

  /// Source text from token [i] up to (not including) the first token at depth 0 that is `,` `)` or one of
  /// [stopNames]; used for types as written (`orders_app.asn_line_input[]`, `numeric(12, 2)`).
  (String text, int endIndex) textUntil(int i, Set<String> stopNames) {
    var depth = 0;
    var j = i;
    for (; j < tokens.length; j++) {
      final t = tokens[j];
      final s = textOf(t);
      if (depth == 0 && (s == ',' || s == ')' || s == ';' || stopNames.contains(t.name))) break;
      if (s == '(' || s == '[') depth++;
      if (s == ')' || s == ']') depth--;
    }
    if (j == i) return ('', j);
    return (text.substring(tokens[i].start, tokens[j - 1].end).replaceAll(RegExp(r'\s+'), ' '), j);
  }

  /// Index of the `)` matching the `(` at token [open].
  int matchingParen(int open) {
    var depth = 0;
    for (var j = open; j < tokens.length; j++) {
      final s = textOf(tokens[j]);
      if (s == '(') depth++;
      if (s == ')') {
        depth--;
        if (depth == 0) return j;
      }
    }
    return tokens.length - 1;
  }
}

/// A qualified name in tokens [first]..[last] spanning [start, end).
final class QualifiedRun {
  const QualifiedRun(this.parts, this.first, this.last, this.start, this.end);

  final List<String> parts;
  final int first;
  final int last;
  final int start;
  final int end;
}
