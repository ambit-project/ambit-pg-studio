// Runs the real app on the Linux desktop with the real folders and saves screenshots to docs/screens/ (SDD evidence).
//   flutter test integration_test/screens_test.dart -d linux
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:pg_studio/app/project_controller.dart';
import 'package:pg_studio/app/settings_store.dart';
import 'package:pg_core/pg_core.dart';
import 'package:pg_studio/app/workspace.dart';
import 'package:pg_studio/main.dart';
import 'package:pg_studio/ui/editor_view.dart';
import 'package:pg_studio/ui/er_view.dart';
import 'package:pg_studio/ui/home_page.dart';
import 'package:re_editor/re_editor.dart';
import 'package:xterm/xterm.dart';

import '../test/complete/complete_ui_test.dart' show type;

final _repos = p.normalize(p.join(Directory.current.path, '..'));
final _wms = p.join(_repos, 'ambit.wms.app', 'db');
final _halycon = p.join(_repos, 'halycon.app.dev', 'db', 'changelog');
final _screens = p.join(Directory.current.path, 'docs', 'screens');
final _boundary = GlobalKey();

Future<void> shot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 100));
  final render = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await render.toImage(pixelRatio: 1);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  Directory(_screens).createSync(recursive: true);
  File(p.join(_screens, '$name.png')).writeAsBytesSync(png!.buffer.asUint8List());
  // ignore: avoid_print
  print('screenshot docs/screens/$name.png');
}

Future<void> waitFor(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw StateError('timeout');
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<(ProjectController, Workspace)> start(
  WidgetTester tester,
  String folder, {
  SettingsStore? settings,
  ThemeMode? theme = ThemeMode.dark,
}) async {
  final project = ProjectController(
    settings:
        settings ?? SettingsStore(p.join(Directory.systemTemp.createTempSync('pg_studio_it').path, 'settings.json')),
  );
  final workspace = Workspace(project);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: PgStudioApp(workspace: workspace, pickFolder: () async => folder, themeMode: theme),
    ),
  );
  await tester.pumpAndSettle();
  return (project, workspace);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('004: open halycon - frames keep coming while it is analysed', (tester) async {
    if (!Directory(_halycon).existsSync()) return markTestSkipped('missing $_halycon');
    final (project, _) = await start(tester, _halycon);
    await tester.tap(find.byKey(const Key('start.open')));
    var frames = 0;
    final watch = Stopwatch()..start();
    await tester.pump();
    while (project.indexing || project.index == null) {
      await tester.pump(const Duration(milliseconds: 16));
      frames++;
    }
    watch.stop();
    // ignore: avoid_print
    print(
      'halycon: indexed in ${project.timing}, ${watch.elapsedMilliseconds} ms on screen, $frames frames while indexing',
    );
    expect(frames, greaterThan(0));
    await tester.pumpAndSettle();
    await shot(tester, '004-halycon-files');
  });

  testWidgets('004: wms - object tree by module, an open procedure, problems', (tester) async {
    if (!Directory(_wms).existsSync()) return markTestSkipped('missing $_wms');
    final (project, ws) = await start(tester, _wms);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Modules'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('60-orders'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('orders_app (contract)'));
    await tester.pumpAndSettle();
    await ws.open('changelog/modules/60-orders/procedures/orders_app.asn_save.sql', select: 0);
    await tester.pumpAndSettle();
    await shot(tester, '004-wms-modules-editor');
  });

  testWidgets('005: wms - Ctrl+click, Find references, hover, Ctrl+T', (tester) async {
    if (!Directory(_wms).existsSync()) return markTestSkipped('missing $_wms');
    final (project, ws) = await start(tester, _wms);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await tester.pumpAndSettle();
    const asn = 'changelog/modules/60-orders/procedures/orders_app.asn_save.sql';
    final tab = (await ws.open(asn))!;
    await tester.pumpAndSettle();
    final view = find.byWidgetPredicate((w) => w is EditorView && w.tab == tab);
    // Ctrl+click on platform.require_role -> its definition, on the line of its name.
    final call = tab.text.indexOf('platform.require_role(');
    tab.reveal(call, call);
    await tester.pumpAndSettle();
    final local = tester.state<EditorViewState>(view).pointOf(call + 10)!;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(tester.getTopLeft(view) + local);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final target = project.index!.objects.values.singleWhere((o) => o.key.qualified == 'platform.require_role');
    final defLine = project.index!.files[target.primary.nameSpan.file]!.lineColumn(target.primary.nameSpan.start).$1;
    expect(ws.current!.path, target.primary.nameSpan.file);
    expect(ws.current!.lineColumn(ws.current!.cursorOffset).$1, defLine);
    // ignore: avoid_print
    print('ctrl+click platform.require_role -> ${ws.current!.path}:${defLine + 1}');
    await shot(tester, '005-ctrl-click-definition');

    // Back (Alt+Left) and Find references (Shift+F12) of orders.purchase_orders.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(ws.current!.path, asn);
    final po = tab.text.indexOf('orders.purchase_orders');
    tab.reveal(po + 3, po + 3);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    final groups = {for (final g in ws.references!.places) g.$1: g.$2.length};
    final files = {
      for (final g in ws.references!.places)
        for (final x in g.$2) x.$1.path.split('/').take(3).join('/'),
    };
    // ignore: avoid_print
    print('${ws.references!.title}: $groups in ${files.length} folders');
    expect(groups['Reads'], greaterThan(0));
    expect(groups['Writes'], greaterThan(0));
    await shot(tester, '005-find-references');

    // Hover on platform.require_actor_id.
    final actor = tab.text.indexOf('platform.require_actor_id');
    tab.reveal(actor, actor);
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getTopLeft(view) + tester.state<EditorViewState>(view).pointOf(actor + 12)!);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('editor.hover')), findsOneWidget);
    await shot(tester, '005-hover');
    await mouse.removePointer();

    // Ctrl+T.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('quickpick.query')), 'asn');
    await tester.pumpAndSettle();
    await shot(tester, '005-go-to-object');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('006: edit with a live error, the real disk watcher, a conflict', (tester) async {
    final copy = Directory.systemTemp.createTempSync('pg_studio_006_');
    Process.runSync('cp', [
      '-r',
      '${p.join(Directory.current.path, 'packages', 'pg_core', 'test', 'fixtures', 'shop')}/.',
      copy.path,
    ]);
    addTearDown(() => copy.deleteSync(recursive: true));
    final (project, ws) = await start(tester, copy.path);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await tester.pumpAndSettle();
    const total = 'changelog/modules/10-sales/functions/sales_app.order_total.sql';
    final tab = (await ws.open(total, select: 0))!;
    await tester.pumpAndSettle();

    // A typing mistake: underlined before saving.
    final at = tab.text.indexOf('FROM sales.orders');
    final (line, column) = tab.lineColumn(at);
    tab.controller.selection = CodeLineSelection.collapsed(index: line, offset: column);
    tab.controller.replaceSelection('FROM FROM ');
    await tester.pump(Workspace.liveDelay + const Duration(milliseconds: 100));
    await waitFor(tester, () => project.index!.problemsIn(total).isNotEmpty);
    await tester.pumpAndSettle();
    await shot(tester, '006-live-syntax-error');

    // Undo the mistake, then an agent changes the file on disk: the real watcher sees it.
    tab.controller.undo();
    await tester.pumpAndSettle();
    expect(tab.dirty, isFalse);
    final file = File(p.join(copy.path, total));
    file.writeAsStringSync('${file.readAsStringSync()}\n-- added by an agent\n');
    await waitFor(tester, () => tab.text.contains('-- added by an agent'), timeout: const Duration(seconds: 10));
    await waitFor(tester, () => project.index!.files[total]!.contentHash == tab.text.hashCode);
    // ignore: avoid_print
    print('watcher: clean tab reloaded and re-indexed after an outside write');

    // Unsaved edits + an outside write: the question.
    tab.controller.selection = const CodeLineSelection.collapsed(index: 0, offset: 0);
    tab.controller.replaceSelection('-- my edit\n');
    await tester.pump();
    file.writeAsStringSync('${file.readAsStringSync()}-- again\n');
    await waitFor(
      tester,
      () => find.text('File changed on disk').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 10),
    );
    await tester.pumpAndSettle();
    await shot(tester, '006-disk-conflict');
    await tester.tap(find.byKey(const Key('conflict.reload')));
    await tester.pumpAndSettle();
    expect(tab.text, endsWith('-- again\n'));
    expect(tab.dirty, isFalse);
  });

  testWidgets('007: wms - object graph and module graph', (tester) async {
    if (!Directory(_wms).existsSync()) return markTestSkipped('missing $_wms');
    final (project, ws) = await start(tester, _wms);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await tester.pumpAndSettle();
    tester.state<HomePageState>(find.byType(HomePage)).setPanelHeight(520);
    final asn = project.index!.objects.values.singleWhere((o) => o.key.qualified == 'orders_app.asn_save');
    await ws.goToSpan(asn.primary.nameSpan);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('graph.center')), findsOneWidget);
    await shot(tester, '007-object-graph');
    ws.showModuleGraph();
    await tester.pumpAndSettle();
    final g = moduleGraph(project.index!);
    // ignore: avoid_print
    print(
      'module graph: ${g.modules.length} modules, ${g.edges.length} dependencies, '
      '${g.edges.fold<int>(0, (n, e) => n + e.violations)} against the rules',
    );
    await shot(tester, '007-module-graph');
  });

  testWidgets('2.0/001: formatting a messy procedure, before and after', (tester) async {
    final copy = Directory.systemTemp.createTempSync('pg_studio_fmt_');
    addTearDown(() => copy.deleteSync(recursive: true));
    const path = 'changelog/modules/10-sales/procedures/sales_app.order_close.sql';
    Directory(p.join(copy.path, p.dirname(path))).createSync(recursive: true);
    File(p.join(copy.path, path)).writeAsStringSync(r'''--liquibase formatted sql

--changeset shop:procedure-sales-app-order-close runOnChange:true splitStatements:false
--comment: Zamknięcie zamówienia (przykład nieuporządkowanego pliku przed formatowaniem).
CREATE OR REPLACE PROCEDURE sales_app.order_close(p_id uuid,   INOUT p_row_version bigint) LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
v_status text;
BEGIN
-- U1101 (404): brak zamówienia.
SELECT o.status INTO v_status FROM sales.orders AS o WHERE o.id = p_id FOR UPDATE;
IF NOT FOUND THEN
RAISE EXCEPTION 'The order does not exist.' USING ERRCODE = 'U1101';
ELSIF v_status = 'closed' THEN
RETURN;
END IF;
UPDATE sales.orders SET status = 'closed'
WHERE id = p_id;
END
$$;
''');
    final (project, ws) = await start(tester, copy.path);
    ws.inMainBranch = (_, _) => false;
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await ws.open(path, select: 0);
    await tester.pumpAndSettle();
    await shot(tester, '2.0-001-format-before');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('format.result')), findsOneWidget);
    await shot(tester, '2.0-001-format-after');
  });

  testWidgets('2.0/002: completion of columns by alias and the signature of a call (wms)', (tester) async {
    if (!Directory(_wms).existsSync()) return markTestSkipped('missing $_wms');
    final (project, ws) = await start(tester, _wms);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await tester.pumpAndSettle();
    const asn = 'changelog/modules/60-orders/procedures/orders_app.asn_save.sql';
    final tab = (await ws.open(asn))!;
    await tester.pumpAndSettle();
    final view = find.byWidgetPredicate((w) => w is EditorView && w.tab == tab);
    // Typing as the IME does (the test text input intercepts the channel, like in widget tests).
    tester.testTextInput.register();
    addTearDown(tester.testTextInput.unregister);
    await tester.tap(view);
    await tester.pump();
    const anchor = 'WHERE o.id = p_purchase_order_id';
    final at = tab.text.indexOf(anchor) + anchor.length;
    tab.reveal(at, at);
    await tester.pumpAndSettle();
    await type(tester, ' AND o.wa');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('editor.completion')), findsOneWidget);
    await shot(tester, '2.0-002-completion');
    tab.controller.undo();
    await tester.pumpAndSettle();
    final end = tab.text.indexOf("PERFORM platform.require_role(ARRAY['admin', 'manager']);");
    tab.reveal(end, end);
    await tester.pumpAndSettle();
    await type(tester, 'CALL orders_app.asn_save(p_id, p_purchase_order_id, ');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('editor.signature')), findsOneWidget);
    await shot(tester, '2.0-002-signature');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
  });

  testWidgets('2.0/005: column uses and the impact of changing a column (wms)', (tester) async {
    if (!Directory(_wms).existsSync()) return markTestSkipped('missing $_wms');
    final (project, ws) = await start(tester, _wms);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await tester.pumpAndSettle();
    tester.state<HomePageState>(find.byType(HomePage)).setPanelHeight(420);
    const asn = 'changelog/modules/60-orders/procedures/orders_app.asn_save.sql';
    final tab = (await ws.open(asn))!;
    await tester.pumpAndSettle();
    final at = tab.text.indexOf('o.status') + 3;
    tab.reveal(at, at);
    await tester.pumpAndSettle();
    ws.findReferencesAt(asn, at);
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('${ws.references!.title}: ${[for (final g in ws.references!.places) '${g.$1} ${g.$2.length}']}');
    await shot(tester, '2.0-005-column-references');
    ws.impactAt(asn, at);
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print(ws.references!.title);
    await shot(tester, '2.0-005-impact');
  });

  testWidgets('2.0/003: rename preview of a column (wms, nothing written)', (tester) async {
    if (!Directory(_wms).existsSync()) return markTestSkipped('missing $_wms');
    final (project, ws) = await start(tester, _wms);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await tester.pumpAndSettle();
    const asn = 'changelog/modules/60-orders/procedures/orders_app.asn_save.sql';
    final tab = (await ws.open(asn))!;
    await tester.pumpAndSettle();
    final at = tab.text.indexOf('a.number') + 4;
    tab.reveal(at, at);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rename.name')), 'asn_number');
    await tester.tap(find.byKey(const Key('rename.next')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rename.preview')), findsOneWidget);
    await shot(tester, '2.0-003-rename-preview');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('2.0/004: the New dialog with a procedure template (wms, nothing created)', (tester) async {
    if (!Directory(_wms).existsSync()) return markTestSkipped('missing $_wms');
    final (project, ws) = await start(tester, _wms);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('new.name')), 'order_close');
    await tester.pumpAndSettle();
    await shot(tester, '2.0-004-new-procedure');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('2.0/007: search with a regex in the whole project (wms)', (tester) async {
    if (!Directory(_wms).existsSync()) return markTestSkipped('missing $_wms');
    final (project, ws) = await start(tester, _wms);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await tester.pumpAndSettle();
    tester.state<HomePageState>(find.byType(HomePage)).setPanelHeight(560);
    ws.searchRegex = true;
    ws.openSearch(query: r"ERRCODE = 'U14\d\d'");
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('search: ${ws.searchHits.length} matches');
    await shot(tester, '2.0-007-search');
  });

  testWidgets('2.0/008: history and effective DDL of a table (wms)', (tester) async {
    if (!Directory(_wms).existsSync()) return markTestSkipped('missing $_wms');
    final (project, ws) = await start(tester, _wms);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await tester.pumpAndSettle();
    tester.state<HomePageState>(find.byType(HomePage)).setPanelHeight(560);
    final t = project.index!.objects.values.firstWhere((o) => o.key.qualified == 'orders.purchase_orders');
    await ws.goToSpan(t.primary.nameSpan);
    ws.showHistory(t);
    await tester.pumpAndSettle();
    await shot(tester, '2.0-008-history');
  });

  testWidgets('2.0/009: the ER diagram of a module (wms) and its PNG export', (tester) async {
    if (!Directory(_wms).existsSync()) return markTestSkipped('missing $_wms');
    final (project, ws) = await start(tester, _wms);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await tester.pumpAndSettle();
    tester.state<HomePageState>(find.byType(HomePage)).setPanelHeight(640);
    ws.showEr('module:orders');
    await tester.pumpAndSettle();
    await shot(tester, '2.0-009-er-orders');
    ws.pickSavePath = (_) async => p.join(_screens, '2.0-009-er-orders-export.png');
    await tester.tap(find.byKey(const Key('er.export')));
    await tester.pumpAndSettle();
    await waitFor(tester, () => File(p.join(_screens, '2.0-009-er-orders-export.png')).existsSync());
  });

  testWidgets('2.0/010: the Changes panel on a branch (a copy of wms in a temporary repository)', (tester) async {
    if (!Directory(_wms).existsSync()) return markTestSkipped('missing $_wms');
    final repo = Directory.systemTemp.createTempSync('pg_branch_it_');
    addTearDown(() => repo.deleteSync(recursive: true));
    Process.runSync('cp', ['-r', '$_wms/.', repo.path]);
    void git(List<String> a) =>
        Process.runSync('git', ['-C', repo.path, '-c', 'user.name=t', '-c', 'user.email=t@t.invalid', ...a]);
    git(['init', '-q', '-b', 'main']);
    git(['add', '.']);
    git(['commit', '-q', '-m', 'main']);
    git(['checkout', '-q', '-b', 'feature/asn-notes']);
    final asn = File(p.join(repo.path, 'changelog/modules/60-orders/procedures/orders_app.asn_save.sql'));
    asn.writeAsStringSync(
      asn.readAsStringSync().replaceFirst('p_expected_on date,', 'p_expected_on date,\n    p_note text,'),
    );
    File(p.join(repo.path, 'changelog/modules/60-orders/views/orders_app.asn_notes.sql')).writeAsStringSync(
      '--liquibase formatted sql\n\n--changeset stocktron:view-orders-app-asn-notes runOnChange:true splitStatements:false\n'
      '--comment: Notatki awizacji.\nSET LOCAL ROLE stocktron_owner;\n\nCREATE OR REPLACE VIEW orders_app.asn_notes AS\n'
      'SELECT a.id, a.note FROM orders.asns AS a;\nRESET ROLE;\n',
    );
    final ddl = File(p.join(repo.path, 'changelog/2026/1-ddl/20261113-10-orders-create-schemas-and-tables.sql'));
    ddl.writeAsStringSync(ddl.readAsStringSync().replaceFirst('note          varchar(1000)', 'note          text'));
    final (project, ws) = await start(tester, repo.path);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await tester.pumpAndSettle();
    tester.state<HomePageState>(find.byType(HomePage)).setPanelHeight(560);
    await ws.showChanges();
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print(
      'changes: ${ws.review!.files.length} files, ${ws.review!.objects.length} objects, '
      '${ws.review!.newProblems.length} new problems, ${ws.review!.warnings.length} warnings',
    );
    await shot(tester, '2.0-010-changes');
  });

  testWidgets('2.0/012: references of a table from dynamic SQL (halycon)', (tester) async {
    if (!Directory(_halycon).existsSync()) return markTestSkipped('missing $_halycon');
    final (project, ws) = await start(tester, _halycon);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await tester.pumpAndSettle();
    // The table with the fewest references among those used from dynamic SQL, so they are visible in the panel.
    final index = project.index!;
    final targets = {
      for (final r in index.references)
        if (r.reference.dynamic && r.kind == RefKind.read) ...r.targets,
    }.toList()..sort((a, b) => index.referencesTo(a).length.compareTo(index.referencesTo(b).length));
    final users = index.objects[targets.first]!;
    final dynamic = index.referencesTo(users.key).where((r) => r.reference.dynamic).first;
    await ws.goToSpan(dynamic.span);
    ws.findReferences(users);
    tester.state<HomePageState>(find.byType(HomePage)).setPanelHeight(420);
    await tester.pumpAndSettle();
    await shot(tester, '2.0-012-dynamic-references');
  });

  testWidgets('2.0/013: a restart restores wms with its tabs; light theme and a larger font', (tester) async {
    if (!Directory(_wms).existsSync()) return markTestSkipped('missing $_wms');
    final settings = SettingsStore(p.join(Directory.systemTemp.createTempSync('pg_studio_it').path, 'settings.json'));
    final (project, ws) = await start(tester, _wms, settings: settings, theme: null);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await ws.open('changelog/modules/60-orders/procedures/orders_app.asn_save.sql', select: 900);
    await ws.open('changelog/modules/60-orders/views/orders_app.asns.sql', select: 200);
    ws.activate(0);
    ws.settings.setThemeMode(ThemeMode.light);
    ws.settings.setFontSize(15.5);
    await tester.pumpAndSettle(); // the cursors move after the editors are laid out
    ws.saveSession();
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox()); // the window closes
    final (again, ws2) = await start(tester, _wms, settings: settings, theme: null);
    final watch = Stopwatch()..start();
    unawaited(startup(again, const []));
    await waitFor(tester, () => !again.indexing && again.index != null && ws2.tabs.length == 2);
    watch.stop();
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('wms restored in ${watch.elapsedMilliseconds} ms: ${ws2.tabs.map((t) => '${t.path}@${t.cursorOffset}')}');
    expect(ws2.active, 0);
    expect(ws2.tabs.map((t) => t.cursorOffset), [900, 200]);
    await tester.tap(find.byKey(const Key('toolbar.settings')));
    await tester.pumpAndSettle();
    await shot(tester, '2.0-013-settings-light');
  });

  testWidgets('3.0/001: the context menu of the editor on a table name (wms)', (tester) async {
    if (!Directory(_wms).existsSync()) return markTestSkipped('missing $_wms');
    final (project, ws) = await start(tester, _wms);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    final tab = (await ws.open('changelog/modules/60-orders/procedures/orders_app.asn_save.sql', select: 0))!;
    await tester.pumpAndSettle();
    final at = tab.text.indexOf('orders.purchase_orders AS o');
    tab.reveal(at, at);
    await tester.pumpAndSettle();
    final state = tester.state<EditorViewState>(find.byType(EditorView));
    final point = tester.getTopLeft(find.byType(EditorView)) + state.pointOf(at + 10)!;
    await tester.tapAt(point, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('menu.nav.impact')), findsOneWidget);
    await shot(tester, '3.0-001-context-menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('3.0/002: help - the Navigation topic and a problem (wms)', (tester) async {
    if (!Directory(_wms).existsSync()) return markTestSkipped('missing $_wms');
    final (project, _) = await start(tester, _wms);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('toolbar.help')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('help.topic.navigation')));
    await tester.pumpAndSettle();
    await shot(tester, '3.0-002-help');
    await tester.tap(find.byKey(const Key('help.topic.problems')));
    await tester.pumpAndSettle();
    await shot(tester, '3.0-002-help-problems');
    await tester.tap(find.byKey(const Key('help.close')));
    await tester.pumpAndSettle();
  });

  testWidgets('3.0/003: the terminal in the wms folder with pg-studio output (paths open files)', (tester) async {
    if (!Directory(_wms).existsSync()) return markTestSkipped('missing $_wms');
    final cli = p.join(Directory.current.path, 'packages', 'pg_core', 'build', 'cli', 'bundle', 'bin', 'pg_studio_cli');
    if (!File(cli).existsSync()) return markTestSkipped('build the CLI first: dart build cli');
    final (project, ws) = await start(tester, _wms);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await ws.open('changelog/modules/60-orders/procedures/orders_app.asn_save.sql', select: 0);
    tester.state<HomePageState>(find.byType(HomePage)).setPanelHeight(430);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await waitFor(tester, () => ws.terminals.sessions.isNotEmpty);
    final s = ws.terminals.current!;
    await tester.pump(const Duration(milliseconds: 600));
    s.terminal.textInput('clear; $cli refs . orders.purchase_orders --kind write');
    s.terminal.keyInput(TerminalKey.enter);
    await waitFor(tester, () => s.terminal.buffer.getText().contains('purchase_order_close.sql:'));
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, '3.0-003-terminal');
    ws.terminals.closeAll();
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('3.0/004: the command palette (wms)', (tester) async {
    if (!Directory(_wms).existsSync()) return markTestSkipped('missing $_wms');
    final (project, ws) = await start(tester, _wms);
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null);
    await ws.open('changelog/modules/60-orders/procedures/orders_app.asn_save.sql', select: 0);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('quickpick.query')), 'go');
    await tester.pumpAndSettle();
    await shot(tester, '3.0-004-palette');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('3.1: the ER diagram of a module in its own window (wms), zoomed and reset', (tester) async {
    if (!Directory(_wms).existsSync()) return markTestSkipped('missing $_wms');
    final project = ProjectController(
      settings: SettingsStore(p.join(Directory.systemTemp.createTempSync('pg_studio_it').path, 'settings.json')),
    );
    final ws = Workspace(project, keepSession: false);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _boundary,
        child: PgStudioApp(workspace: ws, erScope: 'module:orders', themeMode: ThemeMode.dark),
      ),
    );
    await startup(project, [_wms, '--er=module:orders'], workspace: ws);
    await waitFor(tester, () => !project.indexing && project.index != null);
    await tester.pumpAndSettle();
    final er = tester.state<ErViewState>(find.byType(ErView));
    er.transform.value = Matrix4.identity()..scaleByDouble(0.5, 0.5, 1, 1);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('er.resetView')));
    await tester.pumpAndSettle();
    expect(er.transform.value, Matrix4.identity());
    expect(ws.tabs, isEmpty);
    await shot(tester, '3.1-er-window');
  });
}
