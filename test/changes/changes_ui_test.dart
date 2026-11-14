import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pg_studio/ui/home_page.dart';

import '../helpers.dart';

const _view = 'changelog/modules/10-sales/views/sales_app.order_list.sql';
const _ddl = 'changelog/2026/1-ddl/20260101-01-sales-create-schemas-and-tables.sql';

void git(String dir, List<String> args) =>
    Process.runSync('git', ['-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t.invalid', ...args]);

void main() {
  testWidgets('Changes: objects of the branch, a touched deployed changeset, a click opens the object', (tester) async {
    final repo = Directory.systemTemp.createTempSync('pg_branch_ui_');
    addTearDown(() => repo.deleteSync(recursive: true));
    Process.runSync('cp', ['-r', '${fixture('shop')}/.', repo.path]);
    git(repo.path, ['init', '-q', '-b', 'main']);
    git(repo.path, ['add', '.']);
    git(repo.path, ['commit', '-q', '-m', 'main']);
    git(repo.path, ['checkout', '-q', '-b', 'feature']);
    final view = File(p.join(repo.path, _view));
    view.writeAsStringSync(view.readAsStringSync().replaceFirst('o.note', 'o.note, o.id AS order_id'));
    final ddl = File(p.join(repo.path, _ddl));
    ddl.writeAsStringSync(ddl.readAsStringSync().replaceFirst('name text NOT NULL', 'name text'));

    final app = await pumpApp(tester, repo.path);
    final ws = app.workspace;
    tester.state<HomePageState>(find.byType(HomePage)).setPanelHeight(600);
    await tester.runAsync(() => ws.showChanges());
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('changes.title'))).data,
      startsWith('Branch feature against main: 2 files'),
    );
    expect(find.textContaining('a deployed changeset was changed'), findsOneWidget);
    await tester.tap(find.byKey(const Key('changes.object.sales_app.order_list')));
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(ws.current!.path, _view);
  });
}
