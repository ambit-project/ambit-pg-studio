// The Terminal panel on the real window with a real shell (3.0 spec 003): ./verify terminal.
import 'dart:io';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:pg_studio/app/project_controller.dart';
import 'package:pg_studio/app/settings_store.dart';
import 'package:pg_studio/app/terminals.dart';
import 'package:pg_studio/app/workspace.dart';
import 'package:pg_studio/main.dart';
import 'package:pg_studio/ui/terminal_panel.dart';
import 'package:xterm/xterm.dart';

final _shop = p.join(Directory.current.path, 'packages', 'pg_core', 'test', 'fixtures', 'shop');

Future<void> waitFor(WidgetTester tester, bool Function() done, {int seconds = 15, String what = ''}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw StateError('timeout: $what');
    await tester.pump(const Duration(milliseconds: 30));
  }
}

String screen(TerminalSession s) => s.terminal.buffer.getText();

Future<void> run(WidgetTester tester, TerminalSession s, String command) async {
  s.terminal.textInput(command);
  s.terminal.keyInput(TerminalKey.enter);
  await tester.pump(const Duration(milliseconds: 100));
}

bool alive(int pid) =>
    Directory('/proc/$pid').existsSync() && !File('/proc/$pid/stat').readAsStringSync().contains(') Z');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('3.0/003: a shell in the project folder; paths open files; files written there are indexed; '
      'closing ends the processes; quitting asks', (tester) async {
    final dir = Directory.systemTemp.createTempSync('pg_terminal_');
    addTearDown(() => dir.deleteSync(recursive: true));
    Process.runSync('cp', ['-r', '$_shop/.', dir.path]);
    final root = dir.resolveSymbolicLinksSync();
    final project = ProjectController(
      settings: SettingsStore(p.join(Directory.systemTemp.createTempSync('pg_term_it').path, 'settings.json')),
    );
    final ws = Workspace(project);
    await tester.pumpWidget(PgStudioApp(workspace: ws, pickFolder: () async => root, themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start.open')));
    await waitFor(tester, () => !project.indexing && project.index != null, what: 'index');

    // Ctrl+` opens the panel with a shell in the project folder and the keyboard in it.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await waitFor(tester, () => ws.terminals.sessions.isNotEmpty, what: 'session');
    expect(ws.panel, BottomPanel.terminal);
    final s = ws.terminals.current!;
    expect(s.cwd, root);
    await run(tester, s, 'echo "dir=\$(pwd)"');
    await waitFor(tester, () => screen(s).contains('dir=$root'), what: 'pwd');
    await waitFor(tester, () => FocusManager.instance.primaryFocus?.debugLabel == 'terminal ${s.pid}', what: 'focus');

    // Typed on the real keyboard: the keys go to the shell.
    for (final k in [LogicalKeyboardKey.keyL, LogicalKeyboardKey.keyS, LogicalKeyboardKey.space]) {
      await tester.sendKeyEvent(k);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await waitFor(tester, () => screen(s).contains('changelog.yaml'), what: 'ls');

    // A file written in the terminal is indexed.
    await run(
      tester,
      s,
      r"printf -- '--liquibase formatted sql\n--changeset t:1\nCREATE TABLE sales.from_terminal (id int);\n' "
      '> changelog/2026/1-ddl/20260102-01-from-terminal.sql',
    );
    await waitFor(
      tester,
      () => project.index!.objects.values.any((o) => o.key.qualified == 'sales.from_terminal'),
      what: 'indexed',
    );

    // pg-studio-style output: Ctrl+click on the path opens the file at that line and column.
    const target = 'changelog/modules/10-sales/procedures/sales_app.order_save.sql';
    await run(tester, s, 'echo "$target:23:9: warning: example"');
    await waitFor(tester, () => screen(s).contains('$target:23:9: warning'), what: 'echo path');
    final lines = s.terminal.buffer.lines;
    var y = -1;
    for (var i = lines.length - 1; i >= 0; i--) {
      if (lines[i].getText().startsWith('$target:23:9')) {
        y = i;
        break;
      }
    }
    expect(y, isNot(-1));
    tester.state<TerminalPanelState>(find.byType(TerminalPanel)).openPathAt(s, CellOffset(10, y));
    await waitFor(tester, () => ws.current?.path == target, what: 'opened');
    await tester.pump(const Duration(milliseconds: 200));
    expect(ws.current!.lineColumn(ws.current!.cursorOffset), (22, 8));

    // A second terminal; a program in the foreground names the tab and makes quitting ask.
    ws.showPanel(BottomPanel.terminal);
    await tester.pump();
    await tester.tap(find.byKey(const Key('terminal.new')));
    await waitFor(tester, () => ws.terminals.sessions.length == 2, what: 'second');
    final second = ws.terminals.current!;
    await run(tester, second, 'sleep 300');
    await waitFor(tester, () => second.busy, what: 'busy');
    await tester.pump(const Duration(milliseconds: 1100));
    expect(find.text('sleep'), findsOneWidget);
    final sleepPid = int.parse(File('/proc/${second.pid}/stat').readAsStringSync().split(') ').last.split(' ')[5]);
    expect(alive(sleepPid), isTrue);

    final response = tester.binding.handleRequestAppExit();
    await tester.pumpAndSettle();
    expect(find.text('Programs are running'), findsOneWidget);
    await tester.tap(find.byKey(const Key('running.cancel')));
    await tester.pumpAndSettle();
    expect(await response, AppExitResponse.cancel);

    // Closing the tab ends the shell and the program started from it.
    final shellPid = second.pid;
    await tester.tap(find.byKey(const Key('terminal.close.1')));
    await waitFor(tester, () => !alive(sleepPid) && !alive(shellPid), what: 'killed');
    expect(ws.terminals.sessions, hasLength(1));
    // ignore: avoid_print
    print('terminal: shell $shellPid and sleep $sleepPid ended; first shell ${s.pid} in $root');

    // Terminal here: right click on a folder of the Files tree.
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('tree:dir:changelog/2026'))),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu.terminal.here')));
    await waitFor(tester, () => ws.terminals.sessions.length == 2, what: 'terminal here');
    expect(ws.terminals.current!.cwd, p.join(root, 'changelog', '2026'));

    ws.terminals.closeAll();
    await tester.pump(const Duration(milliseconds: 500));
  });
}
