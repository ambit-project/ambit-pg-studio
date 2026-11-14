import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';

import '../app/workspace.dart';
import 'command_menu.dart';
import 'er_view.dart';
import 'help_dialog.dart';
import 'graph_view.dart';
import 'search_panel.dart';
import 'terminal_panel.dart';
import 'theme.dart';

/// Problems, Find references results, error codes and module contracts.
class BottomPanelView extends StatefulWidget {
  const BottomPanelView({super.key, required this.workspace, this.onToggleTerminal});

  final Workspace workspace;

  /// Ctrl+` pressed inside the terminal.
  final VoidCallback? onToggleTerminal;

  @override
  State<BottomPanelView> createState() => _BottomPanelViewState();
}

class _BottomPanelViewState extends State<BottomPanelView> {
  final Map<String, List<String>> _lines = {};
  int _linesGeneration = -1;
  String _codeFilter = '';

  Workspace get ws => widget.workspace;

  /// A line of a file for previews: the open tab's text, else the disk.
  String lineText(Location at) {
    if (_linesGeneration != ws.project.generation) {
      _lines.clear();
      _linesGeneration = ws.project.generation;
    }
    final tab = ws.tabs.where((t) => t.path == at.path).firstOrNull;
    if (tab != null) {
      final (line, _) = tab.lineColumn(at.offset);
      final start = tab.lineStarts[line];
      final end = line + 1 < tab.lineStarts.length ? tab.lineStarts[line + 1] - 1 : tab.text.length;
      return tab.text.substring(start, end.clamp(start, tab.text.length)).trim();
    }
    final file = ws.index?.files[at.path];
    if (file == null) return '';
    final lines = _lines.putIfAbsent(at.path, () {
      try {
        return File(p.join(ws.project.root!, at.path)).readAsLinesSync();
      } on Object {
        return const <String>[];
      }
    });
    final line = file.lineColumn(at.offset).$1;
    return line < lines.length ? lines[line].trim() : '';
  }

  String position(Location at) {
    final file = ws.index?.files[at.path];
    if (file == null) return at.path;
    final (line, column) = file.lineColumn(at.offset);
    return '${at.path}:${line + 1}:${column + 1}';
  }

  @override
  Widget build(BuildContext context) {
    final index = ws.index;
    final problems = index?.allProblems ?? const <Problem>[];
    final codes = index?.conventions.errorCodes ?? const <String, List<ErrorCodeUse>>{};
    final theme = Theme.of(context);
    Widget tab(BottomPanel panel, String label, IconData icon) {
      final selected = ws.panel == panel;
      return TextButton.icon(
        key: Key('panel.${panel.name}'),
        onPressed: () => ws.showPanel(panel),
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
          backgroundColor: selected ? theme.colorScheme.primary.withValues(alpha: 0.10) : null,
          visualDensity: VisualDensity.compact,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: theme.colorScheme.surfaceContainerLow,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                tab(BottomPanel.problems, 'Problems (${problems.length})', Icons.report_outlined),
                tab(
                  BottomPanel.references,
                  'References${ws.references == null ? '' : ' (${ws.references!.count})'}',
                  Icons.link,
                ),
                tab(BottomPanel.search, 'Search', Icons.search),
                tab(BottomPanel.history, 'History', Icons.history_edu_outlined),
                tab(BottomPanel.changes, 'Changes', Icons.difference_outlined),
                tab(BottomPanel.graph, 'Graph', Icons.account_tree_outlined),
                if (codes.isNotEmpty) tab(BottomPanel.errorCodes, 'Error codes (${codes.length})', Icons.tag),
                if (index?.conventions.applies ?? false) tab(BottomPanel.contract, 'Contract', Icons.api_outlined),
                tab(
                  BottomPanel.terminal,
                  'Terminal${ws.terminals.sessions.length > 1 ? ' (${ws.terminals.sessions.length})' : ''}',
                  Icons.terminal,
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: switch (ws.panel) {
            BottomPanel.problems => _problems(problems),
            BottomPanel.references => _references(),
            BottomPanel.search => SearchPanel(workspace: ws),
            BottomPanel.history => _history(index),
            BottomPanel.changes => _changes(index),
            BottomPanel.graph => _graph(index),
            BottomPanel.errorCodes => _errorCodes(codes),
            BottomPanel.contract => _contract(index),
            BottomPanel.terminal => TerminalPanel(workspace: ws, onToggle: widget.onToggleTerminal),
          },
        ),
      ],
    );
  }

  Widget _row({
    Key? key,
    required Widget leading,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
    int indent = 0,
    Widget? trailing,
    Location? at,
    List<MenuEntry> menu = const [],
  }) {
    final theme = Theme.of(context);
    return InkWell(
      key: key,
      onTap: onTap,
      // 3.0 spec 001: open, the row's own commands, copy the row or its place.
      onSecondaryTapUp: at == null
          ? null
          : (d) => showCommandMenu(context, d.globalPosition, [
              MenuEntry('row.open', onTap),
              ...menu,
              const MenuEntry.divider(),
              MenuEntry('row.copy', () => copyToClipboard(context, subtitle == null ? title : '$title   $subtitle')),
              MenuEntry('row.copyLocation', () => copyToClipboard(context, position(at))),
            ]),
      child: Padding(
        padding: EdgeInsets.only(left: 8.0 + indent * 16, right: 8, top: 3, bottom: 3),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: title, style: theme.textTheme.bodySmall),
                    if (subtitle != null)
                      TextSpan(
                        text: '   $subtitle',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }

  Widget _empty(String text) => Center(child: Text(text, style: Theme.of(context).textTheme.bodySmall));

  Widget _problems(List<Problem> problems) {
    if (problems.isEmpty) return _empty('No problems.');
    final colors = SyntaxColors.of(context);
    return ListView.builder(
      itemCount: problems.length,
      itemBuilder: (context, i) {
        final x = problems[i];
        final at = Location(x.span.file, x.span.start, x.span.end - x.span.start);
        return _row(
          key: Key('problem.$i'),
          leading: Icon(
            switch (x.severity) {
              Severity.error => Icons.error_outline,
              Severity.warning => Icons.warning_amber_outlined,
              Severity.info => Icons.info_outline,
            },
            size: 16,
            color: switch (x.severity) {
              Severity.error => colors.error,
              Severity.warning => colors.warning,
              Severity.info => null,
            },
          ),
          title: x.message.split('\n').first,
          subtitle: position(at),
          onTap: () => ws.goTo(at),
          at: at,
          menu: [
            if (x.fix != null) MenuEntry('edit.quickFix', () => ws.applyFix(x), title: 'Fix: ${quickFixTitle(x.fix!)}'),
            if (x.code != null) MenuEntry('help.problem', () => showHelp(context, problem: x.code)),
          ],
          trailing: x.fix == null
              ? null
              : TextButton(
                  key: Key('problem.fix.$i'),
                  onPressed: () => ws.applyFix(x),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  child: Text('Fix: ${quickFixTitle(x.fix!)}'),
                ),
        );
      },
    );
  }

  Widget _references() {
    final list = ws.references;
    if (list == null) return _empty('Find references: Shift+F12 on a name, or right-click an object in the tree.');
    final rows = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
        child: Text(list.title, style: Theme.of(context).textTheme.titleSmall),
      ),
    ];
    for (final (group, items) in list.places) {
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
          child: Text('$group (${items.length})', style: Theme.of(context).textTheme.labelMedium),
        ),
      );
      for (final (place, kind) in items) {
        rows.add(
          _row(
            key: Key('reference.${place.path}:${place.offset}'),
            indent: 1,
            leading: SizedBox(width: 82, child: Text(kind, style: Theme.of(context).textTheme.labelSmall)),
            title: lineText(place),
            subtitle: position(place),
            onTap: () => ws.goTo(place),
            at: place,
          ),
        );
      }
    }
    return ListView(children: rows);
  }

  Widget _graph(ProjectIndex? index) {
    if (index == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final object = ws.graphKey == null ? null : index.objects[ws.graphKey];
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
      child: Row(
        children: [
          SegmentedButton<int>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              const ButtonSegment(value: 0, label: Text('Object')),
              if (index.conventions.applies) const ButtonSegment(value: 1, label: Text('Modules')),
              const ButtonSegment(value: 2, label: Text('ER')),
            ],
            selected: {ws.erGraph ? 2 : (ws.moduleGraph && index.conventions.applies ? 1 : 0)},
            onSelectionChanged: (v) => switch (v.first) {
              1 => ws.showModuleGraph(),
              2 => ws.showEr(ws.erScope ?? _defaultErScope(index)),
              _ => object == null ? null : ws.showGraph(object),
            },
          ),
          const SizedBox(width: 12),
          if (ws.erGraph)
            DropdownButton<String>(
              key: const Key('er.scope'),
              value: ws.erScope,
              isDense: true,
              items: [
                for (final m in index.conventions.modules)
                  DropdownMenuItem(value: 'module:${m.name}', child: Text('module ${m.label}')),
                for (final sch in schemasWithTables(index))
                  DropdownMenuItem(value: 'schema:$sch', child: Text('schema $sch')),
              ],
              onChanged: (v) => ws.showEr(v!),
            ),
          if (!ws.erGraph && !ws.moduleGraph && object != null)
            Expanded(
              child: Text(
                '${object.kind.label} ${object.signature}',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
    final Widget body;
    if (ws.erGraph) {
      final scope = ws.erScope ?? _defaultErScope(index);
      body = ErView(workspace: ws, model: erModelFor(index, scope), scope: scope);
    } else if (ws.moduleGraph && index.conventions.applies) {
      body = ModuleGraphView(workspace: ws, graph: moduleGraph(index));
    } else if (object == null) {
      body = _empty('Ctrl+Shift+G on a name shows what it uses and what uses it.');
    } else {
      body = ObjectGraphView(workspace: ws, graph: objectGraph(index, object));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Expanded(child: body),
      ],
    );
  }

  Widget _history(ProjectIndex? index) {
    final object = index == null || ws.historyKey == null ? null : index.objects[ws.historyKey];
    if (index == null || object == null) {
      return _empty('Ctrl+Shift+H on a name: every change of the object and the effective DDL of a table.');
    }
    final theme = Theme.of(context);
    final h = objectHistory(index, object);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: editorFont, fontFamilyFallback: editorFontFallback);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 2,
          child: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                child: Text(
                  '${object.kind.label} ${object.key.qualified}: ${h.entries.length} changes',
                  key: const Key('history.title'),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              for (final (i, e) in h.entries.indexed)
                _row(
                  key: Key('history.entry.$i'),
                  leading: SizedBox(width: 80, child: Text(e.date, style: theme.textTheme.labelSmall)),
                  title: e.summary,
                  subtitle:
                      '${e.comment.isEmpty ? '' : '${e.comment}  '}${position(Location(e.span.file, e.span.start))}',
                  onTap: () => ws.goTo(Location(e.span.file, e.span.start)),
                  at: Location(e.span.file, e.span.start),
                ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 3,
          child: h.effectiveDdl == null
              ? _empty('No CREATE of this object in the project.')
              : Stack(
                  children: [
                    Positioned.fill(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(8),
                        child: SelectableText(h.effectiveDdl!, key: const Key('history.ddl'), style: mono),
                      ),
                    ),
                    Positioned(
                      right: 8,
                      top: 4,
                      child: IconButton(
                        tooltip: 'Copy',
                        icon: const Icon(Icons.copy, size: 16),
                        onPressed: () => Clipboard.setData(ClipboardData(text: h.effectiveDdl!)),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _changes(ProjectIndex? index) {
    final theme = Theme.of(context);
    final colors = SyntaxColors.of(context);
    if (!ws.reviewDone && !ws.reviewing && index != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ws.refreshReview());
    }
    final r = ws.review;
    final rows = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                ws.reviewing
                    ? 'Comparing with the main branch…'
                    : r == null
                    ? 'Not a git repository with a main branch.'
                    : 'Branch ${r.branch} against ${r.base}: ${r.files.length} files, ${r.objects.length} objects, '
                          '${r.newProblems.length} new problems',
                key: const Key('changes.title'),
                style: theme.textTheme.titleSmall,
              ),
            ),
            IconButton(
              key: const Key('changes.refresh'),
              tooltip: 'Compare again',
              onPressed: ws.reviewing ? null : () => ws.refreshReview(),
              icon: const Icon(Icons.refresh, size: 18),
            ),
          ],
        ),
      ),
    ];
    if (r != null && index != null) {
      void heading(String t) => rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
          child: Text(t, style: theme.textTheme.labelLarge),
        ),
      );
      if (r.warnings.isNotEmpty) {
        heading('Deployed changesets touched (${r.warnings.length})');
        for (final (c, w) in r.warnings) {
          rows.add(
            _row(
              leading: Icon(Icons.warning_amber_outlined, size: 16, color: colors.warning),
              title: w,
              onTap: () => c.status == 'D' ? null : ws.goTo(Location(c.path, 0)),
            ),
          );
        }
      }
      if (r.objects.isNotEmpty) {
        heading('Objects (${r.objects.length})');
        for (final o in r.objects) {
          rows.add(
            _row(
              key: Key('changes.object.${o.object.key.qualified}'),
              indent: 1,
              leading: Icon(iconOf(o.object.kind), size: 15, color: colors.forSpace(o.object.key.space)),
              title: '${o.change}  ${o.object.signature}',
              subtitle: position(Location(o.object.primary.nameSpan.file, o.object.primary.nameSpan.start)),
              onTap: () => ws.goToSpan(o.object.primary.nameSpan),
              trailing: TextButton(onPressed: () => ws.findReferences(o.object), child: Text('${o.uses} uses')),
            ),
          );
        }
      }
      if (r.newProblems.isNotEmpty) {
        heading('New problems (${r.newProblems.length})');
        for (final x in r.newProblems) {
          final at = Location(x.span.file, x.span.start, x.span.end - x.span.start);
          rows.add(
            _row(
              indent: 1,
              leading: Icon(
                x.severity == Severity.error ? Icons.error_outline : Icons.warning_amber_outlined,
                size: 16,
                color: x.severity == Severity.error ? colors.error : colors.warning,
              ),
              title: x.message.split('\n').first,
              subtitle: position(at),
              onTap: () => ws.goTo(at),
            ),
          );
        }
      }
      heading('Files (${r.files.length})');
      for (final f in r.files) {
        rows.add(
          _row(
            indent: 1,
            leading: SizedBox(width: 18, child: Text(f.status, style: theme.textTheme.labelMedium)),
            title: f.from == null ? f.path : '${f.from} -> ${f.path}',
            onTap: () => f.status == 'D' || !f.path.endsWith('.sql') ? null : ws.goTo(Location(f.path, 0)),
          ),
        );
      }
    }
    return ListView(children: rows);
  }

  static String _defaultErScope(ProjectIndex index) {
    final modules = index.conventions.modules.where((m) => schemasWithTables(index).contains(m.name));
    if (modules.isNotEmpty) return 'module:${modules.first.name}';
    final schemas = schemasWithTables(index);
    return schemas.isEmpty ? 'schema:public' : 'schema:${schemas.first}';
  }

  Widget _errorCodes(Map<String, List<ErrorCodeUse>> codes) {
    final entries = codes.entries
        .where(
          (e) =>
              _codeFilter.isEmpty ||
              e.key.toLowerCase().contains(_codeFilter) ||
              e.value.any((u) => u.description.toLowerCase().contains(_codeFilter)),
        )
        .toList();
    final rows = <Widget>[];
    for (final e in entries) {
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
          child: Text('${e.key}  (${e.value.length})', style: Theme.of(context).textTheme.labelLarge),
        ),
      );
      for (final u in e.value) {
        final at = Location(u.span.file, u.span.start, u.span.end - u.span.start);
        rows.add(
          _row(
            indent: 1,
            leading: const Icon(Icons.subdirectory_arrow_right, size: 14),
            title: u.description.isEmpty ? '(no comment)' : u.description,
            subtitle: '${u.from?.qualified ?? ''}  ${position(at)}',
            onTap: () => ws.goTo(at),
            at: at,
          ),
        );
      }
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
          child: TextField(
            key: const Key('codes.filter'),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Code or text, e.g. U1445 or 404',
              border: OutlineInputBorder(),
            ),
            style: Theme.of(context).textTheme.bodySmall,
            onChanged: (v) => setState(() => _codeFilter = v.trim().toLowerCase()),
          ),
        ),
        Expanded(child: ListView(children: rows)),
      ],
    );
  }

  Widget _contract(ProjectIndex? index) {
    if (index == null) return const SizedBox.shrink();
    final c = index.conventions;
    final rows = <Widget>[];
    for (final m in c.modules) {
      final contract = c.contractOf(m, index);
      if (contract.isEmpty) continue;
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
          child: Text('${m.label}: ${m.name}_app (${contract.length})', style: Theme.of(context).textTheme.labelLarge),
        ),
      );
      for (final o in contract) {
        rows.add(
          _row(
            indent: 1,
            leading: Icon(iconOf(o.kind), size: 15, color: SyntaxColors.of(context).forSpace(o.key.space)),
            title: o.signature,
            subtitle: o.kind.label,
            onTap: () => ws.goToSpan(o.primary.nameSpan),
          ),
        );
      }
    }
    return ListView(children: rows);
  }
}
