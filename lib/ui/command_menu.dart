import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/commands.dart';

/// An entry of a context menu: a command from the registry (its title, icon and shortcut) with what it does here.
class MenuEntry {
  const MenuEntry(this.id, this.onSelected, {this.enabled = true, this.title});

  const MenuEntry.divider() : id = null, onSelected = null, enabled = false, title = null;

  /// The command id; null for a divider.
  final String? id;
  final FutureOr<void> Function()? onSelected;
  final bool enabled;

  /// Replaces the command's title (e.g. the title of a quick fix).
  final String? title;
}

/// Shows a context menu at [global] (3.0 spec 001). Every item has the key `menu.<id>`; disabled items stay
/// visible with their shortcut, so the menu also teaches the keys.
Future<void> showCommandMenu(BuildContext context, Offset global, List<MenuEntry> entries) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final local = overlay.globalToLocal(global);
  final theme = Theme.of(context);
  final items = <PopupMenuEntry<MenuEntry>>[];
  for (final e in _trimDividers(entries)) {
    if (e.id == null) {
      items.add(const PopupMenuDivider(height: 8));
      continue;
    }
    final c = command(e.id!);
    items.add(
      PopupMenuItem<MenuEntry>(
        key: Key('menu.${c.id}'),
        value: e,
        enabled: e.enabled,
        height: 32,
        child: Row(
          children: [
            SizedBox(width: 22, child: c.icon == null ? null : Icon(c.icon, size: 16)),
            const SizedBox(width: 6),
            Expanded(child: Text(e.title ?? c.title, style: theme.textTheme.bodyMedium)),
            if (c.shortcut != null) ...[
              const SizedBox(width: 24),
              Text(c.shortcut!, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
  if (items.isEmpty) return;
  final chosen = await showMenu<MenuEntry>(
    context: context,
    position: RelativeRect.fromRect(local & const Size(1, 1), Offset.zero & overlay.size),
    items: items,
    constraints: const BoxConstraints(minWidth: 260, maxWidth: 420),
  );
  await chosen?.onSelected?.call();
}

List<MenuEntry> _trimDividers(List<MenuEntry> entries) {
  final out = <MenuEntry>[];
  for (final e in entries) {
    if (e.id == null && (out.isEmpty || out.last.id == null)) continue;
    out.add(e);
  }
  while (out.isNotEmpty && out.last.id == null) {
    out.removeLast();
  }
  return out;
}

Future<void> copyToClipboard(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Copied: $text', maxLines: 2), duration: const Duration(seconds: 2)));
  }
}
