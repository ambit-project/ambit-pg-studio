import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pg_core/pg_core.dart';

import 'app/project_controller.dart';
import 'app/workspace.dart';
import 'ui/er_view.dart';
import 'ui/home_page.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  final project = ProjectController(cache: Phase1Cache.at());
  final er = erScopeOf(args);
  final workspace = Workspace(project, keepSession: er == null);
  runApp(PgStudioApp(workspace: workspace, erScope: er));
  unawaited(startup(project, args, workspace: workspace));
}

/// `pg_studio <folder>` opens the folder right away; without it the last folder opens again with its tabs
/// (2.0 spec 013).
/// `--terminal` also opens the Terminal panel (3.0 spec 003); `--er=<scope>` is a window with only that ER diagram
/// (3.1), it opens the folder without restoring its tabs.
Future<void> startup(ProjectController project, List<String> args, {Workspace? workspace}) async {
  await project.loadRecent();
  final folders = args.where((a) => !a.startsWith('--')).toList();
  if (folders.isNotEmpty) {
    await project.open(folders.first);
  } else if (project.recent.isNotEmpty && Directory(project.recent.first).existsSync()) {
    await project.open(project.recent.first);
  }
  if (workspace != null && args.contains('--terminal') && project.root != null) {
    workspace.terminals.open(project.root!, fontSize: workspace.settings.fontSize);
    workspace.showPanel(BottomPanel.terminal);
  }
}

/// The scope of `--er=<scope>`: the window shows only that ER diagram (3.1).
String? erScopeOf(List<String> args) =>
    args.where((a) => a.startsWith(erArg)).map((a) => a.substring(erArg.length)).where((s) => s.isNotEmpty).firstOrNull;

class PgStudioApp extends StatelessWidget {
  const PgStudioApp({super.key, required this.workspace, this.pickFolder, this.themeMode, this.erScope});

  final Workspace workspace;
  final Future<String?> Function()? pickFolder;

  /// A window with only this ER diagram instead of the editor (3.1).
  final String? erScope;

  /// Overrides the theme of the settings (tests and screenshots).
  final ThemeMode? themeMode;

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: workspace.settings, builder: _app);

  Widget _app(BuildContext context, Widget? _) {
    return MaterialApp(
      title: 'PG Studio',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode ?? workspace.settings.themeMode,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF336791),
        useMaterial3: true,
        visualDensity: VisualDensity.compact,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF336791),
        brightness: Brightness.dark,
        useMaterial3: true,
        visualDensity: VisualDensity.compact,
      ),
      home: erScope != null
          ? ErWindow(workspace: workspace, scope: erScope!)
          : HomePage(workspace: workspace, pickFolder: pickFolder),
    );
  }
}
