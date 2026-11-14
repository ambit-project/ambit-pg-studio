import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:pg_studio/app/workspace.dart';
import 'package:re_editor/re_editor.dart';

import '../helpers.dart';

const _view = 'changelog/modules/10-sales/views/sales_app.order_list.sql';
const _total = 'changelog/modules/10-sales/functions/sales_app.order_total.sql';

/// Types [text] at [offset] the way the editor does (one revocable edit).
Future<void> typeAt(WidgetTester tester, EditorTab tab, int offset, String text) async {
  final (line, column) = tab.lineColumn(offset);
  tab.controller.selection = CodeLineSelection.collapsed(index: line, offset: column);
  tab.controller.replaceSelection(text);
  await tester.pump();
}

/// Waits past the live re-analysis delay and lets the update finish.
Future<void> afterLive(WidgetTester tester) async {
  await tester.pump(Workspace.liveDelay + const Duration(milliseconds: 50));
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
  }
}

Future<void> settleIo(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
  }
}

void main() {
  testWidgets('typing marks the tab, Ctrl+S writes the file and the index follows', (tester) async {
    final dir = copyFixture('shop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = await pumpApp(tester, dir.path);
    final ws = app.workspace;
    final tab = await openFile(tester, app, _view, select: 0);
    final customers = app.project.index!.objects.values.singleWhere((o) => o.key.qualified == 'sales.customers');
    expect(app.project.index!.referencesTo(customers.key).where((r) => r.span.file == _view), hasLength(1));

    await typeAt(
      tester,
      tab,
      tab.text.indexOf(';\n', tab.text.indexOf('JOIN')),
      '\nLEFT JOIN sales.customers AS c2 ON c2.id = o.customer_id',
    );
    expect(tab.dirty, isTrue);
    expect(find.byKey(const Key('tab.dirty.$_view')), findsOneWidget);
    await afterLive(tester);
    // The index already follows the unsaved text.
    expect(app.project.index!.referencesTo(customers.key).where((r) => r.span.file == _view), hasLength(2));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settleIo(tester);
    expect(tab.dirty, isFalse);
    expect(find.byKey(const Key('tab.dirty.$_view')), findsNothing);
    expect(File(p.join(dir.path, _view)).readAsStringSync(), contains('LEFT JOIN sales.customers AS c2'));
    expect(app.project.index!.files[_view]!.contentHash, tab.text.hashCode);
    expect(ws.unsavedTexts, isEmpty);
  });

  testWidgets('closing a tab with unsaved changes asks: Cancel keeps it, Don\'t save drops the edits', (tester) async {
    final dir = copyFixture('shop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = await pumpApp(tester, dir.path);
    final tab = await openFile(tester, app, _view, select: 0);
    await typeAt(tester, tab, 0, '-- edit\n');
    await tester.tap(find.byKey(const Key('tab.close.$_view')));
    await tester.pump();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.byKey(const Key('unsaved.cancel')));
    await tester.pump();
    expect(app.workspace.tabs, hasLength(1));
    await tester.tap(find.byKey(const Key('tab.close.$_view')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('unsaved.discard')));
    await settleIo(tester);
    expect(app.workspace.tabs, isEmpty);
    expect(File(p.join(dir.path, _view)).readAsStringSync(), isNot(startsWith('-- edit')));
  });

  testWidgets('closing the window with unsaved changes asks; Cancel keeps the app open', (tester) async {
    final dir = copyFixture('shop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = await pumpApp(tester, dir.path);
    final tab = await openFile(tester, app, _view, select: 0);
    await typeAt(tester, tab, 0, '-- edit\n');
    final response = tester.binding.handleRequestAppExit();
    await tester.pump();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.byKey(const Key('unsaved.cancel')));
    await tester.pump();
    expect(await response, AppExitResponse.cancel);
    await afterLive(tester);
  });

  testWidgets('a syntax error is underlined while typing (before saving)', (tester) async {
    final dir = copyFixture('shop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = await pumpApp(tester, dir.path);
    final tab = await openFile(tester, app, _total, select: 0);
    final at = tab.text.indexOf('FROM sales.orders');
    await typeAt(tester, tab, at, 'FROM FROM ');
    await afterLive(tester);
    final problems = app.project.index!.problemsIn(_total);
    expect(problems.single.severity, Severity.error);
    expect(problems.single.span.start, inInclusiveRange(at, at + 10));
    final (line, column) = tab.lineColumn(problems.single.span.start);
    final lineText = tab.text.split('\n')[line];
    final spans = tab.lineSpans!(tab, line, lineText, const TextStyle()).children!.cast<TextSpan>();
    var pos = 0;
    TextStyle? style;
    for (final s in spans) {
      if (column < pos + s.text!.length) {
        style = s.style;
        break;
      }
      pos += s.text!.length;
    }
    expect(style!.decorationStyle, TextDecorationStyle.wavy);
  });

  testWidgets('a file changed on disk: a clean tab reloads, a tab with edits asks (keep or reload)', (tester) async {
    final dir = copyFixture('shop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = await pumpApp(tester, dir.path);
    final ws = app.workspace;
    final clean = await openFile(tester, app, _view, select: 0);
    final file = File(p.join(dir.path, _view));
    file.writeAsStringSync('${file.readAsStringSync()}\n-- changed by an agent\n');
    await tester.runAsync(() => ws.diskChanged([_view]));
    await settleIo(tester);
    expect(clean.text, endsWith('-- changed by an agent\n'));
    expect(clean.dirty, isFalse);
    expect(app.project.index!.files[_view]!.contentHash, clean.text.hashCode);

    // Unsaved edits + a disk change: a question, never a silent overwrite.
    await typeAt(tester, clean, 0, '-- mine\n');
    file.writeAsStringSync('${file.readAsStringSync()}-- changed again\n');
    await tester.runAsync(() => ws.diskChanged([_view]));
    await tester.pump();
    expect(find.text('File changed on disk'), findsOneWidget);
    expect(clean.text, startsWith('-- mine'));
    await tester.tap(find.byKey(const Key('conflict.keep')));
    await settleIo(tester);
    expect(clean.text, startsWith('-- mine'));
    expect(clean.dirty, isTrue);

    file.writeAsStringSync('${file.readAsStringSync()}-- third\n');
    await tester.runAsync(() => ws.diskChanged([_view]));
    await tester.pump();
    await tester.tap(find.byKey(const Key('conflict.reload')));
    await settleIo(tester);
    expect(clean.text, endsWith('-- third\n'));
    expect(clean.dirty, isFalse);
  });

  testWidgets('a new file on disk is indexed; a deleted clean file closes its tab', (tester) async {
    final dir = copyFixture('shop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = await pumpApp(tester, dir.path);
    final ws = app.workspace;
    const added = 'changelog/modules/10-sales/views/sales_app.customer_list.sql';
    File(p.join(dir.path, added))
        .writeAsStringSync('CREATE VIEW sales_app.customer_list AS SELECT c.id FROM sales.customers AS c;\n');
    await tester.runAsync(() => ws.diskChanged([added]));
    await settleIo(tester);
    expect(app.project.index!.objects.values.where((o) => o.key.qualified == 'sales_app.customer_list'), hasLength(1));

    await openFile(tester, app, added, select: 0);
    File(p.join(dir.path, added)).deleteSync();
    await tester.runAsync(() => ws.diskChanged([added]));
    await settleIo(tester);
    expect(ws.tabs.where((t) => t.path == added), isEmpty);
    expect(app.project.index!.objects.values.where((o) => o.key.qualified == 'sales_app.customer_list'), isEmpty);
  });
}
