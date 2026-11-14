import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pg_studio/app/workspace.dart';
import 'package:pg_studio/ui/home_page.dart';

import '../helpers.dart';

const _view = 'changelog/modules/10-sales/views/sales_app.order_list.sql';
const _ddl = 'changelog/2026/1-ddl/20260101-01-sales-create-schemas-and-tables.sql';

Future<void> frames(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('Ctrl+Shift+G: who uses the table and what it uses; a node opens its definition', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    final ws = app.workspace;
    final tab = await openFile(tester, app, _view, select: 0);
    tab.reveal(at(tab, 'sales.orders AS o', 3), at(tab, 'sales.orders AS o', 3));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(ws.panel, BottomPanel.graph);
    expect(find.text('used by (5)'), findsOneWidget);
    expect(find.text('uses (1)'), findsOneWidget);
    expect(find.text('sales_app.order_save'), findsOneWidget);
    expect(find.text('type, read, write'), findsOneWidget); // how order_save uses the table
    // A node opens its definition; the center too.
    await tester.tap(find.text('sales.customers'));
    await frames(tester);
    expect(ws.current!.path, _ddl);
    expect(ws.current!.controller.selectedText, 'sales.customers');
  });

  testWidgets('right-click on a node centers the graph on it', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    final ws = app.workspace;
    final orders = app.project.index!.objects.values.singleWhere((o) => o.key.qualified == 'sales.orders');
    ws.showGraph(orders);
    await tester.pump();
    await tester.tap(find.text('sales_app.order_save'), buttons: kSecondaryButton);
    await tester.pump();
    expect(ws.graphKey!.qualified, 'sales_app.order_save');
    expect(find.textContaining('uses ('), findsOneWidget);
  });

  testWidgets('the module graph: dependencies in number order, violations in red, a click opens a place', (
    tester,
  ) async {
    final app = await pumpApp(tester, fixture('modules'));
    final ws = app.workspace;
    tester.state<HomePageState>(find.byType(HomePage)).setPanelHeight(600);
    ws.showModuleGraph();
    await tester.pump();
    expect(find.text('4 modules, 6 dependencies, 5 uses against the rules'), findsOneWidget);
    expect(find.textContaining('20-orders → 30-billing   2 uses, 2 against the rules'), findsOneWidget);
    expect(find.textContaining('30-billing → 20-orders   1 uses'), findsOneWidget);
    await tester.tap(find.byKey(const Key('graph.module.orders.billing')));
    await frames(tester);
    expect(ws.current, isNotNull);
  });
}
