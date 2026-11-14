import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

late ProjectIndex index;

/// Completion with the cursor at `|` in [text].
Completion at(String text) {
  final offset = text.indexOf('|');
  return complete(index, text.replaceFirst('|', ''), offset);
}

List<String> labels(Completion c) => [for (final i in c.items) i.label];

void main() {
  setUpAll(() async {
    index = (await Indexer.open(p.join(Directory.current.path, 'test', 'fixtures', 'shop'))).$1;
  });

  test('after schema. : its objects with their kinds, overloads once', () {
    final c = at('SELECT sales_app.|');
    expect(labels(c), containsAll(['order_list', 'order_save', 'order_total', 'order_line_input']));
    expect(labels(c).where((l) => l == 'order_total'), hasLength(1));
    expect(c.items.firstWhere((i) => i.label == 'order_list').kind, CompletionKind.view);
    final typed = at('SELECT sales_app.order_t|');
    expect(labels(typed), ['order_total']);
    expect(typed.prefix, 'order_t');
  });

  test('after alias. : the columns of the aliased table or view', () {
    final c = at('SELECT o.| FROM sales.orders AS o JOIN sales.customers c ON c.id = o.customer_id');
    expect(labels(c), ['customer_id', 'id', 'note']); // after ALTER TABLE: total dropped, note added
    expect(c.items.first.detail, contains('sales.orders'));
    expect(labels(at('SELECT c.n| FROM sales.orders AS o JOIN sales.customers c ON c.id = o.customer_id')), ['name']);
    expect(labels(at('UPDATE sales.orders SET status = 1 WHERE orders.|')), contains('customer_id'));
    expect(labels(at('SELECT v.| FROM sales_app.order_list AS v')), ['customer_name', 'id', 'note']);
    // INTO a variable before FROM: the FROM is not taken as the variable's alias.
    expect(labels(at('SELECT o.* INTO v_order FROM sales.orders AS o WHERE o.cu| FOR UPDATE')), ['customer_id']);
  });

  test('after FROM / JOIN: relations (no indexes, no routines)', () {
    final c = at('SELECT 1 FROM sal|');
    expect(labels(c), containsAll(['sales', 'sales.orders', 'sales.customers', 'sales_app.order_list']));
    expect(c.items.where((i) => i.kind == CompletionKind.function || i.kind == CompletionKind.keyword), isEmpty);
    expect(labels(at('SELECT 1 FROM sales.orders o JOIN |')), contains('sales.customers'));
  });

  test('after CALL: procedures; elsewhere objects then keywords', () {
    final call = at('BEGIN CALL |');
    expect(call.items.where((i) => i.kind != CompletionKind.schema).map((i) => i.label), ['sales_app.order_save']);
    final c = at('SEL|');
    expect(labels(c), contains('SELECT'));
    expect(c.items.firstWhere((i) => i.label == 'SELECT').kind, CompletionKind.keyword);
    expect(labels(at('sel|')), contains('select')); // the case of what is typed
    expect(at('x := | ').items, isEmpty); // nothing typed, no clause: no popup
  });

  test('signature help inside a call with the current parameter', () {
    final none = at('PERFORM sales_app.order_total(|');
    expect(none.signature!.signatures.map((o) => o.key.signature), unorderedEquals(['uuid', 'uuid,bool']));
    expect(none.signature!.activeParameter, 0);
    final second = at("CALL sales_app.order_save(p_id, coalesce(a, 'x,y'), |");
    expect(second.signature!.signatures.single.signature, startsWith('sales_app.order_save(p_id uuid'));
    expect(second.signature!.activeParameter, 2);
    expect(at('SELECT count(|').signature, isNull); // built-in, unknown to the project
    expect(at('SELECT sales_app.order_total(p_id) + |').signature, isNull); // the call is closed
  });
}
