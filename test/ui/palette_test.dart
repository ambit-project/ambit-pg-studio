import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pg_studio/app/workspace.dart';

import '../helpers.dart';

const _save = 'changelog/modules/10-sales/procedures/sales_app.order_save.sql';

Future<void> palette(WidgetTester tester, String query) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('quickpick.query')), query);
  await tester.pumpAndSettle();
}

Finder item(int i) => find.byKey(Key('quickpick.item.$i'));

void main() {
  testWidgets('Ctrl+Shift+P: commands by name or description, the shortcut, unavailable ones with the reason', (
    tester,
  ) async {
    final app = await pumpApp(tester, fixture('shop'));
    await palette(tester, 'impact');
    expect(find.descendant(of: item(0), matching: find.text('Impact of a change')), findsOneWidget);
    expect(find.descendant(of: item(0), matching: find.text('Shift+Alt+F12')), findsOneWidget);
    expect(find.descendant(of: item(0), matching: find.text('not available: no file is open')), findsOneWidget);
    // Enter on an unavailable command does nothing; the palette stays open.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quickpick.query')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // Found by its description: "ER diagram" is in the description of the dependency graph.
    await palette(tester, 'er diagram');
    expect(find.descendant(of: item(0), matching: find.text('Dependency graph')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // With the cursor on a table, Enter runs the command.
    final tab = await openFile(tester, app, _save);
    final at = tab.text.indexOf('sales.orders AS o') + 8;
    tab.reveal(at, at);
    await tester.pump();
    await palette(tester, 'impact');
    expect(find.descendant(of: item(0), matching: find.text('Navigation')), findsNothing);
    expect(find.descendant(of: item(0), matching: find.text('Changes and refactoring')), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(app.workspace.panel, BottomPanel.references);
    expect(app.workspace.references!.title, startsWith('Impact of changing sales.orders'));
  });
}
