import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pg_studio/app/project_controller.dart';
import 'package:pg_studio/app/workspace.dart';
import 'package:pg_studio/main.dart';
import 'package:pg_studio/ui/er_view.dart';
import 'package:pg_studio/ui/home_page.dart';

import '../helpers.dart';

const _ddl = 'changelog/2026/1-ddl/20260101-01-sales-create-schemas-and-tables.sql';

void main() {
  testWidgets('ER: the tables of a module with PK/FK, a click opens the table, Export PNG writes a picture', (
    tester,
  ) async {
    final app = await pumpApp(tester, fixture('shop'));
    final ws = app.workspace;
    tester.state<HomePageState>(find.byType(HomePage)).setPanelHeight(600);
    ws.showEr('module:sales');
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('er.count'))).data, '2 tables, 1 foreign keys');
    expect(find.byKey(const Key('er.table.sales.orders')), findsOneWidget);
    final er = find.byType(ErView);
    expect(find.descendant(of: er, matching: find.byIcon(Icons.key)), findsNWidgets(2));
    expect(find.descendant(of: er, matching: find.byIcon(Icons.link)), findsOneWidget);
    await tester.tap(find.byKey(const Key('er.table.sales.customers')));
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(ws.current!.path, _ddl);
    expect(ws.current!.controller.selectedText, 'sales.customers');

    final out = p.join(Directory.systemTemp.createTempSync('pg_er_').path, 'sales.png');
    ws.pickSavePath = (_) async => out;
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('er.export')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    final bytes = File(out).readAsBytesSync();
    expect(bytes.sublist(1, 4), 'PNG'.codeUnits);
  });

  testWidgets('ER 3.1: Reset view brings back the default zoom, the diagram opens in a new window', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    final ws = app.workspace;
    tester.state<HomePageState>(find.byType(HomePage)).setPanelHeight(600);
    ws.showEr('module:sales');
    await tester.pump();
    final state = tester.state<ErViewState>(find.byType(ErView));
    state.transform.value = Matrix4.identity()..scaleByDouble(1.8, 1.8, 1, 1);
    await tester.pump();
    await tester.tap(find.byKey(const Key('er.resetView')));
    await tester.pump();
    expect(state.transform.value, Matrix4.identity());

    final launched = <List<String>>[];
    ws.launchWindow = (args) async => launched.add(args);
    await tester.tap(find.byKey(const Key('er.newWindow')));
    await tester.pump();
    expect(launched, [
      [ws.project.root!, '--er=module:sales'],
    ]);
    expect(erScopeOf(launched.single), 'module:sales');
    expect(erScopeOf([ws.project.root!]), isNull);
  });

  testWidgets('ER 3.1: the window with only the diagram keeps the tabs of the folder untouched', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = tempSettings();
    final saved = {
      fixture('shop'): {
        'tabs': [
          {'path': _ddl, 'offset': 0},
        ],
        'active': 0,
      },
    };
    settings.write('sessions', saved);
    final project = ProjectController(settings: settings);
    final ws = Workspace(project, watchDisk: false, keepSession: false);
    await tester.pumpWidget(PgStudioApp(workspace: ws, erScope: 'schema:sales', themeMode: ThemeMode.dark));
    await tester.runAsync(() => startup(project, [fixture('shop'), '--er=schema:sales'], workspace: ws));
    await settle(tester, project);
    expect(find.byType(HomePage), findsNothing);
    expect(find.byKey(const Key('er.window.title')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('er.count'))).data, '2 tables, 1 foreign keys');
    expect(find.byKey(const Key('er.newWindow')), findsNothing);
    expect(find.byKey(const Key('er.resetView')), findsOneWidget);
    // A click on a table does not open a tab: the window has no editor.
    await tester.tap(find.byKey(const Key('er.table.sales.orders')));
    await tester.pump();
    expect(ws.tabs, isEmpty);
    ws.saveSession();
    expect(settings.read()['sessions'], saved);
  });
}
