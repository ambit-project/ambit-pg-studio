import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pg_core/pg_core.dart';

import '../app/workspace.dart';
import 'theme.dart';

const _nodeHeight = 26.0;
const _gap = 6.0;

Color _edgeColor(Set<RefKind> kinds, SyntaxColors c) {
  if (kinds.contains(RefKind.write)) return c.error;
  if (kinds.contains(RefKind.call) || kinds.contains(RefKind.trigger)) return c.routine;
  if (kinds.contains(RefKind.read)) return c.relation;
  if (kinds.contains(RefKind.type)) return c.type;
  return c.gutter;
}

/// The object in the middle, what uses it on the left and what it uses on the right (spec 007).
class ObjectGraphView extends StatelessWidget {
  const ObjectGraphView({super.key, required this.workspace, required this.graph});

  final Workspace workspace;
  final ObjectGraph graph;

  @override
  Widget build(BuildContext context) {
    final colors = SyntaxColors.of(context);
    final rows = math.max(1, math.max(graph.users.length, graph.uses.length));
    final height = rows * (_nodeHeight + _gap) + 40;
    return LayoutBuilder(
      builder: (context, box) {
        final width = math.max(box.maxWidth, 900.0);
        final column = width * 0.30;
        final centerX = (width - column) / 2;
        final centerY = height / 2 - _nodeHeight / 2;
        double rowY(int i, int count) => (height - count * (_nodeHeight + _gap)) / 2 + i * (_nodeHeight + _gap);
        final edges = <(Offset, Offset, Color, bool)>[];
        for (var i = 0; i < graph.users.length; i++) {
          final n = graph.users[i];
          edges.add((
            Offset(column, rowY(i, graph.users.length) + _nodeHeight / 2),
            Offset(centerX, centerY + _nodeHeight / 2),
            _edgeColor(n.kinds, colors),
            n.writes,
          ));
        }
        for (var i = 0; i < graph.uses.length; i++) {
          final n = graph.uses[i];
          edges.add((
            Offset(centerX + column, centerY + _nodeHeight / 2),
            Offset(width - column, rowY(i, graph.uses.length) + _nodeHeight / 2),
            _edgeColor(n.kinds, colors),
            n.writes,
          ));
        }
        return SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              height: height,
              child: Stack(
                children: [
                  Positioned.fill(child: CustomPaint(painter: _EdgePainter(edges))),
                  Positioned(
                    left: 8,
                    top: 4,
                    child: Text('used by (${graph.users.length})', style: Theme.of(context).textTheme.labelSmall),
                  ),
                  Positioned(
                    right: 8,
                    top: 4,
                    child: Text('uses (${graph.uses.length})', style: Theme.of(context).textTheme.labelSmall),
                  ),
                  for (var i = 0; i < graph.users.length; i++)
                    Positioned(
                      left: 0,
                      top: rowY(i, graph.users.length),
                      width: column,
                      height: _nodeHeight,
                      child: _node(context, graph.users[i], 'graph.user.$i'),
                    ),
                  Positioned(
                    left: centerX,
                    top: centerY,
                    width: column,
                    height: _nodeHeight,
                    child: _Chip(
                      key: const Key('graph.center'),
                      icon: iconOf(graph.center.kind),
                      color: colors.forSpace(graph.center.key.space),
                      label: graph.center.key.qualified,
                      detail: graph.center.kind.label,
                      strong: true,
                      onTap: () => workspace.goToSpan(graph.center.primary.nameSpan),
                    ),
                  ),
                  for (var i = 0; i < graph.uses.length; i++)
                    Positioned(
                      left: width - column,
                      top: rowY(i, graph.uses.length),
                      width: column,
                      height: _nodeHeight,
                      child: _node(context, graph.uses[i], 'graph.use.$i'),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _node(BuildContext context, GraphNode n, String key) {
    final colors = SyntaxColors.of(context);
    final object = n.object;
    return _Chip(
      key: Key(key),
      icon: object == null ? Icons.description_outlined : iconOf(object.kind),
      color: object == null ? colors.gutter : colors.forSpace(object.key.space),
      label: n.label,
      detail: n.kinds.map((k) => k.label).join(', '),
      tooltip: object == null ? n.file : '${object.signature}\nclick: definition · right-click: center the graph here',
      onTap: () =>
          object == null ? workspace.goToSpan(n.places.first.span) : workspace.goToSpan(object.primary.nameSpan),
      onSecondaryTap: object == null ? null : () => workspace.showGraph(object),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.detail,
    required this.onTap,
    this.onSecondaryTap,
    this.tooltip,
    this.strong = false,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String detail;
  final VoidCallback onTap;
  final VoidCallback? onSecondaryTap;
  final String? tooltip;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chip = Material(
      color: strong ? color.withValues(alpha: 0.22) : theme.colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(5),
        side: BorderSide(color: color.withValues(alpha: strong ? 0.9 : 0.5)),
      ),
      child: InkWell(
        onTap: onTap,
        onSecondaryTap: onSecondaryTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(fontWeight: strong ? FontWeight.w700 : null),
                ),
              ),
              const SizedBox(width: 6),
              Text(detail, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
    return tooltip == null
        ? chip
        : Tooltip(message: tooltip, waitDuration: const Duration(milliseconds: 500), child: chip);
  }
}

class _EdgePainter extends CustomPainter {
  _EdgePainter(this.edges);

  final List<(Offset from, Offset to, Color color, bool thick)> edges;

  @override
  void paint(Canvas canvas, Size size) {
    for (final (a, b, color, thick) in edges) {
      final paint = Paint()
        ..color = color.withValues(alpha: 0.75)
        ..style = PaintingStyle.stroke
        ..strokeWidth = thick ? 2.2 : 1.3;
      final mid = (a.dx + b.dx) / 2;
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..cubicTo(mid, a.dy, mid, b.dy, b.dx, b.dy);
      canvas.drawPath(path, paint);
      _arrow(canvas, b, paint);
    }
  }

  static void _arrow(Canvas canvas, Offset tip, Paint paint) {
    final p = Path()
      ..moveTo(tip.dx - 7, tip.dy - 4)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(tip.dx - 7, tip.dy + 4);
    canvas.drawPath(p, paint);
  }

  @override
  bool shouldRepaint(_EdgePainter old) => old.edges != edges;
}

/// Modules in number order with arcs to the modules they use; arcs that break the rules are red (spec 007).
class ModuleGraphView extends StatelessWidget {
  const ModuleGraphView({super.key, required this.workspace, required this.graph});

  final Workspace workspace;
  final ModuleGraph graph;

  static const _row = 28.0;
  static const _labelWidth = 150.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SyntaxColors.of(context);
    final index = {for (var i = 0; i < graph.modules.length; i++) graph.modules[i].name: i};
    final height = graph.modules.length * _row + 24;
    final maxSpan = graph.edges.fold<int>(1, (m, e) => math.max(m, (index[e.from.name]! - index[e.to.name]!).abs()));
    final diagramWidth = _labelWidth + 30 + maxSpan * _row * 0.55 + 20;
    final violations = graph.edges.fold<int>(0, (n, e) => n + e.violations);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          child: SizedBox(
            width: diagramWidth,
            height: height,
            child: CustomPaint(
              painter: _ArcPainter(
                graph,
                index,
                colors,
                theme.textTheme.bodySmall!.copyWith(color: theme.colorScheme.onSurface),
              ),
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                child: Text(
                  '${graph.modules.length} modules, ${graph.edges.length} dependencies, $violations uses against the rules',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              for (final e in graph.edges)
                InkWell(
                  key: Key('graph.module.${e.from.name}.${e.to.name}'),
                  onTap: () => workspace.goToSpan(e.example),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    child: Row(
                      children: [
                        Icon(
                          e.violations > 0 ? Icons.error_outline : Icons.arrow_forward,
                          size: 14,
                          color: e.violations > 0 ? colors.error : colors.gutter,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${e.from.label} → ${e.to.label}   ${e.count} uses'
                            '${e.violations > 0 ? ', ${e.violations} against the rules' : ''}',
                            style: theme.textTheme.bodySmall?.copyWith(color: e.violations > 0 ? colors.error : null),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.graph, this.index, this.colors, this.text);

  final ModuleGraph graph;
  final Map<String, int> index;
  final SyntaxColors colors;
  final TextStyle text;

  @override
  void paint(Canvas canvas, Size size) {
    const row = ModuleGraphView._row;
    const x = ModuleGraphView._labelWidth + 16;
    double y(int i) => 12 + i * row + row / 2;
    for (var i = 0; i < graph.modules.length; i++) {
      final tp = TextPainter(
        text: TextSpan(text: graph.modules[i].label, style: text),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: ModuleGraphView._labelWidth);
      tp.paint(canvas, Offset(ModuleGraphView._labelWidth - tp.width, y(i) - tp.height / 2));
      canvas.drawCircle(Offset(x - 6, y(i)), 3, Paint()..color = colors.gutter);
    }
    for (final e in graph.edges) {
      final a = y(index[e.from.name]!);
      final b = y(index[e.to.name]!);
      final bend = (a - b).abs() * 0.55;
      final bad = e.violations > 0;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..color = (bad ? colors.error : colors.relation).withValues(alpha: bad ? 0.95 : 0.55)
        ..strokeWidth = math.min(1 + math.log(e.count + 1), 5);
      final path = Path()
        ..moveTo(x, a)
        ..cubicTo(x + bend, a, x + bend, b, x, b);
      canvas.drawPath(path, paint);
      final head = Path()
        ..moveTo(x + 7, b - 4)
        ..lineTo(x, b)
        ..lineTo(x + 7, b + 4);
      canvas.drawPath(head, paint);
    }
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.graph != graph;
}
