import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pg_studio/app/workspace.dart';
import 'package:pg_studio/ui/editor_view.dart';

import '../helpers.dart';

const _ddl = 'changelog/2026/1-ddl/20260101-01-sales-create-schemas-and-tables.sql';
const _alter = 'changelog/2026/1-ddl/20260101-02-sales-orders-add-note.sql';
const _save = 'changelog/modules/10-sales/procedures/sales_app.order_save.sql';
const _total = 'changelog/modules/10-sales/functions/sales_app.order_total.sql';
const _view = 'changelog/modules/10-sales/views/sales_app.order_list.sql';
const _grants = 'changelog/2026/1-ddl/20260101-03-grants.sql';

Future<void> frames(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await tester.pump();
  await tester.pump();
}

/// Moves the text cursor to [offset] of the current tab.
Future<void> cursorAt(WidgetTester tester, EditorTab tab, int offset) async {
  tab.reveal(offset, offset);
  await tester.pump();
}

/// The global position of [offset] in the visible editor.
Offset screenPoint(WidgetTester tester, int offset) {
  final state = tester.state<EditorViewState>(find.byType(EditorView));
  final local = state.pointOf(offset);
  if (local == null) throw StateError('offset $offset not visible');
  return tester.getTopLeft(find.byType(EditorView)) + local;
}

/// 1-based line of the cursor in the current tab.
int cursorLine(Workspace ws) => ws.current!.lineColumn(ws.current!.cursorOffset).$1 + 1;

void main() {
  testWidgets('Ctrl+click on a call opens the definition of the right overload on its line', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    final tab = await openFile(tester, app, _save, select: 0);
    await frames(tester);
    final call = tab.text.indexOf('sales_app.order_total(p_id, true)');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(screenPoint(tester, call + 12));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await frames(tester);
    final ws = app.workspace;
    expect(ws.current!.path, _total);
    expect(cursorLine(ws), 11); // CREATE OR REPLACE FUNCTION sales_app.order_total(p_id uuid, p_with_tax boolean)
    final selected = ws.current!.controller.selectedText;
    expect(selected, 'sales_app.order_total');
    // The click focused an editor: losing focus stops re_editor's cursor blink timer before the test ends.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('Ctrl+click works in a scrolled editor (pointer -> text with the scroll position)', (tester) async {
    final app = await pumpApp(tester, fixture('shop'), size: const Size(1600, 640));
    final tab = await openFile(tester, app, _save, select: 0);
    final missing = tab.text.indexOf('sales_app.missing_proc');
    final call = tab.text.indexOf('sales_app.order_total(p_id, true)');
    tab.reveal(missing, missing); // scrolls down
    await frames(tester);
    expect(tab.scroll.verticalScroller.offset, greaterThan(0));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(screenPoint(tester, call + 12));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await frames(tester);
    expect(app.workspace.current!.path, _total);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('F12 on a table opens CREATE TABLE; on the ALTER TABLE name it offers CREATE and ALTER', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    final ws = app.workspace;
    final tab = await openFile(tester, app, _save, select: 0);
    await cursorAt(tester, tab, at(tab, 'sales.orders (id, customer_id)', 3));
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await frames(tester);
    expect(ws.current!.path, _ddl);
    expect(cursorLine(ws), 13);

    final alter = await openFile(tester, app, _alter, select: 0);
    await cursorAt(tester, alter, at(alter, 'sales.orders ADD', 2));
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await frames(tester);
    expect(find.byKey(const Key('quickpick.item.0')), findsOneWidget);
    expect(find.byKey(const Key('quickpick.item.1')), findsOneWidget);
    expect(find.textContaining('CREATE sales.orders'), findsOneWidget);
    expect(find.textContaining('ALTER sales.orders'), findsOneWidget);
    await tester.tap(find.byKey(const Key('quickpick.item.0')));
    await frames(tester);
    expect(ws.current!.path, _ddl);
  });

  testWidgets('Shift+F12 lists reads, writes and other uses; a click opens the place', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    final ws = app.workspace;
    final tab = await openFile(tester, app, _view, select: 0);
    await cursorAt(tester, tab, at(tab, 'sales.orders AS o', 2));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await frames(tester);
    expect(ws.panel, BottomPanel.references);
    expect(ws.references!.title, contains('table sales.orders: 8 references'));
    expect(ws.references!.places.map((g) => (g.$1, g.$2.length)), [('Reads', 3), ('Writes', 2), ('Other uses', 3)]);
    expect(find.text('Reads (3)'), findsOneWidget);
    expect(find.text('Writes (2)'), findsOneWidget);
    final write = ws.references!.places[1].$2.first.$1;
    await tester.tap(find.byKey(Key('reference.${write.path}:${write.offset}')));
    await frames(tester);
    expect(ws.current!.path, _save);
    expect(ws.current!.cursorOffset, write.offset + write.length);
  });

  testWidgets('hover shows the signature, the columns and the changeset comment', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    final tab = await openFile(tester, app, _save, select: 0);
    await frames(tester);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(screenPoint(tester, tab.text.indexOf('sales_app.order_total(p_id);') + 5));
    await tester.pump(const Duration(milliseconds: 500));
    final card = find.byKey(const Key('editor.hover'));
    expect(card, findsOneWidget);
    final text = tester.widget<Text>(find.descendant(of: card, matching: find.byType(Text))).data!;
    expect(text, contains('function sales_app.order_total(p_id uuid) RETURNS numeric'));
    expect(text, contains('-- Suma zamówienia'));

    await gesture.moveTo(screenPoint(tester, tab.text.indexOf('sales.customers AS c') + 3));
    await tester.pump(const Duration(milliseconds: 500));
    final table = tester
        .widget<Text>(find.descendant(of: find.byKey(const Key('editor.hover')), matching: find.byType(Text)))
        .data!;
    expect(table, contains('table sales.customers'));
    expect(table, contains('  id uuid NOT NULL'));
    expect(table, contains('  name text NOT NULL'));
  });

  testWidgets('Ctrl+T objects, Ctrl+P files, Alt+Left/Right back and forward', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    final ws = app.workspace;
    await openFile(tester, app, _save, select: 0);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.enterText(find.byKey(const Key('quickpick.query')), 'order_list');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await frames(tester);
    expect(ws.current!.path, _view);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.enterText(find.byKey(const Key('quickpick.query')), 'grants');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await frames(tester);
    expect(ws.current!.path, _grants);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await frames(tester);
    expect(ws.current!.path, _view);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await frames(tester);
    expect(ws.current!.path, _save);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await frames(tester);
    expect(ws.current!.path, _view);
  });
}
