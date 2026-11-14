import 'package:flutter/material.dart';
import 'package:pg_core/pg_core.dart';

import 'theme.dart';

/// Asks for the new name.
Future<String?> askNewName(BuildContext context, String what, String old) {
  final controller = TextEditingController(text: old)
    ..selection = TextSelection(baseOffset: 0, extentOffset: old.length);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Rename $what'),
      content: SizedBox(
        width: 420,
        child: TextField(
          key: const Key('rename.name'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'New name', border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('rename.next'),
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('Preview'),
        ),
      ],
    ),
  );
}

/// The plan before anything is written: every changed line, renamed and new files, warnings. True = apply.
Future<bool> previewRename(BuildContext context, ProjectIndex index, RenamePlan plan) async {
  final theme = Theme.of(context);
  final colors = SyntaxColors.of(context);
  final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: editorFont, fontFamilyFallback: editorFontFallback);
  final rows = <Widget>[];
  void heading(String text) => rows.add(
    Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Text(text, style: theme.textTheme.titleSmall),
    ),
  );

  // Warnings first: what the rename does not change matters most.
  if (plan.warnings.isNotEmpty) {
    heading('Warnings (${plan.warnings.length})');
    for (final w in plan.warnings) {
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_outlined, size: 16, color: colors.warning),
            const SizedBox(width: 6),
            Expanded(child: Text(w, style: theme.textTheme.bodySmall)),
          ],
        ),
      );
    }
  }
  if (plan.error != null) {
    rows.add(
      Text(
        plan.error!,
        key: const Key('rename.error'),
        style: TextStyle(color: colors.error),
      ),
    );
  } else {
    heading('Changes in ${plan.edits.length} files (${plan.editCount} places)');
    for (final e in plan.edits.entries) {
      final file = index.files[e.key]!;
      rows.add(Text(e.key, style: theme.textTheme.labelMedium));
      final byLine = <int, List<TextEdit>>{};
      for (final x in e.value) {
        (byLine[file.lineColumn(x.start).$1] ??= []).add(x);
      }
      for (final l in byLine.keys.toList()..sort()) {
        final start = file.lineStarts[l];
        final end = l + 1 < file.lineStarts.length ? file.lineStarts[l + 1] - 1 : file.text.length;
        final before = file.text.substring(start, end);
        var after = before;
        for (final x in [...byLine[l]!]..sort((a, b) => b.start.compareTo(a.start))) {
          after = after.replaceRange(x.start - start, x.end - start, x.replacement);
        }
        rows.add(Text('${l + 1}  - ${before.trim()}', style: mono?.copyWith(color: colors.error)));
        rows.add(Text('${l + 1}  + ${after.trim()}', style: mono?.copyWith(color: colors.string)));
      }
    }
    if (plan.renames.isNotEmpty) {
      heading('Renamed files');
      for (final r in plan.renames.entries) {
        rows.add(Text('${r.key}\n  -> ${r.value}', style: mono));
      }
    }
    if (plan.newFiles.isNotEmpty) {
      heading('New changeset (renames it in the database)');
      for (final n in plan.newFiles.entries) {
        rows.add(Text(n.key, style: theme.textTheme.labelMedium));
        rows.add(Text(n.value.trimRight(), style: mono));
      }
    }
    if (plan.changelogLines.isNotEmpty) {
      heading('CHANGELOG.md');
      for (final l in plan.changelogLines) {
        rows.add(Text(l, style: mono));
      }
    }
  }
  final apply = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('rename.preview'),
      title: Text(plan.title),
      content: SizedBox(
        width: 900,
        height: 520,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        if (plan.error == null)
          FilledButton(
            key: const Key('rename.apply'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apply'),
          ),
      ],
    ),
  );
  return apply ?? false;
}
