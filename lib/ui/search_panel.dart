import 'package:flutter/material.dart';
import 'package:pg_core/pg_core.dart';

import '../app/workspace.dart';
import 'rename_dialog.dart';
import 'theme.dart';

/// Ctrl+Shift+F: text or regex in every file of the project, replace with a preview (2.0 spec 007).
class SearchPanel extends StatefulWidget {
  const SearchPanel({super.key, required this.workspace});

  final Workspace workspace;

  @override
  State<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<SearchPanel> {
  late final query = TextEditingController(text: ws.searchQuery);
  final replacement = TextEditingController();
  late final paths = TextEditingController(text: ws.searchPaths);
  final focus = FocusNode();
  int _focusSeen = -1;

  Workspace get ws => widget.workspace;

  @override
  void dispose() {
    query.dispose();
    replacement.dispose();
    paths.dispose();
    focus.dispose();
    super.dispose();
  }

  Future<void> _replaceAll() async {
    final index = ws.index;
    if (index == null || ws.searchHits.isEmpty) return;
    final plan = ws.replaceAllPlan(replacement.text);
    if (!await previewRename(context, index, plan) || !mounted) return;
    final refused = await ws.applyRename(plan);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(refused ?? 'Replaced ${plan.editCount} matches in ${plan.edits.length} files')),
    );
    ws.runSearch();
  }

  Widget _toggle(String label, String tooltip, bool on, ValueChanged<bool> set) => Tooltip(
    message: tooltip,
    child: InkWell(
      key: Key('search.toggle.$label'),
      onTap: () {
        set(!on);
        ws.runSearch();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: on ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.25) : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label, style: Theme.of(context).textTheme.labelMedium),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (_focusSeen != ws.searchFocus) {
      _focusSeen = ws.searchFocus;
      if (query.text != ws.searchQuery) query.text = ws.searchQuery;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) focus.requestFocus();
      });
    }
    final theme = Theme.of(context);
    final colors = SyntaxColors.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: editorFont, fontFamilyFallback: editorFontFallback);
    final byFile = <String, List<SearchHit>>{};
    for (final h in ws.searchHits) {
      (byFile[h.path] ??= []).add(h);
    }
    final rows = <Widget>[];
    for (final e in byFile.entries) {
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
          child: Text('${e.key} (${e.value.length})', style: theme.textTheme.labelMedium),
        ),
      );
      for (final h in e.value) {
        final lineStart = ws.index?.files[h.path]?.lineStarts[h.line] ?? 0;
        final a = (h.start - lineStart).clamp(0, h.lineText.length);
        final b = (h.end - lineStart).clamp(a, h.lineText.length);
        rows.add(
          InkWell(
            key: Key('search.hit.${h.path}:${h.start}'),
            onTap: () => ws.goTo(Location(h.path, h.start, h.end - h.start)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 2, 8, 2),
              child: Text.rich(
                TextSpan(
                  style: mono,
                  children: [
                    TextSpan(
                      text: '${h.line + 1}  ',
                      style: TextStyle(color: colors.gutter),
                    ),
                    TextSpan(text: h.lineText.substring(0, a).trimLeft()),
                    TextSpan(
                      text: h.lineText.substring(a, b),
                      style: TextStyle(backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.35)),
                    ),
                    TextSpan(text: h.lineText.substring(b)),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
      }
    }
    InputDecoration deco(String hint) =>
        InputDecoration(isDense: true, hintText: hint, border: const OutlineInputBorder());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  key: const Key('search.query'),
                  controller: query,
                  focusNode: focus,
                  style: mono,
                  decoration: deco('Search in all files').copyWith(errorText: ws.searchError),
                  onChanged: (v) {
                    ws.searchQuery = v;
                    ws.runSearch();
                  },
                ),
              ),
              const SizedBox(width: 6),
              _toggle('Aa', 'Match case', ws.searchCase, (v) => ws.searchCase = v),
              _toggle('W', 'Whole word', ws.searchWord, (v) => ws.searchWord = v),
              _toggle('.*', 'Regular expression', ws.searchRegex, (v) => ws.searchRegex = v),
              const SizedBox(width: 6),
              Expanded(
                flex: 2,
                child: TextField(
                  key: const Key('search.paths'),
                  controller: paths,
                  style: mono,
                  decoration: deco('Files containing (e.g. modules/60-orders)'),
                  onChanged: (v) {
                    ws.searchPaths = v;
                    ws.runSearch();
                  },
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  key: const Key('search.replacement'),
                  controller: replacement,
                  style: mono,
                  decoration: deco(ws.searchRegex ? r'Replace with ($1, $2 ... are groups)' : 'Replace with'),
                ),
              ),
              const SizedBox(width: 6),
              FilledButton.tonal(
                key: const Key('search.replaceAll'),
                onPressed: ws.searchHits.isEmpty ? null : _replaceAll,
                child: const Text('Replace all…'),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: Text(
                  ws.searchQuery.isEmpty ? '' : '${ws.searchHits.length} matches in ${byFile.length} files',
                  key: const Key('search.count'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        Expanded(child: ListView(children: rows)),
      ],
    );
  }
}
