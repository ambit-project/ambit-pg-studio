import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pg_studio/app/commands.dart';
import 'package:pg_studio/app/help.dart';

import '../helpers.dart';
import 'commands_test.dart' show pick;

const _alter = 'changelog/2026/1-ddl/20260101-02-sales-orders-add-note.sql';

Future<void> closeHelp(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('help.close')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the ? button: topics with commands from the registry, search, every shortcut listed', (tester) async {
    await pumpApp(tester, fixture('shop'));
    await tester.tap(find.byKey(const Key('toolbar.help')));
    await tester.pumpAndSettle();
    for (final t in helpTopics) {
      expect(find.byKey(Key('help.topic.${t.id}')), findsOneWidget, reason: t.id);
    }
    expect(find.byKey(const Key('help.topic.shortcuts')), findsOneWidget);
    expect(find.byKey(const Key('help.topic.problems')), findsOneWidget);

    // A section lists its commands with descriptions and keys.
    await tester.tap(find.byKey(const Key('help.topic.refactoring')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('help.command.edit.rename')), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const Key('help.command.edit.rename')), matching: find.text('F2')),
      findsOneWidget,
    );

    // Search narrows the topics.
    await tester.enterText(find.byKey(const Key('help.search')), 'jsonb');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('help.topic.refactoring')), findsNothing);
    expect(find.byKey(const Key('help.topic.problems')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('help.search')), 'no such thing at all');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('help.empty')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('help.search')), '');
    await tester.pumpAndSettle();

    // The shortcut list is the registry: every command with keys has a row.
    await tester.tap(find.byKey(const Key('help.topic.shortcuts')));
    await tester.pumpAndSettle();
    final withKeys = appCommands.where((c) => c.keys.isNotEmpty).toList();
    expect(withKeys.length, greaterThan(25));
    for (final c in withKeys) {
      await tester.scrollUntilVisible(
        find.byKey(Key('help.shortcut.${c.id}')),
        100,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('help.page.shortcuts:')),
          matching: find.byType(Scrollable),
        ),
      );
      for (final k in c.keys) {
        expect(
          find.descendant(of: find.byKey(Key('help.shortcut.${c.id}')), matching: find.text(shortcutLabel(k))),
          findsOneWidget,
          reason: '${c.id} ${shortcutLabel(k)}',
        );
      }
    }
    await closeHelp(tester);
  });

  testWidgets('F1 on a line with a problem opens its description; so does What does this mean? in Problems', (
    tester,
  ) async {
    final app = await pumpApp(tester, fixture('shop'));
    final tab = await openFile(tester, app, _alter);
    final error = app.workspace.index!.problemsIn(_alter).firstWhere((x) => x.code == 'syntax');
    tab.reveal(error.span.start, error.span.start);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('help')), findsOneWidget);
    expect(find.byKey(const Key('help.problem.syntax')), findsOneWidget);
    expect(find.text('Before'), findsWidgets);
    await closeHelp(tester);

    // F1 elsewhere: the start page.
    tab.reveal(0, 0);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.pumpAndSettle();
    expect(find.textContaining('PG Studio reads a folder'), findsOneWidget);
    await closeHelp(tester);

    final i = app.workspace.index!.allProblems.indexWhere((x) => x.code == 'unresolved');
    await tester.tapAt(tester.getCenter(find.byKey(Key('problem.$i'))), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await pick(tester, 'help.problem');
    expect(find.byKey(const Key('help.problem.unresolved')), findsOneWidget);
    await closeHelp(tester);
  });
}
