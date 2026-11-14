import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pg_studio/app/workspace.dart';
import 'package:pg_studio/ui/home_page.dart';

import '../helpers.dart';

void main() {
  testWidgets('module rules in Problems; Fix applies a quick fix as one edit and the problem goes away', (
    tester,
  ) async {
    final dir = copyFixture('rules');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = await pumpApp(tester, dir.path, size: const Size(1600, 1600));
    tester.state<HomePageState>(find.byType(HomePage)).setPanelHeight(1300);
    final problems = app.project.index!.allProblems;
    expect(problems.where((x) => x.code == 'module-rule'), hasLength(41));
    final i = problems.indexWhere((x) => x.fix == 'add-reset-role' && x.span.file.endsWith('shop_app.no_actor.sql'));
    app.workspace.showPanel(BottomPanel.problems);
    await tester.pump();
    await tester.tap(find.byKey(Key('problem.fix.$i')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    final tab = app.workspace.current!;
    expect(tab.path, endsWith('shop_app.no_actor.sql'));
    expect(tab.dirty, isTrue);
    expect(tab.text.trimRight(), endsWith('RESET ROLE;'));
    await tester.pump(Workspace.liveDelay + const Duration(milliseconds: 50));
    for (var k = 0; k < 4; k++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(
      app.project.index!.allProblems.where(
        (x) => x.span.file == tab.path && x.message.contains("last statement must be 'RESET ROLE;'"),
      ),
      isEmpty,
    );
  });
}
