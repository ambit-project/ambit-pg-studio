import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

DbObject find(ProjectIndex index, String q) => index.objects.values.firstWhere((o) => o.key.qualified == q);

void main() {
  test('a table: every statement in changelog order with date, changeset and comment', () async {
    final index = (await Indexer.open(p.join(Directory.current.path, 'test', 'fixtures', 'shop'))).$1;
    final h = objectHistory(index, find(index, 'sales.orders'));
    expect(
      [for (final e in h.entries) (e.date, e.summary)],
      [
        ('2026-01-01', 'CREATE TABLE'),
        ('2026-01-01', 'CREATE INDEX orders_customer_ix'),
        ('2026-01-01', 'ADD COLUMN note, DROP COLUMN total'),
        ('2026-01-01', 'CREATE TRIGGER orders_touch'),
      ],
    );
    expect(h.entries[2].changeset, 'shop:20260101-02-sales-orders-add-note');
    expect(h.entries[2].comment, 'Notatka do zamówienia.');
  });

  test('the effective DDL replays ALTERs and parses', () async {
    final index = (await Indexer.open(p.join(Directory.current.path, 'test', 'fixtures', 'shop'))).$1;
    final ddl = objectHistory(index, find(index, 'sales.orders')).effectiveDdl!;
    expect(
      ddl,
      contains(
        'CREATE TABLE sales.orders (\n'
        '    id uuid PRIMARY KEY,\n'
        '    customer_id uuid NOT NULL REFERENCES sales.customers (id),\n'
        '    note text\n'
        ');',
      ),
    );
    expect(ddl, contains('CREATE UNIQUE INDEX IF NOT EXISTS orders_customer_ix ON sales.orders (customer_id);'));
    expect(ddl, contains('CREATE TRIGGER orders_touch BEFORE UPDATE ON sales.orders'));
    expect(PgQuery.parse(ddl).ok, isTrue);
  });

  test('ALTER COLUMN: NOT NULL, DEFAULT, TYPE, constraints, RENAME COLUMN', () {
    const ddl = '''CREATE TABLE s.t (a int, b text DEFAULT 'x', c int);
ALTER TABLE s.t ALTER COLUMN a SET NOT NULL, ALTER COLUMN b DROP DEFAULT, ALTER COLUMN c TYPE bigint USING c::bigint;
ALTER TABLE s.t ADD CONSTRAINT t_a_uq UNIQUE (a), ALTER COLUMN b SET DEFAULT 'y';
ALTER TABLE s.t RENAME COLUMN c TO d;
ALTER TABLE s.t ENABLE ROW LEVEL SECURITY;''';
    final file = analyzeFile('x.sql', ddl);
    final index = ProjectIndex.link('/tmp', {'x.sql': file}, ['x.sql']);
    final h = objectHistory(index, find(index, 's.t'));
    expect(h.entries.map((e) => e.summary), [
      'CREATE TABLE',
      'ALTER COLUMN a SET NOT NULL, ALTER COLUMN b DROP DEFAULT, ALTER COLUMN c TYPE bigint',
      'ADD CONSTRAINT t_a_uq UNIQUE, ALTER COLUMN b SET DEFAULT',
      'RENAME COLUMN c TO d',
      'ENABLE ROW LEVEL SECURITY',
    ]);
    expect(
      h.effectiveDdl,
      contains(
        "CREATE TABLE s.t (\n    a int NOT NULL,\n    b text DEFAULT 'y',\n    d bigint,\n    CONSTRAINT t_a_uq UNIQUE (a)\n);",
      ),
    );
    expect(PgQuery.parse(h.effectiveDdl!).ok, isTrue);
  });

  for (final repo in ['ambit.wms.app/db', 'halycon.app.dev/db/changelog', 'ambit.jobtron.app/db']) {
    final db = p.normalize(p.join(Directory.current.path, '..', '..', '..', repo));
    test(
      '$repo: the effective DDL of every table parses',
      () async {
        final index = (await Indexer.open(db)).$1;
        var tables = 0;
        final bad = <String>[];
        for (final o in index.objects.values.where((o) => o.kind == ObjectKind.table && o.isDefinedHere)) {
          tables++;
          final ddl = objectHistory(index, o).effectiveDdl;
          if (ddl == null || !PgQuery.parse(ddl).ok) bad.add(o.key.qualified);
        }
        print('$repo: $tables tables, effective DDL not parsing: $bad');
        expect(bad, isEmpty);
      },
      tags: ['corpus'],
      skip: Directory(db).existsSync() ? false : 'missing $db',
    );
  }
}
