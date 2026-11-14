import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

const _opts = FormatOptions();

String fmt(String text, {FormatOptions options = _opts, bool fileIsNew = false}) =>
    formatSql(text, options: options, fileIsNew: fileIsNew).text;

/// Tokens without whitespace, dollar-quoted bodies by their own tokens: what a format may never change.
List<String> tokens(String s) {
  final out = <String>[];
  for (final t in PgQuery.scan(s)) {
    final raw = s.substring(t.start, t.end);
    if (t.name == 'SCONST' && raw.startsWith(r'$')) {
      final tag = raw.substring(0, raw.indexOf(r'$', 1) + 1);
      out
        ..add(tag)
        ..addAll(tokens(raw.substring(tag.length, raw.length - tag.length)));
    } else {
      out.add(raw.trimRight());
    }
  }
  return out;
}

void main() {
  group('routines', () {
    const messy = r'''CREATE OR REPLACE PROCEDURE s_app.p(p_id uuid,   p_lines s_app.line_input[],
  INOUT p_row_version bigint) LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
v_x int;
BEGIN
-- U1101 (404): brak.
IF p_id IS NULL THEN
RAISE EXCEPTION 'x' USING ERRCODE = 'U1101';
ELSIF p_row_version IS NULL THEN
v_x := 1;
ELSE
FOR v_x IN SELECT 1
FROM s.t AS t LOOP
NULL;
END LOOP;
END IF;
UPDATE s.t SET status = CASE WHEN p_id IS NULL THEN
'a' ELSE 'b' END
WHERE id = p_id;
BEGIN
PERFORM 1;
EXCEPTION
WHEN others THEN
NULL;
END;
END
$$;''';

    test('header one parameter and one clause per line, the body indented by its blocks', () {
      expect(fmt(messy), r'''CREATE OR REPLACE PROCEDURE s_app.p(
    p_id uuid,
    p_lines s_app.line_input[],
    INOUT p_row_version bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_x int;
BEGIN
    -- U1101 (404): brak.
    IF p_id IS NULL THEN
        RAISE EXCEPTION 'x' USING ERRCODE = 'U1101';
    ELSIF p_row_version IS NULL THEN
        v_x := 1;
    ELSE
        FOR v_x IN SELECT 1
        FROM s.t AS t LOOP
            NULL;
        END LOOP;
    END IF;
    UPDATE s.t SET status = CASE WHEN p_id IS NULL THEN
    'a' ELSE 'b' END
    WHERE id = p_id;
    BEGIN
        PERFORM 1;
    EXCEPTION
        WHEN others THEN
            NULL;
    END;
END
$$;''');
    });

    test('only whitespace changes, and a second format changes nothing', () {
      final once = fmt(messy);
      expect(tokens(once), tokens(messy));
      expect(fmt(once), once);
    });

    test('a short one-line parameter list stays on one line; a multi-line one stays multi-line', () {
      expect(
        fmt(r'CREATE FUNCTION s.f(a int) RETURNS int LANGUAGE sql AS $$ SELECT a $$;'),
        'CREATE FUNCTION s.f(a int)\nRETURNS int\nLANGUAGE sql\nAS \$\$\n    SELECT a\n\$\$;',
      );
      expect(
        fmt('CREATE FUNCTION s.f(\n  a int\n) RETURNS int LANGUAGE sql AS \$\$ SELECT a \$\$;'),
        startsWith('CREATE FUNCTION s.f(\n    a int\n)'),
      );
    });

    test('clauseIndent indents RETURNS/LANGUAGE/... but not AS (halycon style)', () {
      final out = fmt(
        r'CREATE FUNCTION s.f() RETURNS TABLE (a int) LANGUAGE plpgsql STABLE AS $$ BEGIN RETURN; END $$;',
        options: const FormatOptions(clauseIndent: 4),
      );
      expect(out, contains('\n    RETURNS TABLE (a int)\n    LANGUAGE plpgsql\n    STABLE\nAS \$\$'));
    });

    test('upper-case keywords in bodies when asked', () {
      final out = fmt(
        'CREATE FUNCTION s.f() RETURNS int LANGUAGE plpgsql AS \$\$\nbegin\nif true then return 1; end if;\nend\n\$\$;',
        options: const FormatOptions(keywordCase: KeywordCase.upper),
      );
      expect(out, contains('BEGIN\n    IF TRUE THEN RETURN 1; END IF;\nEND'));
    });
  });

  group('statements', () {
    test('a view: clauses at the left, items indented, the author\'s line breaks and comments stay', () {
      const view = '''CREATE OR REPLACE VIEW s_app.v AS
SELECT
  a.id,
      -- komentarz zostaje
      a.name
FROM s.a AS a
  JOIN s.b AS b ON b.id = a.b_id
WHERE a.x = 1
  AND a.y = 2;''';
      expect(fmt(view), '''CREATE OR REPLACE VIEW s_app.v AS
SELECT
    a.id,
    -- komentarz zostaje
    a.name
FROM s.a AS a
JOIN s.b AS b ON b.id = a.b_id
WHERE a.x = 1
    AND a.y = 2;''');
    });

    test('subqueries, CASE and parenthesised lists by depth', () {
      const sql = '''SELECT
CASE
WHEN x THEN 1
ELSE 2
END AS c
FROM s.t AS t
WHERE t.id IN (
SELECT u.id
FROM s.u AS u
)''';
      expect(fmt(sql), '''SELECT
    CASE
        WHEN x THEN 1
        ELSE 2
    END AS c
FROM s.t AS t
WHERE t.id IN (
    SELECT u.id
    FROM s.u AS u
)''');
    });

    test('a line over the limit breaks before its clauses, then after the items of the SELECT list', () {
      const long = 'SELECT aaaa, bbbb, cccc FROM s.t AS t WHERE t.x = 1 ORDER BY aaaa';
      expect(fmt(long, options: const FormatOptions(maxLineLength: 20)), '''SELECT
    aaaa,
    bbbb,
    cccc
FROM s.t AS t
WHERE t.x = 1
ORDER BY aaaa''');
    });

    test('statements the formatter does not lay out stay exactly as written', () {
      const sql = 'SET   LOCAL ROLE x;\nGRANT  SELECT ON s.t TO y;\nCREATE SCHEMA   s;';
      expect(fmt(sql), sql);
    });
  });

  group('Liquibase', () {
    const deployed = '''--liquibase formatted sql

--changeset a:1
--comment: wdrożony
SELECT 1
 FROM   s.t;

--changeset a:2 runOnChange:true
SELECT 1
      FROM s.t;''';

    test('changesets without runOnChange are left alone (checksum), runOnChange ones are formatted', () {
      final r = formatSql(deployed);
      expect(r.text, contains('SELECT 1\n FROM   s.t;'));
      expect(r.text, endsWith('SELECT 1\nFROM s.t;'));
      expect(r.skipped.single.reason, contains('without runOnChange'));
    });

    test('a file not deployed yet (not in main) is formatted completely', () {
      final r = formatSql(deployed, fileIsNew: true);
      expect(r.skipped, isEmpty);
      expect(r.text, contains('SELECT 1\nFROM s.t;'));
    });

    test('Liquibase properties survive', () {
      const sql = '--liquibase formatted sql\n--changeset a:1 runOnChange:true\nSELECT 1\n   FROM \${schema}.t AS t;';
      expect(fmt(sql), endsWith('SELECT 1\nFROM \${schema}.t AS t;'));
    });

    test('a psql script and a syntax error are reported, not formatted', () {
      expect(formatSql('\\set x 1\nSELECT :x;').skipped.single.reason, contains('psql script'));
      final broken = formatSql('SELECT FROM WHERE;');
      expect(broken.text, 'SELECT FROM WHERE;');
      expect(broken.skipped.single.reason, contains('syntax error'));
    });
  });

  test('a range formats only the statements it touches', () {
    const sql = 'SELECT 1\n  FROM a;\nSELECT 2\n  FROM b;';
    final second = sql.indexOf('SELECT 2');
    expect(formatSql(sql, rangeStart: second, rangeEnd: second + 3).text, 'SELECT 1\n  FROM a;\nSELECT 2\nFROM b;');
  });

  test('options from .pgstudio.json fields', () {
    final o = FormatOptions.fromJson({
      'indent': 2,
      'maxLineLength': 80,
      'keywordCase': 'upper',
      'formatOnSave': true,
      'clauseIndent': 4,
    });
    expect(
      [o.indent, o.maxLineLength, o.keywordCase, o.formatOnSave, o.clauseIndent],
      [2, 80, KeywordCase.upper, true, 4],
    );
  });
}
