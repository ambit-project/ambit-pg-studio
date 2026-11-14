import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

void main() {
  test('keywords, names, strings, comments, Liquibase lines and the inside of a dollar-quoted body', () {
    const text = '''--liquibase formatted sql
--changeset a:b
-- zwykły komentarz
CREATE FUNCTION s.f() RETURNS int LANGUAGE plpgsql AS \$\$
BEGIN
  RETURN 1; -- w ciele
END \$\$;''';
    final kinds = {for (final t in highlight(text)) text.substring(t.start, t.end): t.kind};
    expect(kinds['--changeset a:b'], HighlightKind.liquibase);
    expect(kinds['-- zwykły komentarz'], HighlightKind.comment);
    expect(kinds['CREATE'], HighlightKind.keyword);
    expect(kinds['f'], HighlightKind.identifier);
    expect(kinds['BEGIN'], HighlightKind.keyword);
    expect(kinds['RETURN'], HighlightKind.keyword);
    expect(kinds['1'], HighlightKind.number);
    expect(kinds['-- w ciele'], HighlightKind.comment);
    expect(kinds[r'$$'], HighlightKind.string);
  });

  test('Liquibase properties do not break the scanner', () {
    final tokens = highlight(r'GRANT USAGE ON SCHEMA s TO ${role_prefix}_api;');
    expect(tokens.where((t) => t.kind == HighlightKind.keyword), isNotEmpty);
  });
}
