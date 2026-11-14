import 'package:flutter/material.dart';
import 'package:pg_core/pg_core.dart';

import 'theme.dart';

/// Ctrl+N: a new procedure, function or view in a module, or a dated changeset, from a template that passes the
/// module rules (2.0 spec 004). Returns the file to create, or null.
Future<NewFile?> showNewFileDialog(BuildContext context, ProjectIndex index, String today, {String? module}) {
  return showDialog<NewFile>(
    context: context,
    builder: (context) => _NewFileDialog(index: index, today: today, module: module),
  );
}

class _NewFileDialog extends StatefulWidget {
  const _NewFileDialog({required this.index, required this.today, this.module});

  final ProjectIndex index;
  final String today;
  final String? module;

  @override
  State<_NewFileDialog> createState() => _NewFileDialogState();
}

class _NewFileDialogState extends State<_NewFileDialog> {
  NewKind kind = NewKind.procedure;
  late String module = widget.index.conventions.modules.any((m) => m.name == widget.module)
      ? widget.module!
      : widget.index.conventions.modules.first.name;
  bool internal = false;
  String name = '';

  ({NewFile? file, String? error}) get result => name.isEmpty
      ? (file: null, error: null)
      : newFromTemplate(widget.index, kind: kind, module: module, name: name, internal: internal, today: widget.today);

  static String label(NewKind k) => switch (k) {
    NewKind.procedure => 'Procedure',
    NewKind.function => 'Function (read)',
    NewKind.view => 'View',
    NewKind.ddlChangeset => 'Dated changeset (DDL)',
    NewKind.dataChangeset => 'Dated changeset (data)',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = result;
    final isObject = kind == NewKind.procedure || kind == NewKind.function || kind == NewKind.view;
    return AlertDialog(
      title: const Text('New'),
      content: SizedBox(
        width: 760,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<NewKind>(
                  key: const Key('new.kind'),
                  value: kind,
                  items: [for (final k in NewKind.values) DropdownMenuItem(value: k, child: Text(label(k)))],
                  onChanged: (v) => setState(() => kind = v!),
                ),
                DropdownButton<String>(
                  key: const Key('new.module'),
                  value: module,
                  items: [
                    for (final m in widget.index.conventions.modules)
                      DropdownMenuItem(value: m.name, child: Text(m.label)),
                  ],
                  onChanged: (v) => setState(() => module = v!),
                ),
                if (isObject)
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(value: false, label: Text('${module}_app')),
                      ButtonSegment(value: true, label: Text('${module}_internal')),
                    ],
                    selected: {internal},
                    onSelectionChanged: (v) => setState(() => internal = v.first),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('new.name'),
              autofocus: true,
              decoration: InputDecoration(
                labelText: isObject ? 'Name (e.g. order_cancel)' : 'What it does (e.g. add_order_notes)',
                border: const OutlineInputBorder(),
                errorText: r.error,
              ),
              onChanged: (v) => setState(() => name = v.trim()),
              onSubmitted: (_) {
                if (result.file != null) Navigator.pop(context, result.file);
              },
            ),
            if (r.file != null) ...[
              const SizedBox(height: 12),
              Text(r.file!.path, key: const Key('new.path'), style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              Container(
                constraints: const BoxConstraints(maxHeight: 300),
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                color: SyntaxColors.of(context).background,
                child: SingleChildScrollView(
                  child: Text(
                    r.file!.content,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: editorFont,
                      fontFamilyFallback: editorFontFallback,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('new.create'),
          onPressed: r.file == null ? null : () => Navigator.pop(context, r.file),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
