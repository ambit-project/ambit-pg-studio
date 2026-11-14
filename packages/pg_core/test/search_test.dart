import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

late ProjectIndex index;

void main() {
  setUpAll(() async {
    index = (await Indexer.open(p.join(Directory.current.path, 'test', 'fixtures', 'shop'))).$1;
  });

  test('plain text, case, whole word, path filter', () {
    final all = searchProject(index, 'sales.orders').hits;
    expect(all.length, greaterThan(5));
    expect(all.first.lineText, contains('sales.orders'));
    expect(searchProject(index, 'SALES.ORDERS', caseSensitive: true).hits, isEmpty);
    expect(searchProject(index, 'sale', wholeWord: true).hits, isEmpty);
    expect(searchProject(index, 'sale').hits, isNotEmpty);
    expect(searchProject(index, 'sales.orders', pathFilter: 'views/').hits.map((h) => h.path).toSet(), {
      'changelog/modules/10-sales/views/sales_app.order_list.sql',
    });
  });

  test('regular expressions and their errors', () {
    final r = searchProject(index, r"ERRCODE = '(U\d+)'", regex: true);
    expect(r.hits.single.match.group(1), 'U1101');
    expect(searchProject(index, '(', regex: true).error, startsWith('Invalid regular expression'));
  });

  test('replace: groups in regex replacements; deployed changesets skipped with a warning', () {
    final hits = searchProject(index, r'sales\.(orders|customers)\b', regex: true).hits;
    final inMain = index.order.toSet();
    final plan = replacePlan(index, hits, r'sales.$1', regex: true, inMain: inMain);
    expect(plan.edits.keys, isNot(contains('changelog/2026/1-ddl/20260101-01-sales-create-schemas-and-tables.sql')));
    expect(plan.warnings.where((w) => w.contains('20260101-01-sales-create-schemas-and-tables.sql')), hasLength(1));
    final edit = plan.edits['changelog/modules/10-sales/views/sales_app.order_list.sql']!.first;
    expect(edit.replacement, anyOf('sales.orders', 'sales.customers'));
    final all = replacePlan(index, hits, 'x', inMain: const {});
    expect(all.warnings, isEmpty);
    expect(all.editCount, hits.length);
  });
}
