import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

String fixture(String name) => p.join(Directory.current.path, 'test', 'fixtures', name);

void main() {
  test('an object: what uses it and what it uses, with how', () async {
    final index = (await Indexer.open(fixture('shop'))).$1;
    final orders = index.objects.values.singleWhere((o) => o.key.qualified == 'sales.orders');
    final g = objectGraph(index, orders);
    expect(
      {for (final n in g.users) n.label: n.kinds},
      {
        'sales.orders_customer_ix': {RefKind.indexOn},
        'sales.orders_touch': {RefKind.trigger},
        'sales_app.order_save': {RefKind.type, RefKind.read, RefKind.write},
        'sales_app.order_total': {RefKind.read},
        'sales_app.order_list': {RefKind.read},
      },
    );
    expect(g.users.firstWhere((n) => n.label == 'sales_app.order_save').writes, isTrue);
    expect(
      {for (final n in g.uses) n.label: n.kinds},
      {
        'sales.customers': {RefKind.foreignKey},
      },
    );

    final save = index.objects.values.singleWhere((o) => o.key.qualified == 'sales_app.order_save');
    final s = objectGraph(index, save);
    expect(s.uses.map((n) => n.label), containsAll(['sales.orders', 'sales.customers', 'sales_app.order_total']));
    expect(s.users.map((n) => n.label), ['20260101-03-grants.sql']); // GRANT outside a definition: the file
  });

  test('modules: who uses whom, how often, with the violations of the rules', () async {
    final index = (await Indexer.open(fixture('modules'))).$1;
    final g = moduleGraph(index);
    expect(g.modules.map((m) => m.label), ['00-platform', '10-partners', '20-orders', '30-billing']);
    expect(
      [for (final e in g.edges) '${e.from.name}->${e.to.name} ${e.count}/${e.violations}'],
      [
        'orders->platform 3/1',
        'orders->partners 4/2',
        'orders->billing 2/2',
        'billing->platform 1/0',
        'billing->partners 1/0',
        'billing->orders 1/0',
      ],
    );
  });
}
