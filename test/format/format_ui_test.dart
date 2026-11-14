import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers.dart';

const _view = 'changelog/modules/10-sales/views/sales_app.order_list.sql';
const _ddl = 'changelog/2026/1-ddl/20260101-01-sales-create-schemas-and-tables.sql';

Future<void> ctrlShift(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

Future<void> settleLive(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
  }
}

void main() {
  testWidgets('Ctrl+Shift+I formats the file as one edit, Ctrl+Z brings it back', (tester) async {
    final dir = copyFixture('shop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File(p.join(dir.path, _view));
    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst('FROM sales.orders AS o', '      FROM sales.orders AS o'),
    );
    final app = await pumpApp(tester, dir.path);
    final ws = app.workspace;
    ws.inMainBranch = (_, _) => true;
    final tab = await openFile(tester, app, _view, select: 0);
    final before = tab.text;
    await ctrlShift(tester, LogicalKeyboardKey.keyI);
    expect(tab.text, contains('\nFROM sales.orders AS o'));
    expect(tab.dirty, isTrue);
    expect(find.textContaining('Formatted 1 statement'), findsOneWidget);
    tab.controller.undo();
    await tester.pump();
    expect(tab.text, before);
    await settleLive(tester);
  });

  testWidgets('a deployed changeset is left as written and the summary says why', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    app.workspace.inMainBranch = (_, _) => true; // the DDL file is in main: deployed
    final tab = await openFile(tester, app, _ddl, select: 0);
    final before = tab.text;
    await ctrlShift(tester, LogicalKeyboardKey.keyI);
    expect(tab.text, before);
    expect(find.textContaining('left as written: 1× changeset without runOnChange'), findsOneWidget);
  });

  testWidgets('format on save from .pgstudio.json', (tester) async {
    final dir = copyFixture('shop');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, '.pgstudio.json')).writeAsStringSync('{"format": {"formatOnSave": true}}');
    final file = File(p.join(dir.path, _view));
    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst('FROM sales.orders AS o', '      FROM sales.orders AS o'),
    );
    final app = await pumpApp(tester, dir.path);
    app.workspace.inMainBranch = (_, _) => true;
    expect(app.workspace.formatOptions.formatOnSave, isTrue);
    await openFile(tester, app, _view, select: 0);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settleLive(tester);
    expect(file.readAsStringSync(), contains('\nFROM sales.orders AS o'));
  });
}
