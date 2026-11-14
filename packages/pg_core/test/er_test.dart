import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

void main() {
  test('tables with PK/FK columns, foreign keys as edges, referenced tables to the left', () async {
    final index = (await Indexer.open(p.join(Directory.current.path, 'test', 'fixtures', 'shop'))).$1;
    final er = erModel(index, schema: 'sales');
    expect(
      [for (final t in er.tables) (t.object.key.qualified, t.layer, t.row)],
      [('sales.customers', 0, 0), ('sales.orders', 1, 0)],
    );
    final orders = er.tables[1];
    expect(
      [for (final c in orders.columns) '${c.name}${c.primaryKey ? ' PK' : ''}${c.foreignKey ? ' FK' : ''}'],
      ['id PK', 'customer_id FK', 'note'],
    );
    expect(
      [for (final e in er.edges) '${e.from.qualified} -> ${e.to.qualified} ${e.columns}'],
      ['sales.orders -> sales.customers [customer_id]'],
    );
  });

  test('a module: references to another module are external nodes; ALTER TABLE ADD CONSTRAINT counts', () async {
    final index = (await Indexer.open(p.join(Directory.current.path, 'test', 'fixtures', 'modules'))).$1;
    final orders = index.conventions.modules.firstWhere((m) => m.name == 'orders');
    final er = erModel(index, module: orders);
    expect([
      for (final t in er.tables) (t.object.key.qualified, t.external),
    ], unorderedEquals([('orders.orders', false), ('partners.customers', true), ('billing.invoices', true)]));
    final altered = analyzeFile(
      'x.sql',
      'CREATE TABLE s.a (id int PRIMARY KEY); CREATE TABLE s.b (id int, a_id int);'
          ' ALTER TABLE s.b ADD CONSTRAINT b_pk PRIMARY KEY (id), ADD CONSTRAINT b_a FOREIGN KEY (a_id) REFERENCES s.a (id);',
    );
    final small = ProjectIndex.link('/tmp', {'x.sql': altered}, ['x.sql']);
    final er2 = erModel(small, schema: 's');
    expect(er2.edges.single.columns, ['a_id']);
    expect(er2.tables.firstWhere((t) => t.object.key.name == 'b').columns.first.primaryKey, isTrue);
  });

  test(
    'wms: every schema with tables builds a model',
    () async {
      final db = p.normalize(p.join(Directory.current.path, '..', '..', '..', 'ambit.wms.app', 'db'));
      final index = (await Indexer.open(db)).$1;
      var edges = 0;
      for (final s in schemasWithTables(index)) {
        edges += erModel(index, schema: s).edges.length;
      }
      print('wms: ${schemasWithTables(index).length} schemas, $edges foreign keys');
      expect(edges, greaterThan(20));
    },
    tags: ['corpus'],
    skip: Directory(p.normalize(p.join(Directory.current.path, '..', '..', '..', 'ambit.wms.app', 'db'))).existsSync()
        ? false
        : 'missing',
  );
}
