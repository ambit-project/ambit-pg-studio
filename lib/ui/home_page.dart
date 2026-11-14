import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart' hide ObjectKey;
import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';

import '../app/commands.dart';
import '../app/workspace.dart';
import 'command_menu.dart';
import 'dialogs.dart';
import 'editor_view.dart';
import 'help_dialog.dart';
import 'panels.dart';
import 'new_file_dialog.dart';
import 'rename_dialog.dart';
import 'settings_dialog.dart';
import 'sidebar.dart';
import 'theme.dart';

/// The project window: toolbar, sidebar, editor tabs, bottom panel, status bar.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.workspace, this.pickFolder});

  final Workspace workspace;

  /// Replaces the folder dialog (tests).
  final Future<String?> Function()? pickFolder;

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  double sidebarWidth = 320;
  double panelHeight = 230;
  final Map<EditorTab, GlobalKey<EditorViewState>> _editorKeys = {};
  late final AppLifecycleListener _lifecycle;

  Workspace get ws => widget.workspace;

  /// Height of the bottom panel (the splitter drags it).
  void setPanelHeight(double height) => setState(() => panelHeight = height.clamp(80, 900));

  @override
  void initState() {
    super.initState();
    ws.addListener(_changed);
    ws.project.addListener(_changed);
    ws.settings.addListener(_changed);
    _lifecycle = AppLifecycleListener(onExitRequested: _exitRequested, onInactive: ws.saveSession);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    ws.removeListener(_changed);
    ws.project.removeListener(_changed);
    ws.settings.removeListener(_changed);
    super.dispose();
  }

  bool _askingConflict = false;

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final conflict = ws.tabs.where((t) => t.diskConflict).firstOrNull;
    if (conflict != null && !_askingConflict) unawaited(_askConflict(conflict));
  }

  Future<void> _askConflict(EditorTab tab) async {
    _askingConflict = true;
    try {
      ws.activate(ws.tabs.indexOf(tab));
      final choice = await askDiskConflict(context, tab.path);
      if (!ws.tabs.contains(tab)) return;
      await ws.resolveConflict(tab, reload: choice == ConflictChoice.reload);
    } finally {
      _askingConflict = false;
    }
  }

  /// Closing the window with unsaved tabs asks first (spec 006).
  Future<AppExitResponse> _exitRequested() async {
    ws.saveSession();
    // A program running in a terminal (3.0 spec 003) asks first; the shells end with the app.
    final busy = ws.terminals.busy;
    if (busy.isNotEmpty && mounted && !await askRunningTerminals(context, [for (final s in busy) s.title])) {
      return AppExitResponse.cancel;
    }
    final response = await _exitUnsaved();
    if (response == AppExitResponse.exit) ws.terminals.closeAll();
    return response;
  }

  Future<AppExitResponse> _exitUnsaved() async {
    final dirty = ws.tabs.where((t) => t.dirty).toList();
    if (dirty.isEmpty || !mounted) return AppExitResponse.exit;
    final choice = await askUnsaved(context, [for (final t in dirty) t.path]);
    switch (choice) {
      case UnsavedChoice.cancel:
        return AppExitResponse.cancel;
      case UnsavedChoice.discard:
        return AppExitResponse.exit;
      case UnsavedChoice.save:
        for (final t in dirty) {
          await ws.save(t);
        }
        return AppExitResponse.exit;
    }
  }

  // --- commands ----------------------------------------------------------------------------------------------------

  Future<void> openFolder() async {
    final picked = await (widget.pickFolder ?? () => getDirectoryPath(confirmButtonText: 'Open'))();
    if (picked != null) await openPath(picked);
  }

  Future<void> openPath(String folder) async {
    if (!await _confirmLeavingUnsaved()) return;
    await ws.project.open(folder);
  }

  Future<bool> _confirmLeavingUnsaved() async {
    final dirty = ws.tabs.where((t) => t.dirty).toList();
    if (dirty.isEmpty) return true;
    final choice = await askUnsaved(context, [for (final t in dirty) t.path]);
    if (choice == UnsavedChoice.cancel) return false;
    if (choice == UnsavedChoice.save) {
      for (final t in dirty) {
        await ws.save(t);
      }
    }
    return true;
  }

  Future<void> closeTab(int i) async {
    final tab = ws.tabs[i];
    if (tab.dirty) {
      final choice = await askUnsaved(context, [tab.path]);
      if (choice == UnsavedChoice.cancel) return;
      if (choice == UnsavedChoice.save) await ws.save(tab);
    }
    // Unfocus first: re_editor stops its cursor blink timer on focus loss, before the editor is disposed.
    FocusManager.instance.primaryFocus?.unfocus();
    await WidgetsBinding.instance.endOfFrame;
    ws.close(ws.tabs.indexOf(tab));
  }

  Future<void> save(EditorTab tab) async {
    try {
      await ws.save(tab);
    } on Object catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cannot save ${tab.path}: $e')));
    }
  }

  Future<void> quickOpenFile() async {
    final index = ws.index;
    if (index == null) return;
    final path = await showQuickPick<String>(
      context,
      hint: 'Go to file',
      search: (q) {
        final query = q.toLowerCase();
        final matches = index.order.where((f) => f.toLowerCase().contains(query)).toList()
          ..sort((a, b) {
            final an = p.basename(a).toLowerCase().contains(query) ? 0 : 1;
            final bn = p.basename(b).toLowerCase().contains(query) ? 0 : 1;
            return an != bn ? an - bn : a.compareTo(b);
          });
        return [
          for (final f in matches.take(200))
            PickItem(f, p.basename(f), detail: p.dirname(f), icon: Icons.description_outlined),
        ];
      },
    );
    if (path != null) await ws.open(path);
  }

  Future<void> quickOpenObject() async {
    final index = ws.index;
    if (index == null) return;
    final colors = SyntaxColors.of(context);
    final object = await showQuickPick<DbObject>(
      context,
      hint: 'Go to object (table, view, procedure, function, type...)',
      search: (q) {
        final query = q.toLowerCase();
        final matches =
            index.objects.values.where((o) => o.isDefinedHere && o.key.qualified.toLowerCase().contains(query)).toList()
              ..sort((a, b) {
                final an = a.key.name.startsWith(query) ? 0 : 1;
                final bn = b.key.name.startsWith(query) ? 0 : 1;
                return an != bn ? an - bn : a.key.compareTo(b.key);
              });
        return [
          for (final o in matches.take(200))
            PickItem(
              o,
              o.key.qualified,
              detail: '${o.kind.label}  ${o.signature}',
              icon: iconOf(o.kind),
              iconColor: colors.forSpace(o.key.space),
            ),
        ];
      },
    );
    if (object != null) await ws.goToSpan(object.primary.nameSpan);
  }

  Future<void> goToDefinition() async {
    final tab = ws.current;
    if (tab == null) return;
    await _editorKeys[tab]?.currentState?.goToDefinition(tab.cursorOffset);
  }

  void findReferences() {
    final tab = ws.current;
    if (tab == null) return;
    ws.findReferencesAt(tab.path, tab.cursorOffset);
  }

  /// Ctrl+Shift+I: format the selection or the file; the summary says what was left as written and why.
  void formatCurrent() {
    final tab = ws.current;
    if (tab == null) return;
    final r = ws.format(tab);
    final reasons = <String, int>{};
    for (final s in r.skipped) {
      final key = s.reason.split(':').first;
      reasons[key] = (reasons[key] ?? 0) + 1;
    }
    final skipped = reasons.entries.map((e) => '${e.value}× ${e.key}').join('; ');
    final message = r.formattedStatements == 0 && skipped.isEmpty
        ? 'Already formatted.'
        : 'Formatted ${r.formattedStatements} statement${r.formattedStatements == 1 ? '' : 's'}'
              '${skipped.isEmpty ? '' : ' · left as written: $skipped'}';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(key: const Key('format.result'), content: Text(message), duration: const Duration(seconds: 6)),
      );
  }

  /// F2: rename the object or column at the cursor - name, preview, apply.
  Future<void> renameAtCursor() async {
    final tab = ws.current;
    if (tab == null) return;
    final target = ws.renameTarget(tab.path, tab.cursorOffset);
    if (target != null) await _rename(target);
  }

  Future<void> _rename(({ObjectKey object, String? column, String old, String label}) target) async {
    final index = ws.index;
    if (index == null) return;
    final name = await askNewName(context, target.label, target.old);
    if (name == null || name.isEmpty || !mounted) return;
    final plan = ws.planRenameOf(target.object, target.column, name);
    if (!await previewRename(context, index, plan) || !mounted) return;
    final refused = await ws.applyRename(plan);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: const Key('rename.result'),
        content: Text(refused ?? '${plan.title}: ${plan.editCount} places, ${plan.newFiles.length} new changeset(s)'),
      ),
    );
  }

  /// Ctrl+N: a new object or changeset from a template (only in folders with modules).
  Future<void> newFile({String? module}) async {
    final index = ws.index;
    if (index == null || !index.conventions.applies) return;
    final d = DateTime.now();
    final today = '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
    final file = await showNewFileDialog(context, index, today, module: module);
    if (file != null) await ws.createFile(file);
  }

  void showImpact() {
    final tab = ws.current;
    if (tab == null) return;
    ws.impactAt(tab.path, tab.cursorOffset);
  }

  void showGraph() {
    final tab = ws.current;
    if (tab == null) return;
    ws.showGraphAt(tab.path, tab.cursorOffset);
  }

  /// What each global command of the registry does (3.0 spec 001); menus add the commands that need a target.
  Map<String, VoidCallback> get actions => {
    'folder.open': () => unawaited(openFolder()),
    'file.goto': () => unawaited(quickOpenFile()),
    'file.new': () => unawaited(newFile()),
    'file.save': () {
      final tab = ws.current;
      if (tab != null) unawaited(save(tab));
    },
    'tab.close': () {
      if (ws.active >= 0) unawaited(closeTab(ws.active));
    },
    'tab.closeOthers': () {
      if (ws.active >= 0) unawaited(closeOthers(ws.active));
    },
    'tab.closeSaved': closeSaved,
    'tab.closeAll': () => unawaited(closeAll()),
    'object.goto': () => unawaited(quickOpenObject()),
    'nav.definition': () => unawaited(goToDefinition()),
    'nav.references': findReferences,
    'nav.back': () => unawaited(ws.back()),
    'nav.forward': () => unawaited(ws.forward()),
    'nav.graph': showGraph,
    'nav.impact': showImpact,
    'nav.history': () {
      final tab = ws.current;
      if (tab != null) ws.showHistoryAt(tab.path, tab.cursorOffset);
    },
    'edit.format': formatCurrent,
    'edit.quickFix': () => unawaited(quickFixAtCursor()),
    'edit.rename': () => unawaited(renameAtCursor()),
    'search.project': () {
      // The selected text of the editor starts the search.
      final tab = ws.current;
      ws.openSearch(query: tab?.controller.selectedText);
    },
    'review.changes': () => unawaited(ws.showChanges()),
    'view.zoomIn': () => ws.settings.zoom(1),
    'view.zoomOut': () => ws.settings.zoom(-1),
    'view.zoomReset': () => ws.settings.zoom(0),
    'view.settings': () => unawaited(showSettingsDialog(context, ws.settings)),
    'help.open': () => unawaited(openHelp()),
    'terminal.toggle': toggleTerminal,
    'terminal.new': () => openTerminal(),
    'palette.open': () => unawaited(openPalette()),
  };

  /// Why a global command cannot run now (null = it can); the palette lists it disabled with this reason.
  String? unavailable(String id) {
    final tab = ws.current;
    final index = ws.index;
    const needTab = {
      'file.save',
      'tab.close',
      'tab.closeOthers',
      'tab.closeSaved',
      'tab.closeAll',
      'nav.definition',
      'nav.references',
      'nav.graph',
      'nav.impact',
      'nav.history',
      'edit.format',
      'edit.quickFix',
      'edit.rename',
    };
    if (needTab.contains(id) && tab == null) return 'no file is open';
    const needIndex = {
      'file.goto',
      'object.goto',
      'search.project',
      'review.changes',
      'terminal.toggle',
      'terminal.new',
    };
    if (needIndex.contains(id) && index == null) return 'no folder is open';
    return switch (id) {
      'file.new' when index?.conventions.applies != true => 'only in folders with changelog/modules/',
      'nav.back' when !ws.canGoBack => 'nothing to go back to',
      'nav.forward' when !ws.canGoForward => 'nothing to go forward to',
      'edit.quickFix' when fixAt(tab!, tab.cursorOffset) == null => 'no quick fix on this line',
      'palette.open' => 'already open',
      _ => null,
    };
  }

  /// Ctrl+Shift+P: every global command of the registry by name or description (3.0 spec 004).
  Future<void> openPalette() async {
    final list = [
      for (final section in CommandSection.values)
        for (final c in appCommands)
          if (c.section == section && c.global && !c.editorKeys) c,
    ];
    final id = await showQuickPick<String>(
      context,
      hint: 'Run a command',
      search: (q) {
        final query = q.toLowerCase();
        return [
          for (final c in list)
            if (query.isEmpty ||
                c.title.toLowerCase().contains(query) ||
                c.description.toLowerCase().contains(query) ||
                c.section.title.toLowerCase().contains(query))
              () {
                final why = unavailable(c.id);
                return PickItem(
                  c.id,
                  c.title,
                  detail: why == null ? c.section.title : 'not available: $why',
                  icon: c.icon,
                  trailing: c.shortcut,
                  enabled: why == null,
                );
              }(),
        ];
      },
    );
    if (id != null) run(id);
  }

  BottomPanel _beforeTerminal = BottomPanel.problems;

  /// Ctrl+`: the Terminal panel with the keyboard in it; pressed again (in the terminal), the previous panel.
  void toggleTerminal() {
    if (ws.panel == BottomPanel.terminal) {
      FocusManager.instance.primaryFocus?.unfocus();
      ws.showPanel(_beforeTerminal);
      return;
    }
    _beforeTerminal = ws.panel;
    ws.showPanel(BottomPanel.terminal);
    ws.terminals.requestFocus();
  }

  /// A new terminal in [dir] (default: the project folder), shown and focused.
  void openTerminal([String? dir]) {
    final root = ws.project.root;
    if (root == null) return;
    if (ws.panel != BottomPanel.terminal) _beforeTerminal = ws.panel;
    ws.terminals.open(dir ?? root, fontSize: ws.settings.fontSize);
    ws.showPanel(BottomPanel.terminal);
    ws.terminals.requestFocus();
  }

  /// F1: the description of the problem on the cursor line, else the help.
  Future<void> openHelp() async {
    final tab = ws.current;
    final x = tab == null ? null : problemAt(tab, tab.cursorOffset);
    await showHelp(context, problem: x?.code);
  }

  /// A problem at [offset] or on its line.
  Problem? problemAt(EditorTab tab, int offset) {
    final problems = ws.index?.problemsIn(tab.path) ?? const <Problem>[];
    final (line, _) = tab.lineColumn(offset);
    return problems.where((x) => x.span.start <= offset && offset <= x.span.end).firstOrNull ??
        problems.where((x) => tab.lineColumn(x.span.start).$1 == line).firstOrNull;
  }

  /// Runs a global command by id (the palette and tests).
  void run(String id) => actions[id]?.call();

  /// The keys of every global command, from the registry; the editor's own keys (copy, paste...) are not bound here.
  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    final a = actions;
    return {
      for (final c in appCommands)
        if (!c.editorKeys && a[c.id] != null)
          for (final k in c.keys) k: a[c.id]!,
    };
  }

  /// `Title (shortcut)` of a command, for tooltips.
  static String tip(String id) {
    final c = command(id);
    return c.shortcut == null ? c.title : '${c.title} (${c.shortcut})';
  }

  // --- targets picked in menus ---------------------------------------------------------------------------------------

  Future<void> closeOthers(int keep) async {
    final tab = ws.tabs[keep];
    for (final t in [...ws.tabs]) {
      if (t != tab && ws.tabs.contains(t)) await closeTab(ws.tabs.indexOf(t));
    }
  }

  void closeSaved() {
    for (final t in [...ws.tabs]) {
      if (!t.dirty) ws.close(ws.tabs.indexOf(t));
    }
  }

  Future<void> closeAll() async {
    for (final t in [...ws.tabs]) {
      if (ws.tabs.contains(t)) await closeTab(ws.tabs.indexOf(t));
    }
  }

  /// The problem with a quick fix at the cursor (on its line), if any.
  Problem? fixAt(EditorTab tab, int offset) {
    final problems = ws.index?.problemsIn(tab.path) ?? const <Problem>[];
    final (line, _) = tab.lineColumn(offset);
    for (final x in problems) {
      if (x.fix == null) continue;
      if (x.span.start <= offset && offset <= x.span.end) return x;
      if (tab.lineColumn(x.span.start).$1 == line) return x;
    }
    return null;
  }

  Future<void> quickFixAtCursor() async {
    final tab = ws.current;
    if (tab == null) return;
    final x = fixAt(tab, tab.cursorOffset);
    if (x != null) await ws.applyFix(x);
  }

  /// Rename of an object picked in the tree.
  Future<void> renameObject(DbObject o) =>
      _rename((object: o.key, column: null, old: o.key.name, label: '${o.kind.label} ${o.key.qualified}'));

  /// Opens the folder of [path] (relative) in the desktop file manager.
  Future<void> reveal(String path) async {
    final dir = p.dirname(p.join(ws.project.root!, path));
    try {
      await Process.start('xdg-open', [dir], mode: ProcessStartMode.detached);
    } on Object catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cannot open $dir: $e')));
    }
  }

  /// The context menu of the editor at [global] (the cursor is already where the user clicked).
  Future<void> editorMenu(EditorTab tab, Offset global) async {
    final offset = tab.cursorOffset;
    final objects = ws.objectsAt(tab.path, offset);
    final column = ws.index?.columnAt(tab.path, offset);
    final onName = objects.isNotEmpty || column != null;
    final fix = fixAt(tab, offset);
    final problem = problemAt(tab, offset);
    final selection = !tab.controller.selection.isCollapsed;
    await showCommandMenu(context, global, [
      MenuEntry('nav.definition', goToDefinition, enabled: ws.definitionsAt(tab.path, offset).isNotEmpty),
      MenuEntry('nav.references', findReferences, enabled: onName),
      MenuEntry('nav.impact', showImpact, enabled: onName),
      MenuEntry('nav.graph', showGraph, enabled: objects.isNotEmpty),
      MenuEntry('nav.history', actions['nav.history'], enabled: onName),
      const MenuEntry.divider(),
      MenuEntry('edit.rename', renameAtCursor, enabled: ws.renameTarget(tab.path, offset) != null),
      MenuEntry('edit.format', formatCurrent),
      if (fix != null) MenuEntry('edit.quickFix', () => ws.applyFix(fix), title: 'Fix: ${quickFixTitle(fix.fix!)}'),
      if (problem?.code != null) MenuEntry('help.problem', () => showHelp(context, problem: problem!.code)),
      const MenuEntry.divider(),
      MenuEntry('edit.cut', tab.controller.cut, enabled: selection),
      MenuEntry('edit.copy', tab.controller.copy, enabled: selection),
      MenuEntry('edit.paste', tab.controller.paste),
      MenuEntry('edit.selectAll', tab.controller.selectAll),
    ]);
  }

  /// The context menu of a tab.
  Future<void> tabMenu(int i, Offset global) async {
    final tab = ws.tabs[i];
    await showCommandMenu(context, global, [
      MenuEntry('tab.close', () => closeTab(ws.tabs.indexOf(tab))),
      MenuEntry('tab.closeOthers', () => closeOthers(ws.tabs.indexOf(tab)), enabled: ws.tabs.length > 1),
      MenuEntry('tab.closeSaved', closeSaved, enabled: ws.tabs.any((t) => !t.dirty)),
      MenuEntry('tab.closeAll', closeAll),
      const MenuEntry.divider(),
      MenuEntry('path.copy', () => copyToClipboard(context, tab.path)),
      MenuEntry('file.reveal', () => reveal(tab.path)),
    ]);
  }

  // --- layout ------------------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final project = ws.project;
    return CallbackShortcuts(
      bindings: _shortcuts,
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              _toolbar(),
              const Divider(height: 1),
              Expanded(
                child: project.root == null
                    ? _start()
                    : project.indexing && project.index == null
                    ? _indexing()
                    : project.error != null
                    ? Center(child: Text(project.error!))
                    : _workbench(),
              ),
              _statusBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbar() {
    final theme = Theme.of(context);
    final project = ws.project;
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: theme.colorScheme.surfaceContainer,
      child: Row(
        children: [
          Icon(Icons.storage_rounded, color: theme.colorScheme.primary, size: 20),
          const SizedBox(width: 8),
          Text('PG Studio', style: theme.textTheme.titleSmall),
          const SizedBox(width: 16),
          TextButton.icon(
            key: const Key('toolbar.open'),
            onPressed: openFolder,
            icon: const Icon(Icons.folder_open_outlined, size: 18),
            label: const Text('Open folder'),
          ),
          if (project.recent.isNotEmpty)
            PopupMenuButton<String>(
              key: const Key('toolbar.recent'),
              tooltip: 'Recent folders',
              icon: const Icon(Icons.history, size: 18),
              onSelected: (f) => unawaited(openPath(f)),
              itemBuilder: (context) => [for (final r in project.recent) PopupMenuItem(value: r, child: Text(r))],
            ),
          if (project.root != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                project.root!,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ] else
            const Spacer(),
          if (project.root != null) const Spacer(),
          IconButton(
            tooltip: tip('nav.back'),
            onPressed: ws.canGoBack ? () => unawaited(ws.back()) : null,
            icon: const Icon(Icons.arrow_back, size: 18),
          ),
          IconButton(
            tooltip: tip('nav.forward'),
            onPressed: ws.canGoForward ? () => unawaited(ws.forward()) : null,
            icon: const Icon(Icons.arrow_forward, size: 18),
          ),
          IconButton(
            key: const Key('toolbar.new'),
            tooltip: tip('file.new'),
            onPressed: ws.index?.conventions.applies == true ? () => unawaited(newFile()) : null,
            icon: const Icon(Icons.note_add_outlined, size: 20),
          ),
          IconButton(
            key: const Key('toolbar.format'),
            tooltip: tip('edit.format'),
            onPressed: ws.current == null ? null : formatCurrent,
            icon: const Icon(Icons.format_align_left, size: 20),
          ),
          IconButton(
            key: const Key('toolbar.impact'),
            tooltip: tip('nav.impact'),
            onPressed: ws.current == null ? null : showImpact,
            icon: const Icon(Icons.crisis_alert_outlined, size: 20),
          ),
          IconButton(
            key: const Key('toolbar.graph'),
            tooltip: tip('nav.graph'),
            onPressed: ws.current == null ? null : showGraph,
            icon: const Icon(Icons.account_tree_outlined, size: 20),
          ),
          IconButton(
            key: const Key('toolbar.objects'),
            tooltip: tip('object.goto'),
            onPressed: ws.index == null ? null : () => unawaited(quickOpenObject()),
            icon: const Icon(Icons.manage_search, size: 20),
          ),
          IconButton(
            tooltip: tip('file.goto'),
            onPressed: ws.index == null ? null : () => unawaited(quickOpenFile()),
            icon: const Icon(Icons.find_in_page_outlined, size: 20),
          ),
          IconButton(
            key: const Key('toolbar.help'),
            tooltip: tip('help.open'),
            onPressed: () => unawaited(showHelp(context)),
            icon: const Icon(Icons.help_outline, size: 20),
          ),
          IconButton(
            key: const Key('toolbar.settings'),
            tooltip: tip('view.settings'),
            onPressed: () => unawaited(showSettingsDialog(context, ws.settings)),
            icon: const Icon(Icons.settings_outlined, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _start() {
    final theme = Theme.of(context);
    final recent = ws.project.recent;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('SQL Postgres Project', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text(
              'Open a folder with database files (SQL, Liquibase changesets). It is analysed without a database connection.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('start.open'),
              onPressed: openFolder,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('Open folder…  (Ctrl+O)'),
            ),
            if (recent.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text('Recent', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final r in recent)
                TextButton(
                  onPressed: () => unawaited(openPath(r)),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(r, overflow: TextOverflow.ellipsis),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _indexing() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [const CircularProgressIndicator(), const SizedBox(height: 12), Text('Analysing ${ws.project.root}…')],
    ),
  );

  Widget _workbench() {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: sidebarWidth,
          child: Sidebar(workspace: ws, host: this),
        ),
        _Splitter(
          axis: Axis.vertical,
          onDrag: (d) => setState(() => sidebarWidth = (sidebarWidth + d).clamp(200, 700)),
        ),
        Expanded(
          child: Column(
            children: [
              _tabs(),
              Expanded(
                child: ws.current == null
                    ? Center(
                        child: Text(
                          'Open a file from the tree, Ctrl+P (file) or Ctrl+T (object).',
                          style: theme.textTheme.bodySmall,
                        ),
                      )
                    : _editors(),
              ),
              _Splitter(axis: Axis.horizontal, onDrag: (d) => setPanelHeight(panelHeight - d)),
              SizedBox(
                height: panelHeight,
                child: BottomPanelView(workspace: ws, onToggleTerminal: toggleTerminal),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// One editor per tab, kept alive while the tab is open: each keeps its scroll position, and switching tabs does
  /// not dispose a focused re_editor (its cursor blink timer outlives a disposed editor).
  Widget _editors() {
    _editorKeys.removeWhere((tab, _) => !ws.tabs.contains(tab));
    return IndexedStack(
      index: ws.active,
      sizing: StackFit.expand,
      children: [
        for (final tab in ws.tabs)
          EditorView(
            key: _editorKeys.putIfAbsent(tab, () => GlobalKey<EditorViewState>(debugLabel: tab.path)),
            workspace: ws,
            tab: tab,
            onChoose: (title, places) => chooseLocation(context, title, places),
            onContextMenu: (global) => unawaited(editorMenu(tab, global)),
            onSave: save,
          ),
      ],
    );
  }

  Widget _tabs() {
    final theme = Theme.of(context);
    if (ws.tabs.isEmpty) return const SizedBox(height: 0);
    return Container(
      height: 34,
      color: theme.colorScheme.surfaceContainerLow,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: ws.tabs.length,
        itemBuilder: (context, i) {
          final tab = ws.tabs[i];
          final active = i == ws.active;
          return InkWell(
            key: Key('tab.${tab.path}'),
            onTap: () => ws.activate(i),
            onSecondaryTapUp: (d) => unawaited(tabMenu(i, d.globalPosition)),
            child: Container(
              padding: const EdgeInsets.only(left: 12, right: 4),
              decoration: BoxDecoration(
                color: active ? theme.colorScheme.surface : null,
                border: Border(
                  bottom: BorderSide(color: active ? theme.colorScheme.primary : Colors.transparent, width: 2),
                  right: BorderSide(color: theme.dividerColor.withValues(alpha: 0.3)),
                ),
              ),
              child: Row(
                children: [
                  Tooltip(
                    message: tab.path,
                    child: Text(tab.name, style: theme.textTheme.bodySmall),
                  ),
                  if (tab.dirty)
                    Padding(
                      key: Key('tab.dirty.${tab.path}'),
                      padding: const EdgeInsets.only(left: 6),
                      child: Icon(Icons.circle, size: 8, color: theme.colorScheme.primary),
                    ),
                  IconButton(
                    key: Key('tab.close.${tab.path}'),
                    visualDensity: VisualDensity.compact,
                    iconSize: 14,
                    tooltip: tip('tab.close'),
                    onPressed: () => unawaited(closeTab(i)),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _statusBar() {
    final theme = Theme.of(context);
    final project = ws.project;
    final index = project.index;
    final style = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final parts = <String>[];
    if (index != null) {
      final errors = index.allProblems.where((x) => x.severity == Severity.error).length;
      final warnings = index.allProblems.where((x) => x.severity == Severity.warning).length;
      parts.add('${index.files.length} files');
      parts.add('${index.objects.length} objects');
      parts.add('${index.references.length} references');
      parts.add('$errors errors, $warnings warnings');
      if (index.conventions.applies) parts.add('${index.conventions.modules.length} modules');
      final t = project.timing;
      if (t != null) parts.add('indexed in ${t.total.inMilliseconds} ms');
    }
    final tab = ws.current;
    return Container(
      key: const Key('statusbar'),
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: theme.colorScheme.surfaceContainer,
      child: Row(
        children: [
          if (project.indexing) ...[
            const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
            const SizedBox(width: 6),
            Text('Indexing…', style: style),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Text(parts.join('  ·  '), style: style, overflow: TextOverflow.ellipsis),
          ),
          // The cursor moves without the workspace notifying: listen to the editor itself.
          if (tab != null)
            ListenableBuilder(
              listenable: tab.controller,
              builder: (context, _) {
                final (line, column) = tab.lineColumn(tab.cursorOffset);
                return Text('Ln ${line + 1}, Col ${column + 1}', key: const Key('status.cursor'), style: style);
              },
            ),
        ],
      ),
    );
  }
}

class _Splitter extends StatelessWidget {
  const _Splitter({required this.axis, required this.onDrag});

  /// vertical: a vertical line dragged left/right.
  final Axis axis;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final vertical = axis == Axis.vertical;
    return MouseRegion(
      cursor: vertical ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: vertical ? (d) => onDrag(d.delta.dx) : null,
        onVerticalDragUpdate: vertical ? null : (d) => onDrag(d.delta.dy),
        child: SizedBox(
          width: vertical ? 5 : double.infinity,
          height: vertical ? double.infinity : 5,
          child: Center(
            child: Container(
              width: vertical ? 1 : double.infinity,
              height: vertical ? double.infinity : 1,
              color: Theme.of(context).dividerColor,
            ),
          ),
        ),
      ),
    );
  }
}
