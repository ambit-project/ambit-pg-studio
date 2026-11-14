import 'package:flutter/material.dart';

/// A node of a lazily flattened tree (folders with hundreds of files stay fast).
class TreeItem {
  TreeItem({
    required this.id,
    required this.label,
    this.icon,
    this.iconColor,
    this.children = const [],
    this.onTap,
    this.onContextMenu,
    this.trailing,
    this.selected = false,
    this.tooltip,
  });

  final String id;
  final String label;
  final IconData? icon;
  final Color? iconColor;
  final List<TreeItem> children;
  final VoidCallback? onTap;

  /// Right click at a global position (3.0 spec 001).
  final ValueChanged<Offset>? onContextMenu;
  final Widget? trailing;
  final bool selected;
  final String? tooltip;

  bool get isGroup => children.isNotEmpty;
}

class TreeList extends StatefulWidget {
  const TreeList({super.key, required this.roots, this.initiallyExpanded = const {}, this.expandAll = false});

  final List<TreeItem> roots;
  final Set<String> initiallyExpanded;

  /// Expand every group (used while filtering).
  final bool expandAll;

  @override
  State<TreeList> createState() => _TreeListState();
}

class _TreeListState extends State<TreeList> {
  late final Set<String> _expanded = {...widget.initiallyExpanded};

  List<(TreeItem, int)> _flatten() {
    final out = <(TreeItem, int)>[];
    void visit(TreeItem item, int depth) {
      out.add((item, depth));
      if (item.isGroup && (widget.expandAll || _expanded.contains(item.id))) {
        for (final c in item.children) {
          visit(c, depth + 1);
        }
      }
    }

    for (final r in widget.roots) {
      visit(r, 0);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _flatten();
    final theme = Theme.of(context);
    return ListView.builder(
      itemCount: rows.length,
      itemExtent: 26,
      itemBuilder: (context, i) {
        final (item, depth) = rows[i];
        final expanded = widget.expandAll || _expanded.contains(item.id);
        final row = InkWell(
          key: ValueKey('tree:${item.id}'),
          onTap: () {
            if (item.isGroup) {
              setState(() => expanded ? _expanded.remove(item.id) : _expanded.add(item.id));
            }
            item.onTap?.call();
          },
          onSecondaryTapUp: item.onContextMenu == null ? null : (d) => item.onContextMenu!(d.globalPosition),
          child: Container(
            color: item.selected ? theme.colorScheme.primary.withValues(alpha: 0.14) : null,
            padding: EdgeInsets.only(left: 6.0 + depth * 14, right: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: item.isGroup
                      ? Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 16)
                      : const SizedBox.shrink(),
                ),
                if (item.icon != null) ...[
                  Icon(item.icon, size: 15, color: item.iconColor ?? theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    item.label,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                ?item.trailing,
              ],
            ),
          ),
        );
        return item.tooltip == null
            ? row
            : Tooltip(message: item.tooltip, waitDuration: const Duration(milliseconds: 600), child: row);
      },
    );
  }
}
