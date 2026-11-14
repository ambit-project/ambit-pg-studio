// Syntax classes of a SQL file from the PostgreSQL scanner, with dollar-quoted bodies scanned again inside.
import '../liquibase.dart';
import '../pg_query/pg_query.dart';

enum HighlightKind { keyword, identifier, string, number, comment, liquibase, operator, punctuation }

final class HighlightToken {
  const HighlightToken(this.start, this.end, this.kind);

  final int start;
  final int end;
  final HighlightKind kind;
}

/// Tokens of [text] (UTF-16 offsets, sorted). A scanner error (an unterminated string while typing) leaves the rest
/// of that text unhighlighted.
List<HighlightToken> highlight(String text) {
  final prepared = prepareSql(text).sql;
  final out = <HighlightToken>[];
  _scan(prepared, 0, out, 0);
  return out;
}

void _scan(String text, int base, List<HighlightToken> out, int depth) {
  final tokens = PgQuery.scan(text);
  for (final t in tokens) {
    final raw = text.substring(t.start, t.end);
    switch (t.name) {
      case 'SQL_COMMENT' || 'C_COMMENT':
        final liquibase =
            raw.startsWith('--changeset') ||
            raw.startsWith('--comment:') ||
            raw.startsWith('--liquibase') ||
            raw.startsWith('--rollback') ||
            raw.startsWith('--precondition');
        out.add(
          HighlightToken(base + t.start, base + t.end, liquibase ? HighlightKind.liquibase : HighlightKind.comment),
        );
      case 'SCONST' || 'USCONST' || 'BCONST' || 'XCONST':
        if (raw.startsWith(r'$') && depth < 3) {
          final tagEnd = raw.indexOf(r'$', 1);
          final tag = raw.substring(0, tagEnd + 1);
          if (raw.length >= tag.length * 2) {
            out.add(HighlightToken(base + t.start, base + t.start + tag.length, HighlightKind.string));
            _scan(raw.substring(tag.length, raw.length - tag.length), base + t.start + tag.length, out, depth + 1);
            out.add(HighlightToken(base + t.end - tag.length, base + t.end, HighlightKind.string));
            continue;
          }
        }
        out.add(HighlightToken(base + t.start, base + t.end, HighlightKind.string));
      case 'ICONST' || 'FCONST':
        out.add(HighlightToken(base + t.start, base + t.end, HighlightKind.number));
      case 'IDENT' || 'UIDENT':
        out.add(HighlightToken(base + t.start, base + t.end, HighlightKind.identifier));
      default:
        if (t.isKeyword) {
          out.add(HighlightToken(base + t.start, base + t.end, HighlightKind.keyword));
        } else if (raw.length == 1 && '(),;.[]'.contains(raw)) {
          out.add(HighlightToken(base + t.start, base + t.end, HighlightKind.punctuation));
        } else {
          out.add(HighlightToken(base + t.start, base + t.end, HighlightKind.operator));
        }
    }
  }
}
