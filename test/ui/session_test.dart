import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pg_studio/app/app_settings.dart';
import 'package:pg_studio/main.dart';
import 'package:re_editor/re_editor.dart';

import '../helpers.dart';

const _save = 'changelog/modules/10-sales/procedures/sales_app.order_save.sql';
const _view = 'changelog/modules/10-sales/views/sales_app.order_list.sql';

void main() {
  testWidgets('a restart opens the last folder with its tabs, cursors and the active tab', (tester) async {
    final settings = tempSettings();
    final shop = fixture('shop');
    final first = await pumpApp(tester, shop, settings: settings);
    final save = await openFile(tester, first, _save, select: 120);
    await openFile(tester, first, _view, select: 40);
    first.workspace.activate(0);
    await tester.pump();
    expect(save.cursorOffset, 120);
    // Closing the window writes the session (AppLifecycleListener.onExitRequested).
    first.workspace.saveSession();
    await tester.pumpWidget(const SizedBox());

    // A new start: no folder argument.
    final second = await pumpBare(tester, settings: settings);
    await tester.runAsync(() => startup(second.project, const []));
    await settle(tester, second.project);
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    final ws = second.workspace;
    expect(second.project.root, shop);
    expect(ws.tabs.map((t) => t.path), [_save, _view]);
    expect(ws.active, 0);
    expect(ws.tabs[0].cursorOffset, 120);
    expect(ws.tabs[1].cursorOffset, 40);
    expect(find.byKey(const ValueKey('editor:$_save')), findsOneWidget);
    // The status bar follows the cursor (it moved after the tab opened).
    final (line, column) = ws.tabs[0].lineColumn(120);
    expect(tester.widget<Text>(find.byKey(const Key('status.cursor'))).data, 'Ln ${line + 1}, Col ${column + 1}');
  });

  testWidgets('theme and font size in the settings dialog and with Ctrl+= / Ctrl+- / Ctrl+0; they are saved', (
    tester,
  ) async {
    final settings = tempSettings();
    final app = await pumpApp(tester, fixture('shop'), settings: settings, settingsTheme: true);
    await openFile(tester, app, _save);
    BuildContext ctx() => tester.element(find.byKey(const ValueKey('editor:$_save')));

    await tester.tap(find.byKey(const Key('toolbar.settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings.theme.dark')));
    await tester.pumpAndSettle();
    expect(Theme.of(ctx()).brightness, Brightness.dark);
    await tester.tap(find.byKey(const Key('settings.theme.light')));
    await tester.pumpAndSettle();
    expect(Theme.of(ctx()).brightness, Brightness.light);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    double editorFont() => tester.widget<CodeEditor>(find.byKey(const ValueKey('editor:$_save'))).style!.fontSize!;
    expect(editorFont(), AppSettings.defaultFont);
    for (var i = 0; i < 2; i++) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }
    expect(editorFont(), AppSettings.defaultFont + 2);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(editorFont(), AppSettings.defaultFont + 1);

    final again = AppSettings(settings);
    expect(again.themeMode, ThemeMode.light);
    expect(again.fontSize, AppSettings.defaultFont + 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(editorFont(), AppSettings.defaultFont);
  });
}
