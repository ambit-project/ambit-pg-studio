import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pg_studio/app/commands.dart';
import 'package:pg_studio/app/workspace.dart';
import 'package:pg_studio/ui/home_page.dart';

import '../helpers.dart';
import '../nav/nav_test.dart' show frames, screenPoint;

const _save = 'changelog/modules/10-sales/procedures/sales_app.order_save.sql';
const _view = 'changelog/modules/10-sales/views/sales_app.order_list.sql';

HomePageState home(WidgetTester tester) => tester.state<HomePageState>(find.byType(HomePage));

Future<void> rightClick(WidgetTester tester, Offset at) async {
  await tester.tapAt(at, buttons: kSecondaryButton);
  await tester.pumpAndSettle();
}

Future<void> pick(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(Key('menu.$id')));
  await tester.pumpAndSettle();
}

bool enabled(WidgetTester tester, String id) =>
    tester.widget<PopupMenuItem<Object?>>(find.byKey(Key('menu.$id'))).enabled;

void main() {
  testWidgets('the registry: names, descriptions, unique keys; every global command has an action and its keys work', (
    tester,
  ) async {
    final ids = <String>{};
    final keys = <String, String>{};
    for (final c in appCommands) {
      expect(ids.add(c.id), isTrue, reason: 'duplicate id ${c.id}');
      expect(c.title, isNotEmpty);
      expect(c.description.length, greaterThan(10), reason: c.id);
      if (c.editorKeys) continue;
      for (final k in c.keys) {
        final label = shortcutLabel(k);
        expect(keys[label], isNull, reason: '$label is on ${keys[label]} and ${c.id}');
        keys[label] = c.id;
      }
    }
    expect(shortcutLabel(command('nav.impact').keys.first), 'Shift+Alt+F12');
    expect(shortcutLabel(command('nav.back').keys.first), 'Alt+Left');

    final app = await pumpApp(tester, fixture('shop'));
    final actions = home(tester).actions;
    for (final c in appCommands.where((c) => c.global && !c.editorKeys)) {
      expect(actions[c.id], isNotNull, reason: 'no action for ${c.id}');
    }
    for (final id in actions.keys) {
      expect(() => command(id), returnsNormally, reason: '$id is not in the registry');
    }

    // Keys come from the registry: Ctrl+Shift+F opens the search, Ctrl+= makes the font larger.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(app.workspace.panel, BottomPanel.search);
    final font = app.workspace.settings.fontSize;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(app.workspace.settings.fontSize, font + 1);
    // Toolbar tooltips are the registry's titles and keys.
    expect(find.byTooltip('Impact of a change (Shift+Alt+F12)'), findsOneWidget);
  });

  testWidgets('right click in the editor: commands for the name under the pointer, disabled ones stay listed', (
    tester,
  ) async {
    final app = await pumpApp(tester, fixture('shop'));
    final tab = await openFile(tester, app, _save, select: 0);
    await frames(tester);
    final table = tab.text.indexOf('sales.orders AS o');
    await rightClick(tester, screenPoint(tester, table + 8));
    // The click moved the cursor onto the name.
    expect(tab.cursorOffset, inInclusiveRange(table, table + 12));
    for (final id in ['nav.definition', 'nav.references', 'nav.impact', 'nav.graph', 'nav.history', 'edit.rename']) {
      expect(enabled(tester, id), isTrue, reason: id);
    }
    expect(enabled(tester, 'edit.copy'), isFalse); // nothing selected
    expect(
      find.descendant(of: find.byKey(const Key('menu.nav.references')), matching: find.text('Shift+F12')),
      findsOneWidget,
    );
    await pick(tester, 'nav.references');
    expect(app.workspace.panel, BottomPanel.references);
    expect(app.workspace.references!.title, startsWith('table sales.orders'));

    // On a keyword: no target, so the name commands are disabled.
    final keyword = tab.text.indexOf('LANGUAGE plpgsql');
    await rightClick(tester, screenPoint(tester, keyword + 2));
    expect(enabled(tester, 'nav.references'), isFalse);
    expect(enabled(tester, 'edit.rename'), isFalse);
    expect(enabled(tester, 'edit.format'), isTrue);
    await pick(tester, 'edit.selectAll');
    expect(tab.controller.selectedText, tab.text);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('right click on a tab: close others, close saved; copy path', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    await openFile(tester, app, _save);
    await openFile(tester, app, _view);
    await rightClick(tester, tester.getCenter(find.byKey(const Key('tab.$_view'))));
    await pick(tester, 'tab.closeOthers');
    expect(app.workspace.tabs.map((t) => t.path), [_view]);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    await rightClick(tester, tester.getCenter(find.byKey(const Key('tab.$_view'))));
    await pick(tester, 'path.copy');
    expect(copied, _view);
    await rightClick(tester, tester.getCenter(find.byKey(const Key('tab.$_view'))));
    await pick(tester, 'tab.closeSaved');
    expect(app.workspace.tabs, isEmpty);
  });

  testWidgets('right click in the trees and on a panel row', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });

    // A file in the Files tree (its folder is expanded at start).
    final file = find.byKey(
      const ValueKey('tree:file:changelog/2026/1-ddl/20260101-01-sales-create-schemas-and-tables.sql'),
    );
    await rightClick(tester, tester.getCenter(file));
    expect(find.byKey(const Key('menu.file.reveal')), findsOneWidget);
    await pick(tester, 'path.copy');
    expect(copied, 'changelog/2026/1-ddl/20260101-01-sales-create-schemas-and-tables.sql');

    // An object in the Objects tree: references and the ER diagram of its schema.
    await tester.tap(find.text('Objects'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tree:schema:sales')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tree:schema:sales:table')));
    await tester.pumpAndSettle();
    final orders = app.workspace.index!.objects.values.firstWhere((o) => o.key.qualified == 'sales.orders');
    await rightClick(tester, tester.getCenter(find.byKey(ValueKey('tree:obj:${orders.key}'))));
    expect(find.text('ER diagram of sales'), findsOneWidget);
    await pick(tester, 'nav.references');
    expect(app.workspace.references!.title, startsWith('table sales.orders'));
    await rightClick(tester, tester.getCenter(find.byKey(ValueKey('tree:obj:${orders.key}'))));
    await pick(tester, 'object.er');
    expect(app.workspace.panel, BottomPanel.graph);
    expect(app.workspace.erScope, 'schema:sales');
    final launched = <List<String>>[];
    app.workspace.launchWindow = (args) async => launched.add(args);
    await rightClick(tester, tester.getCenter(find.byKey(ValueKey('tree:obj:${orders.key}'))));
    await pick(tester, 'er.newWindow');
    expect(launched.single.last, '--er=schema:sales');

    // A row of the Problems panel: copy file:line:column.
    app.workspace.showPanel(BottomPanel.problems);
    await tester.pumpAndSettle();
    await rightClick(tester, tester.getCenter(find.byKey(const Key('problem.0'))));
    await pick(tester, 'row.copyLocation');
    expect(copied, matches(RegExp(r'^changelog/.+\.sql:\d+:\d+$')));
  });
}
