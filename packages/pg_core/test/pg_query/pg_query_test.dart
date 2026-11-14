import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

void main() {
  group('parse', () {
    test('returns the JSON tree of the statements', () {
      final result = PgQuery.parse('SELECT 1; CREATE TABLE s.t (id uuid PRIMARY KEY);');
      expect(result.ok, isTrue);
      expect(result.statements, hasLength(2));
      expect(result.statements[1]['stmt'], contains('CreateStmt'));
    });

    test('reports a syntax error with the UTF-16 offset, also after Polish characters', () {
      const sql = '-- zażółć gęślą jaźń\nSELECT FROM WHERE;';
      final result = PgQuery.parse(sql);
      expect(result.ok, isFalse);
      expect(result.error!.message, contains('syntax error'));
      expect(sql.substring(result.error!.offset!), startsWith('WHERE'));
    });
  });

  group('parsePlpgsql', () {
    test('returns the function body statements', () {
      final result = PgQuery.parsePlpgsql(r'''
CREATE PROCEDURE a.p(p_x text) LANGUAGE plpgsql AS $$
DECLARE v record;
BEGIN
  SELECT * INTO v FROM s.tab WHERE id = p_x;
  CALL s.other(v.id);
END $$;''');
      expect(result.ok, isTrue, reason: result.error?.message);
      expect(result.functionsJson, contains('PLpgSQL_stmt_call'));
    });

    test('reports an error in the body', () {
      final result = PgQuery.parsePlpgsql(
        r'CREATE FUNCTION a.f() RETURNS int LANGUAGE plpgsql AS $$ BEGIN RETURN; $$;',
      );
      expect(result.ok, isFalse);
    });
  });

  group('scan', () {
    test('returns tokens with UTF-16 offsets and names, comments included', () {
      const sql = "-- ł\nSELECT 'ą', x.y FROM t";
      final tokens = PgQuery.scan(sql);
      final byName = {for (final t in tokens) sql.substring(t.start, t.end): t.name};
      expect(byName['-- ł'], 'SQL_COMMENT');
      expect(byName['SELECT'], 'SELECT');
      expect(byName["'ą'"], 'SCONST');
      expect(byName['x'], 'IDENT');
      expect(tokens.firstWhere((t) => t.name == 'SELECT').isKeyword, isTrue);
    });

    test('a token libpg_query has no name for (a lone \$) does not fail', () {
      final tokens = PgQuery.scan(r'GRANT USAGE ON SCHEMA s TO \${role_prefix}_api;');
      expect(tokens, isNotEmpty);
    });

    test('reports an unterminated string', () {
      PgSyntaxError? error;
      final tokens = PgQuery.scan("SELECT 'abc", onError: (e) => error = e);
      expect(tokens, isEmpty);
      expect(error, isNotNull);
    });
  });

  test('split returns statement ranges', () {
    final source = SourceText('SELECT 1;\n-- ż\nSELECT 2;');
    final ranges = PgQuery.split(source)!;
    expect(ranges, hasLength(2));
    expect(source.text.substring(ranges[1].start, ranges[1].end), contains('SELECT 2'));
  });
}
