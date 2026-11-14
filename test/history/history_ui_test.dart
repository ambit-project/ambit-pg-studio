import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pg_studio/app/workspace.dart';
import 'package:pg_studio/ui/home_page.dart';

import '../helpers.dart';

const _view = 'changelog/modules/10-sales/views/sales_app.order_list.sql';
const _alter = 'changelog/2026/1-ddl/20260101-02-sales-orders-add-note.sql';

void main() {
  testWidgets('Ctrl+Shift+H on a table: the timeline and the effective DDL; an entry opens its statement', (
    tester,
  ) async {
    final app = await pumpApp(tester, fixture('shop'));
    tester.state<HomePageState>(find.byType(HomePage)).setPanelHeight(500);
    final tab = await openFile(tester, app, _view, select: 0);
    tab.reveal(at(tab, 'sales.orders AS o', 3), at(tab, 'sales.orders AS o', 3));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(app.workspace.panel, BottomPanel.history);
    expect(tester.widget<Text>(find.byKey(const Key('history.title'))).data, 'table sales.orders: 4 changes');
    expect(tester.widget<SelectableText>(find.byKey(const Key('history.ddl'))).data, contains('    note text\n);'));
    await tester.tap(find.byKey(const Key('history.entry.2')));
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(app.workspace.current!.path, _alter);
  });
}
