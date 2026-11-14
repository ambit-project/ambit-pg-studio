import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers.dart';

const _view = 'changelog/modules/10-sales/views/sales_app.order_list.sql';
const _newView = 'changelog/modules/10-sales/views/sales_app.order_overview.sql';
const _save = 'changelog/modules/10-sales/procedures/sales_app.order_save.sql';

Future<void> io(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
  }
}

void main() {
  testWidgets('F2 on a view: new name, preview with warnings, Apply renames the file and the object', (tester) async {
    final dir = copyFixture('shop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = await pumpApp(tester, dir.path);
    final ws = app.workspace;
    ws.filesInMain = (_) => app.project.index!.order.toSet(); // everything deployed
    final tab = await openFile(tester, app, _view, select: 0);
    final at = tab.text.indexOf('sales_app.order_list') + 12;
    tab.reveal(at, at);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pump();
    await tester.enterText(find.byKey(const Key('rename.name')), 'order_overview');
    await tester.tap(find.byKey(const Key('rename.next')));
    await tester.pump();
    expect(find.byKey(const Key('rename.preview')), findsOneWidget);
    expect(find.textContaining('ALTER VIEW sales_app.order_list RENAME TO order_overview;'), findsOneWidget);
    expect(find.textContaining('grant left as it is (deployed changeset)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('rename.apply')));
    await io(tester);
    expect(File(p.join(dir.path, _newView)).existsSync(), isTrue);
    expect(File(p.join(dir.path, _view)).existsSync(), isFalse);
    expect(ws.current!.path, _newView);
    expect(app.project.index!.objects.values.where((o) => o.key.qualified == 'sales_app.order_overview'), hasLength(1));
  });

  testWidgets('an invalid name is shown in the preview and nothing is written; unsaved files stop the rename', (
    tester,
  ) async {
    final dir = copyFixture('shop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = await pumpApp(tester, dir.path);
    final ws = app.workspace;
    ws.filesInMain = (_) => app.project.index!.order.toSet();
    final tab = await openFile(tester, app, _save, select: 0);
    final at = tab.text.indexOf('sales.customers') + 8;
    tab.reveal(at, at);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pump();
    await tester.enterText(find.byKey(const Key('rename.name')), 'Bad Name');
    await tester.tap(find.byKey(const Key('rename.next')));
    await tester.pump();
    expect(find.byKey(const Key('rename.error')), findsOneWidget);
    expect(find.byKey(const Key('rename.apply')), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    // An unsaved edit in a file the rename touches: refused, nothing written.
    tab.controller.selectAll();
    tab.controller.replaceSelection('-- edit\n${tab.savedText}');
    await tester.pump();
    final plan = ws.planRenameOf(
      app.project.index!.objects.values.firstWhere((o) => o.key.qualified == 'sales.customers').key,
      null,
      'clients',
    );
    final refused = await tester.runAsync(() => ws.applyRename(plan));
    expect(refused, startsWith('Save or close first: $_save'));
    expect(File(p.join(dir.path, _save)).readAsStringSync(), contains('sales.customers'));
    await tester.pump(const Duration(milliseconds: 400));
    await io(tester);
  });
}
