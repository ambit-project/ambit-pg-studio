import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pg_studio/app/workspace.dart';
import 'package:pg_studio/ui/editor_view.dart';

import '../helpers.dart';

const _view = 'changelog/modules/10-sales/views/sales_app.order_list.sql';
const _alter = 'changelog/2026/1-ddl/20260101-02-sales-orders-add-note.sql';

Future<void> frames(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('F12 on a column opens its definition (ALTER TABLE ADD COLUMN)', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    final tab = await openFile(tester, app, _view, select: 0);
    tab.reveal(at(tab, 'o.note', 3), at(tab, 'o.note', 3));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await frames(tester);
    expect(app.workspace.current!.path, _alter);
    expect(app.workspace.current!.controller.selectedText, 'note');
  });

  testWidgets('Shift+F12 on a column: reads and writes; hover shows the type and the counts', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    final ws = app.workspace;
    final tab = await openFile(tester, app, _view, select: 0);
    final c = at(tab, 'o.customer_id', 3);
    tab.reveal(c, c);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await frames(tester);
    expect(ws.references!.title, 'column sales.orders.customer_id: 3 uses');
    expect(ws.references!.places.map((g) => (g.$1, g.$2.length)), [('Reads', 1), ('Writes', 2)]);
    expect(ws.hoverAt(_view, c), startsWith('column sales.orders.customer_id uuid NOT NULL\n1 reads, 2 writes'));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    final view = find.byWidgetPredicate((w) => w is EditorView && w.tab == tab);
    await gesture.moveTo(tester.getTopLeft(view) + tester.state<EditorViewState>(view).pointOf(c)!);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('editor.hover')), findsOneWidget);
  });

  testWidgets('Shift+Alt+F12: impact of changing a table', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    final ws = app.workspace;
    final tab = await openFile(tester, app, _view, select: 0);
    tab.reveal(at(tab, 'sales.orders AS o', 3), at(tab, 'sales.orders AS o', 3));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await frames(tester);
    expect(ws.panel, BottomPanel.references);
    expect(ws.references!.title, startsWith('Impact of changing sales.orders:'));
    final direct = ws.references!.places.first;
    expect(direct.$1, 'Uses it directly');
    expect(direct.$2.map((x) => x.$2), contains('procedure: type, read, write'));
  });
}
