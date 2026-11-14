import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pg_studio/app/workspace.dart';
import 'package:pg_studio/ui/home_page.dart';

import '../helpers.dart';

const _view = 'changelog/modules/10-sales/views/sales_app.order_list.sql';
const _ddl = 'changelog/2026/1-ddl/20260101-01-sales-create-schemas-and-tables.sql';

Future<void> io(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
  }
}

void main() {
  testWidgets('Ctrl+Shift+F, regex and path filter, a click opens the match', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    tester.state<HomePageState>(find.byType(HomePage)).setPanelHeight(500);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(app.workspace.panel, BottomPanel.search);
    await tester.enterText(find.byKey(const Key('search.query')), 'sales.customers');
    await tester.pump();
    final count = tester.widget<Text>(find.byKey(const Key('search.count'))).data!;
    expect(count, matches(RegExp(r'^\d+ matches in \d+ files$')));
    await tester.enterText(find.byKey(const Key('search.paths')), 'views/');
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('search.count'))).data, '1 matches in 1 files');
    final hit = app.workspace.searchHits.single;
    await tester.tap(find.byKey(Key('search.hit.${hit.path}:${hit.start}')));
    await io(tester);
    expect(app.workspace.current!.path, _view);
    expect(app.workspace.current!.controller.selectedText, 'sales.customers');
  });

  testWidgets('Replace all: preview warns about deployed changesets, Apply changes the editable files only', (
    tester,
  ) async {
    final dir = copyFixture('shop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = await pumpApp(tester, dir.path);
    final ws = app.workspace;
    ws.filesInMain = (_) => app.project.index!.order.toSet();
    tester.state<HomePageState>(find.byType(HomePage)).setPanelHeight(500);
    ws.openSearch(query: 'sales.customers');
    await tester.pump();
    await tester.enterText(find.byKey(const Key('search.replacement')), 'sales.clients');
    await tester.tap(find.byKey(const Key('search.replaceAll')));
    await tester.pump();
    expect(find.textContaining('left as they are (deployed changeset)'), findsWidgets);
    await tester.tap(find.byKey(const Key('rename.apply')));
    await io(tester);
    expect(File(p.join(dir.path, _view)).readAsStringSync(), contains('JOIN sales.clients AS c'));
    expect(File(p.join(dir.path, _ddl)).readAsStringSync(), contains('REFERENCES sales.customers'));
  });
}
