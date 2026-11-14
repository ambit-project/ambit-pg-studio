import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pg_studio/app/project_controller.dart';
import 'package:pg_studio/app/settings_store.dart';
import 'package:pg_studio/app/workspace.dart';
import 'package:pg_studio/main.dart';

/// The pg_core fixture folders (copied to a temp folder when a test writes files).
String fixture(String name) => p.join(Directory.current.path, 'packages', 'pg_core', 'test', 'fixtures', name);

Directory copyFixture(String name) {
  final target = Directory.systemTemp.createTempSync('pg_studio_$name');
  Process.runSync('cp', ['-r', '${fixture(name)}/.', target.path]);
  return target;
}

class App {
  App(this.project, this.workspace);

  final ProjectController project;
  final Workspace workspace;
}

/// Pumps the app with [folder] opened through the Open folder button (the dialog is replaced).
Future<App> pumpApp(
  WidgetTester tester,
  String folder, {
  Size size = const Size(1600, 1000),
  SettingsStore? settings,
  bool settingsTheme = false,
}) async {
  final app = await pumpBare(tester, size: size, settings: settings, settingsTheme: settingsTheme, folder: folder);
  await tester.tap(find.byKey(const Key('start.open')));
  await settle(tester, app.project);
  return app;
}

/// A new settings file in a temp folder.
SettingsStore tempSettings() =>
    SettingsStore(p.join(Directory.systemTemp.createTempSync('pg_studio_settings').path, 'settings.json'));

/// Pumps the app without opening a folder; the theme is dark unless [settingsTheme] (then the settings decide).
Future<App> pumpBare(
  WidgetTester tester, {
  Size size = const Size(1600, 1000),
  SettingsStore? settings,
  bool settingsTheme = false,
  String? folder,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final project = ProjectController(settings: settings ?? tempSettings());
  final workspace = Workspace(project, watchDisk: false);
  await tester.pumpWidget(
    PgStudioApp(workspace: workspace, pickFolder: () async => folder, themeMode: settingsTheme ? null : ThemeMode.dark),
  );
  return App(project, workspace);
}

/// Lets isolates and file IO finish, then pumps frames.
Future<void> settle(WidgetTester tester, ProjectController project) async {
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    if (!project.indexing && project.index != null) break;
  }
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pump();
}

/// Opens [path] in a tab and waits for it.
Future<EditorTab> openFile(WidgetTester tester, App app, String path, {int? select}) async {
  final tab = await tester.runAsync(() => app.workspace.open(path, select: select));
  await tester.pump();
  await tester.pump();
  return tab!;
}

/// Offset of the first [text] in [tab] (+ [delta]).
int at(EditorTab tab, String text, [int delta = 0]) {
  final i = tab.text.indexOf(text);
  if (i < 0) throw StateError('"$text" not in ${tab.path}');
  return i + delta;
}
