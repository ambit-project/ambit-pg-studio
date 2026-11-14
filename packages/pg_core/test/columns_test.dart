import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

final _shop = p.join(Directory.current.path, 'test', 'fixtures', 'shop');
const _save = 'changelog/modules/10-sales/procedures/sales_app.order_save.sql';
const _view = 'changelog/modules/10-sales/views/sales_app.order_list.sql';
const _ddl = 'changelog/2026/1-ddl/20260101-01-sales-create-schemas-and-tables.sql';
const _alter = 'changelog/2026/1-ddl/20260101-02-sales-orders-add-note.sql';

late ProjectIndex index;

String text(SourceSpan s) => index.files[s.file]!.text.substring(s.start, s.end);
int line(SourceSpan s) => index.files[s.file]!.lineColumn(s.start).$1 + 1;
ObjectKey key(String q) => index.objects.values.firstWhere((o) => o.key.qualified == q).key;

void main() {
  setUpAll(() async {
    index = (await Indexer.open(_shop)).$1;
  });

  test('alias.column, INSERT column lists and UPDATE SET targets (writes), bare names of the only relation', () {
    final uses = [
      for (final u in index.columnUses)
        if (u.span.file == _save) '${line(u.span)} ${u.kind.label} ${u.relation.qualified}.${u.column}',
    ];
    expect(uses, [
      '23 read sales.customers.id',
      '26 read sales.orders.id',
      '28 write sales.orders.id',
      '28 write sales.orders.customer_id',
      '30 write sales.orders.customer_id',
      '30 read sales.orders.id',
    ]);
    // p_id, p_customer_id (parameters) and v_order (a variable) are never columns.
    expect(index.columnUses.where((u) => const {'p_id', 'p_customer_id', 'v_order'}.contains(u.column)), isEmpty);
  });

  test('a view: the columns of its tables by alias, also in JOIN ... ON', () {
    final uses = {
      for (final u in index.columnUses)
        if (u.span.file == _view) '${u.relation.qualified}.${u.column}',
    };
    expect(uses, {
      'sales.orders.id',
      'sales.customers.name',
      'sales.orders.note',
      'sales.customers.id',
      'sales.orders.customer_id',
    });
  });

  test('columnAt on a use and on a definition; the definition of a column added by ALTER TABLE', () {
    final note = index.columnUses.firstWhere((u) => u.span.file == _view && u.column == 'note');
    final at = index.columnAt(_view, note.span.start + 1)!;
    expect((at.relation.qualified, at.column), ('sales.orders', 'note'));
    final def = index.columnDefinition(at.relation, 'note')!;
    expect((def.file, text(def)), (_alter, 'note'));
    final idDef = index.columnDefinition(key('sales.orders'), 'customer_id')!;
    expect((idDef.file, line(idDef)), (_ddl, 15));
    final onDef = index.columnAt(_ddl, idDef.start)!;
    expect((onDef.column, onDef.use), ('customer_id', null));
  });

  test('column uses by kind', () {
    final uses = index.columnUsesOf(key('sales.orders'), 'customer_id');
    expect(uses.map((u) => (u.kind, u.span.file)).toSet(), {(RefKind.write, _save), (RefKind.read, _view)});
  });

  test('impact of a column and of a table, also through a view built on a view', () {
    final extra = analyzeFile(
      'changelog/modules/10-sales/views/sales_app.order_report.sql',
      'CREATE VIEW sales_app.order_report AS SELECT l.id, l.note FROM sales_app.order_list AS l;',
    );
    final files = {...index.files, extra.path: extra};
    final more = ProjectIndex.link(_shop, files, [...index.order, extra.path]);
    final orders = more.objects.values.firstWhere((o) => o.key.qualified == 'sales.orders').key;
    final note = more.impactOf(orders, column: 'note');
    expect(
      [for (final i in note) (i.object.key.qualified, i.level)],
      [('sales_app.order_list', 1), ('sales_app.order_report', 2)],
    );
    final table = more.impactOf(orders);
    expect(
      table.map((i) => i.object.key.qualified),
      containsAll(['sales_app.order_save', 'sales_app.order_total', 'sales_app.order_list', 'sales_app.order_report']),
    );
    expect(
      table.firstWhere((i) => i.object.key.qualified == 'sales_app.order_save').how,
      containsAll([RefKind.read, RefKind.write]),
    );
  });
}
