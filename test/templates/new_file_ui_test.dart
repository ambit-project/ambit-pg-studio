import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';

import '../helpers.dart';

void main() {
  testWidgets('Ctrl+N: a new procedure in a module, the file opens and has no problems', (tester) async {
    final dir = copyFixture('modules');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = await pumpApp(tester, dir.path);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.enterText(find.byKey(const Key('new.name')), 'order_close');
    await tester.pump();
    final path = tester.widget<Text>(find.byKey(const Key('new.path'))).data!;
    expect(path, 'changelog/modules/00-platform/procedures/platform_app.order_close.sql');
    expect(find.textContaining('SET LOCAL ROLE fx_owner;'), findsOneWidget);
    await tester.tap(find.byKey(const Key('new.create')));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(File(p.join(dir.path, path)).existsSync(), isTrue);
    expect(app.workspace.current!.path, path);
    // No syntax error and no module rule; the fixture has no platform.require_actor_id, so that name is unresolved.
    final problems = app.project.index!.allProblems.where((x) => x.span.file == path).toList();
    expect(problems.where((x) => x.severity == Severity.error || x.code == 'module-rule'), isEmpty);
    expect(app.project.index!.objects.values.where((o) => o.key.qualified == 'platform_app.order_close'), hasLength(1));
  });
}
