import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';

import '../app/workspace.dart';
import 'command_menu.dart';
import 'home_page.dart';
import 'theme.dart';
import 'tree.dart';

enum SidebarView { files, objects, modules }

/// Files as on disk, objects by schema, or objects by module (when the folder has modules).
class Sidebar extends StatefulWidget {
  const Sidebar({super.key, required this.workspace, this.host});

  final Workspace workspace;

  /// Runs the commands of the context menus that need dialogs (rename, new file); null in isolated tests.
  final HomePageState? host;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  SidebarView view = SidebarView.files;
  String filter = '';

  Workspace get ws => widget.workspace;

  void _menu(Offset global, List<MenuEntry> entries) => unawaited(showCommandMenu(context, global, entries));

  /// File or folder ([dir]) in the Files tree.
  void _pathMenu(String path, Offset global, {bool dir = false}) {
    final index = ws.index!;
    final host = widget.host;
    final module = dir
        ? index.conventions.modules.where((m) => m.folder == path || path.startsWith('${m.folder}/')).firstOrNull
        : index.conventions.moduleOfFile(path);
    _menu(global, [
      if (!dir) MenuEntry('row.open', () => ws.open(path)),
      if (module != null && host != null)
        MenuEntry('file.newInModule', () => host.newFile(module: module.name), title: 'New object in ${module.label}…'),
      const MenuEntry.divider(),
      MenuEntry('path.copy', () => copyToClipboard(context, path)),
      if (host != null) MenuEntry('file.reveal', () => host.reveal(dir ? '$path/.' : path)),
      if (host != null)
        MenuEntry('terminal.here', () => host.openTerminal(p.join(ws.project.root!, dir ? path : p.dirname(path)))),
    ]);
  }

  /// An object in the Objects or Modules tree.
  void _objectMenu(DbObject o, Offset global) {
    final index = ws.index!;
    final host = widget.host;
    final schema = o.key.schema;
    _menu(global, [
      MenuEntry('nav.definition', () => ws.goToSpan(o.primary.nameSpan), title: 'Go to definition'),
      MenuEntry('nav.references', () => ws.findReferences(o)),
      MenuEntry('nav.graph', () => ws.showGraph(o)),
      MenuEntry(
        'object.er',
        () => ws.showEr('schema:$schema'),
        title: 'ER diagram of $schema',
        enabled: schemasWithTables(index).contains(schema),
      ),
      MenuEntry(
        'er.newWindow',
        () => ws.openErWindow('schema:$schema'),
        enabled: schemasWithTables(index).contains(schema),
      ),
      MenuEntry('nav.history', () => ws.showHistory(o)),
      const MenuEntry.divider(),
      if (host != null) MenuEntry('edit.rename', () => host.renameObject(o), enabled: o.isDefinedHere),
    ]);
  }

  /// A schema node (by schema or inside a module) or a module node.
  void _groupMenu(Offset global, {String? schema, ModuleInfo? module}) {
    final index = ws.index!;
    final host = widget.host;
    _menu(global, [
      if (schema != null)
        MenuEntry(
          'object.er',
          () => ws.showEr('schema:$schema'),
          title: 'ER diagram of $schema',
          enabled: schemasWithTables(index).contains(schema),
        ),
      if (schema != null)
        MenuEntry(
          'er.newWindow',
          () => ws.openErWindow('schema:$schema'),
          enabled: schemasWithTables(index).contains(schema),
        ),
      if (module != null) ...[
        MenuEntry('object.er', () => ws.showEr('module:${module.name}'), title: 'ER diagram of ${module.label}'),
        MenuEntry('er.newWindow', () => ws.openErWindow('module:${module.name}')),
        if (host != null)
          MenuEntry(
            'file.newInModule',
            () => host.newFile(module: module.name),
            title: 'New object in ${module.label}…',
          ),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final index = ws.index;
    final hasModules = index?.conventions.applies ?? false;
    if (!hasModules && view == SidebarView.modules) view = SidebarView.objects;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: SegmentedButton<SidebarView>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              const ButtonSegment(value: SidebarView.files, label: Text('Files')),
              const ButtonSegment(value: SidebarView.objects, label: Text('Objects')),
              if (hasModules) const ButtonSegment(value: SidebarView.modules, label: Text('Modules')),
            ],
            selected: {view},
            onSelectionChanged: (s) => setState(() => view = s.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
          child: TextField(
            key: const Key('sidebar.filter'),
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.filter_list, size: 18),
              hintText: 'Filter',
              border: OutlineInputBorder(),
            ),
            style: Theme.of(context).textTheme.bodySmall,
            onChanged: (v) => setState(() => filter = v.trim().toLowerCase()),
          ),
        ),
        Expanded(
          child: index == null
              ? const SizedBox.shrink()
              : TreeList(
                  key: ValueKey('${view.name}:${filter.isEmpty}'),
                  roots: switch (view) {
                    SidebarView.files => _files(index),
                    SidebarView.objects => _objectsBySchema(index),
                    SidebarView.modules => _objectsByModule(index),
                  },
                  expandAll: filter.isNotEmpty,
                  initiallyExpanded: _initiallyExpanded(index),
                ),
        ),
      ],
    );
  }

  Set<String> _initiallyExpanded(ProjectIndex index) {
    if (view != SidebarView.files) return const {};
    // The folders up to the first level of files.
    final open = <String>{};
    for (final path in index.order.take(1)) {
      final parts = path.split('/');
      for (var i = 1; i < parts.length; i++) {
        open.add('dir:${parts.take(i).join('/')}');
      }
    }
    return open;
  }

  bool _matches(String text) => filter.isEmpty || text.toLowerCase().contains(filter);

  List<TreeItem> _files(ProjectIndex index) {
    final root = _Dir('');
    final paths = [...index.order]..sort();
    for (final path in paths) {
      if (!_matches(path)) continue;
      final parts = path.split('/');
      var dir = root;
      for (var i = 0; i < parts.length - 1; i++) {
        dir = dir.dirs.putIfAbsent(parts[i], () => _Dir(parts.take(i + 1).join('/')));
      }
      dir.files.add(path);
    }
    final colors = SyntaxColors.of(context);
    final current = ws.current?.path;
    List<TreeItem> build(_Dir d) => [
      for (final e in d.dirs.entries)
        TreeItem(
          id: 'dir:${e.value.path}',
          label: e.key,
          icon: Icons.folder_outlined,
          children: build(e.value),
          onContextMenu: (g) => _pathMenu(e.value.path, g, dir: true),
        ),
      for (final f in d.files)
        () {
          final problems = index.problemsIn(f);
          final errors = problems.where((x) => x.severity == Severity.error).length;
          final warnings = problems.where((x) => x.severity == Severity.warning).length;
          return TreeItem(
            id: 'file:$f',
            label: f.split('/').last,
            icon: Icons.description_outlined,
            selected: f == current,
            tooltip: f,
            onTap: () => ws.open(f),
            onContextMenu: (g) => _pathMenu(f, g),
            trailing: errors + warnings == 0
                ? null
                : Text(
                    '${errors + warnings}',
                    style: TextStyle(fontSize: 11, color: errors > 0 ? colors.error : colors.warning),
                  ),
          );
        }(),
    ];
    return build(root);
  }

  TreeItem _object(DbObject o) {
    final colors = SyntaxColors.of(context);
    return TreeItem(
      id: 'obj:${o.key}',
      label: o.key.space == ObjectSpace.routine ? '${o.key.name}(${o.key.signature})' : o.key.name,
      icon: iconOf(o.kind),
      iconColor: colors.forSpace(o.key.space),
      tooltip: o.signature,
      onTap: () => ws.goToSpan(o.primary.nameSpan),
      onContextMenu: (g) => _objectMenu(o, g),
    );
  }

  List<TreeItem> _kinds(String prefix, Iterable<DbObject> objects) {
    final byKind = <ObjectKind, List<DbObject>>{};
    for (final o in objects) {
      if (o.kind == ObjectKind.schema || !o.isDefinedHere) continue;
      (byKind[o.kind] ??= []).add(o);
    }
    return [
      for (final kind in ObjectKind.values)
        if (byKind[kind] != null)
          TreeItem(
            id: '$prefix:${kind.name}',
            label: '${_plural(kind)} (${byKind[kind]!.length})',
            icon: iconOf(kind),
            children: [for (final o in byKind[kind]!..sort((a, b) => a.key.compareTo(b.key))) _object(o)],
          ),
    ];
  }

  List<TreeItem> _objectsBySchema(ProjectIndex index) {
    final bySchema = <String, List<DbObject>>{};
    for (final o in index.objects.values) {
      if (o.key.space == ObjectSpace.schema || o.key.space == ObjectSpace.extension) continue;
      if (!_matches(o.key.qualified)) continue;
      (bySchema[o.key.schema] ??= []).add(o);
    }
    final extensions = index.objects.values
        .where((o) => o.kind == ObjectKind.extension && _matches(o.key.name))
        .toList();
    final schemas = bySchema.keys.toList()..sort();
    return [
      for (final s in schemas)
        TreeItem(
          id: 'schema:$s',
          label: s,
          icon: Icons.folder_special_outlined,
          children: _kinds('schema:$s', bySchema[s]!),
          onContextMenu: (g) => _groupMenu(g, schema: s),
        ),
      if (extensions.isNotEmpty)
        TreeItem(
          id: 'extensions',
          label: 'extensions (${extensions.length})',
          icon: Icons.extension_outlined,
          children: [for (final e in extensions) _object(e)],
        ),
    ];
  }

  List<TreeItem> _objectsByModule(ProjectIndex index) {
    final c = index.conventions;
    final items = <TreeItem>[];
    for (final m in c.modules) {
      final schemas = <TreeItem>[];
      for (final schema in [m.name, '${m.name}_app', '${m.name}_internal']) {
        final objects = index.objects.values.where((o) => o.key.schema == schema && _matches(o.key.qualified)).toList();
        if (objects.isEmpty) continue;
        schemas.add(
          TreeItem(
            id: 'module:${m.name}:$schema',
            label: schema == '${m.name}_app' ? '$schema (contract)' : schema,
            icon: Icons.folder_special_outlined,
            children: _kinds('module:${m.name}:$schema', objects),
            onContextMenu: (g) => _groupMenu(g, schema: schema),
          ),
        );
      }
      if (schemas.isEmpty) continue;
      items.add(
        TreeItem(
          id: 'module:${m.name}',
          label: m.label,
          icon: Icons.view_module_outlined,
          children: schemas,
          onContextMenu: (g) => _groupMenu(g, module: m),
        ),
      );
    }
    final moduleSchemas = {for (final m in c.modules) ...m.schemas};
    final rest = index.objects.values
        .where((o) => o.key.schema.isNotEmpty && !moduleSchemas.contains(o.key.schema) && _matches(o.key.qualified))
        .toList();
    if (rest.isNotEmpty) {
      items.add(
        TreeItem(
          id: 'module:-',
          label: 'outside modules',
          icon: Icons.folder_outlined,
          children: _kinds('module:-', rest),
        ),
      );
    }
    return items;
  }

  static String _plural(ObjectKind k) => switch (k) {
    ObjectKind.tableIndex => 'indexes',
    ObjectKind.materializedView => 'materialized views',
    _ => '${k.label}s',
  };
}

class _Dir {
  _Dir(this.path);

  final String path;
  final Map<String, _Dir> dirs = {};
  final List<String> files = [];
}
