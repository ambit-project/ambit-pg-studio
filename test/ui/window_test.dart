import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pg_studio/ui/editor_view.dart';

import '../helpers.dart';

const _save = 'changelog/modules/10-sales/procedures/sales_app.order_save.sql';
const _alter = 'changelog/2026/1-ddl/20260101-02-sales-orders-add-note.sql';

void main() {
  testWidgets('Open folder indexes it in the background and shows the file tree', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    expect(app.project.index, isNotNull);
    expect(find.text('changelog'), findsOneWidget);
    expect(find.textContaining('7 files'), findsOneWidget); // the status bar: the fixture's .sql files
    // Folders open on tap, files open in a tab.
    await tester.tap(find.text('modules'));
    await tester.pump();
    await tester.tap(find.text('10-sales'));
    await tester.pump();
    await tester.tap(find.text('procedures'));
    await tester.pump();
    await tester.tap(find.text('sales_app.order_save.sql'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(app.workspace.current!.path, _save);
    expect(find.byKey(const Key('tab.$_save')), findsOneWidget);
    expect(find.byType(EditorView, skipOffstage: false), findsOneWidget);
  });

  testWidgets('the UI keeps rendering while a folder is analysed (isolate)', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    // Re-open: the progress shows and frames keep coming while the isolate works.
    final opening = app.project.open(fixture('shop'));
    await tester.pump();
    expect(app.project.indexing, isTrue);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    await tester.pump(const Duration(milliseconds: 16));
    await settle(tester, app.project);
    expect(app.project.indexing, isFalse);
    await opening;
  });

  testWidgets('objects by schema and by module, a click opens the definition', (tester) async {
    final app = await pumpApp(tester, fixture('modules'));
    await tester.tap(find.text('Objects'));
    await tester.pump();
    expect(find.text('orders_app'), findsOneWidget);
    await tester.tap(find.text('Modules'));
    await tester.pump();
    expect(find.text('20-orders'), findsOneWidget);
    await tester.tap(find.text('20-orders'));
    await tester.pump();
    await tester.tap(find.text('orders_app (contract)'));
    await tester.pump();
    await tester.tap(find.text('procedures (2)'));
    await tester.pump();
    await tester.tap(find.text('order_save(uuid,uuid)'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump();
    final tab = app.workspace.current!;
    expect(tab.path, 'changelog/modules/20-orders/procedures/orders_app.order_save.sql');
    expect(
      tab.text.substring(tab.cursorOffset - 'orders_app.order_save'.length, tab.cursorOffset),
      'orders_app.order_save',
    );
  });

  testWidgets('tabs: several files, switching and closing', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    await openFile(tester, app, _save);
    await openFile(tester, app, _alter);
    expect(app.workspace.tabs.map((t) => t.path), [_save, _alter]);
    expect(app.workspace.current!.path, _alter);
    await tester.tap(find.byKey(const Key('tab.$_save')));
    await tester.pump();
    expect(app.workspace.current!.path, _save);
    await tester.tap(find.byKey(const Key('tab.close.$_save')));
    await tester.pump();
    expect(app.workspace.tabs.map((t) => t.path), [_alter]);
  });

  testWidgets('highlighting: keywords, comments, objects by kind from the index, problems underlined', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    final tab = await openFile(tester, app, _alter);
    final style = const TextStyle(fontSize: 13);
    TextStyle? styleAt(int offset) {
      final (line, column) = tab.lineColumn(offset);
      final lineText = tab.text.split('\n')[line];
      final span = tab.lineSpans!(tab, line, lineText, style);
      var pos = 0;
      for (final child in span.children!.cast<TextSpan>()) {
        if (column < pos + child.text!.length) return child.style;
        pos += child.text!.length;
      }
      return null;
    }

    final create = styleAt(at(tab, 'CREATE FUNCTION'))!;
    final comment = styleAt(at(tab, '--comment: Notatka'))!;
    final table = styleAt(at(tab, 'sales.orders ADD'))!;
    final broken = app.project.index!.problemsIn(_alter).single;
    final error = styleAt(broken.span.start)!;
    expect(create.color, isNot(comment.color));
    expect(comment.fontStyle, FontStyle.italic);
    expect(table.fontWeight, FontWeight.w700); // ALTER TABLE: a place of the table
    expect(error.decorationStyle, TextDecorationStyle.wavy);
  });

  testWidgets('Problems lists errors and warnings with file:line; a click opens the place', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    expect(find.textContaining('Problems (2)'), findsOneWidget);
    expect(find.textContaining('$_alter:9:'), findsOneWidget);
    expect(find.textContaining('routine sales_app.missing_proc is not defined'), findsOneWidget);
    await tester.tap(find.byKey(const Key('problem.1')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump();
    final tab = app.workspace.current!;
    expect(tab.path, _save);
    final problem = app.project.index!.allProblems[1];
    expect(problem.code, 'unresolved');
    expect(tab.cursorOffset, problem.span.end);
  });
}
