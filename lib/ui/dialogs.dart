import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/workspace.dart';

/// An item of a quick pick list.
class PickItem<T> {
  const PickItem(this.value, this.label, {this.detail, this.icon, this.iconColor, this.trailing, this.enabled = true});

  final T value;
  final String label;
  final String? detail;
  final IconData? icon;
  final Color? iconColor;

  /// Shown on the right (a shortcut in the command palette).
  final String? trailing;

  /// A disabled item is listed (with why in [detail]) but cannot be picked.
  final bool enabled;
}

/// Ctrl+P / Ctrl+T: type to filter, arrows to move, Enter to open.
Future<T?> showQuickPick<T>(
  BuildContext context, {
  required String hint,
  required List<PickItem<T>> Function(String query) search,
}) {
  return showDialog<T>(
    context: context,
    builder: (context) => _QuickPick<T>(hint: hint, search: search),
  );
}

class _QuickPick<T> extends StatefulWidget {
  const _QuickPick({required this.hint, required this.search});

  final String hint;
  final List<PickItem<T>> Function(String query) search;

  @override
  State<_QuickPick<T>> createState() => _QuickPickState<T>();
}

class _QuickPickState<T> extends State<_QuickPick<T>> {
  String query = '';
  int selected = 0;
  late List<PickItem<T>> items = widget.search('');

  void _update(String q) => setState(() {
    query = q;
    items = widget.search(q);
    selected = 0;
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: const Alignment(0, -0.7),
      child: Material(
        elevation: 12,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 720,
          height: 460,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                  setState(() => selected = (selected + 1).clamp(0, items.isEmpty ? 0 : items.length - 1)),
              const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                  setState(() => selected = (selected - 1).clamp(0, items.isEmpty ? 0 : items.length - 1)),
            },
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: TextField(
                    key: const Key('quickpick.query'),
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: widget.hint,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: _update,
                    onSubmitted: (_) {
                      if (items.isNotEmpty && items[selected].enabled) Navigator.of(context).pop(items[selected].value);
                    },
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: items.length,
                    itemExtent: 30,
                    itemBuilder: (context, i) {
                      final item = items[i];
                      return InkWell(
                        key: Key('quickpick.item.$i'),
                        onTap: item.enabled ? () => Navigator.of(context).pop(item.value) : null,
                        child: Container(
                          color: i == selected ? theme.colorScheme.primary.withValues(alpha: 0.14) : null,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              if (item.icon != null) ...[
                                Icon(item.icon, size: 16, color: item.iconColor),
                                const SizedBox(width: 8),
                              ],
                              ConstrainedBox(
                                // The label keeps its width; the detail takes the rest, so the trailing column lines up.
                                constraints: const BoxConstraints(maxWidth: 380),
                                child: Text(
                                  item.label,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: item.enabled ? null : theme.disabledColor,
                                  ),
                                ),
                              ),
                              if (item.detail != null) ...[
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    item.detail!,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                              if (item.detail == null) const Spacer(),
                              if (item.trailing != null) ...[
                                const SizedBox(width: 12),
                                Text(
                                  item.trailing!,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Several definitions (overloads, CREATE and ALTERs): pick one.
Future<Location?> chooseLocation(BuildContext context, String title, List<(Location, String)> places) {
  return showQuickPick<Location>(
    context,
    hint: title,
    search: (q) => [
      for (final (place, label) in places)
        if (q.isEmpty || label.toLowerCase().contains(q.toLowerCase())) PickItem(place, label, detail: place.path),
    ],
  );
}

enum UnsavedChoice { save, discard, cancel }

Future<UnsavedChoice> askUnsaved(BuildContext context, List<String> files) async {
  final result = await showDialog<UnsavedChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Unsaved changes'),
      content: Text(
        files.length == 1
            ? 'Save the changes in ${files.single}?'
            : 'Save the changes in ${files.length} files?\n${files.join('\n')}',
      ),
      actions: [
        TextButton(
          key: const Key('unsaved.cancel'),
          onPressed: () => Navigator.pop(context, UnsavedChoice.cancel),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('unsaved.discard'),
          onPressed: () => Navigator.pop(context, UnsavedChoice.discard),
          child: const Text("Don't save"),
        ),
        FilledButton(
          key: const Key('unsaved.save'),
          onPressed: () => Navigator.pop(context, UnsavedChoice.save),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  return result ?? UnsavedChoice.cancel;
}

enum ConflictChoice { reload, keepMine }

/// The file changed on disk while the tab has unsaved edits: never overwrite silently (spec 006).
Future<ConflictChoice?> askDiskConflict(BuildContext context, String file) {
  return showDialog<ConflictChoice>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('File changed on disk'),
      content: Text('$file changed on disk and has unsaved changes here.'),
      actions: [
        TextButton(
          key: const Key('conflict.keep'),
          onPressed: () => Navigator.pop(context, ConflictChoice.keepMine),
          child: const Text('Keep my changes'),
        ),
        FilledButton(
          key: const Key('conflict.reload'),
          onPressed: () => Navigator.pop(context, ConflictChoice.reload),
          child: const Text('Reload from disk'),
        ),
      ],
    ),
  );
}

/// Closing the app while programs run in terminals (3.0 spec 003): true = quit and end them.
Future<bool> askRunningTerminals(BuildContext context, List<String> programs) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Programs are running'),
      content: Text(
        '${programs.length == 1 ? 'A program is' : 'Programs are'} running in the terminal: ${programs.join(', ')}.\n'
        'Quitting ends ${programs.length == 1 ? 'it' : 'them'}.',
      ),
      actions: [
        TextButton(
          key: const Key('running.cancel'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('running.quit'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Quit'),
        ),
      ],
    ),
  );
  return result ?? false;
}
