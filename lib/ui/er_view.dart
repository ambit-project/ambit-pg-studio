import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide ObjectKey;
import 'package:flutter/rendering.dart';
import 'package:pg_core/pg_core.dart';

import '../app/commands.dart';
import '../app/workspace.dart';
import 'theme.dart';

const _boxWidth = 260.0;
const _gapX = 110.0;
const _gapY = 24.0;
const _header = 28.0;
const _row = 19.0;

/// The ER model of a scope `schema:<s>` or `module:<m>` (a module that is gone falls back to the schema of that name).
ErModel erModelFor(ProjectIndex index, String scope) {
  final module = scope.startsWith('module:')
      ? index.conventions.modules.where((m) => m.name == scope.substring(7)).firstOrNull
      : null;
  return module != null ? erModel(index, module: module) : erModel(index, schema: scope.split(':').last);
}

/// The ER diagram of a schema or module: tables with PK/FK columns, foreign keys as arrows (2.0 spec 009).
class ErView extends StatefulWidget {
  const ErView({super.key, required this.workspace, required this.model, this.scope, this.title});

  final Workspace workspace;
  final ErModel model;

  /// The scope of the diagram; with it the diagram can open in a new window (3.1).
  final String? scope;

  /// Set when the diagram is the whole window (3.1): the title above it, no "new window" button, a click on a table
  /// does not open the editor.
  final String? title;

  bool get window => title != null;

  @override
  State<ErView> createState() => ErViewState();
}

class ErViewState extends State<ErView> {
  final _canvas = GlobalKey();

  /// Zoom and pan of the diagram; [resetView] brings back the default (3.1).
  final transform = TransformationController();

  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }

  void resetView() => transform.value = Matrix4.identity();

  double _height(ErTable t) => _header + (t.external ? 0 : math.max(1, t.columns.length) * _row) + 8;

  /// Positions of the boxes: one column per layer, stacked.
  Map<ObjectKey, Rect> layout() {
    final rects = <ObjectKey, Rect>{};
    final y = <int, double>{};
    for (final t in widget.model.tables) {
      final top = y[t.layer] ?? 16;
      final r = Rect.fromLTWH(16 + t.layer * (_boxWidth + _gapX), top, _boxWidth, _height(t));
      rects[t.object.key] = r;
      y[t.layer] = r.bottom + _gapY;
    }
    return rects;
  }

  /// Renders the diagram to PNG bytes (2x).
  Future<List<int>> png() async {
    final boundary = _canvas.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  Future<void> export() async {
    final name = '${widget.model.title.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}.png';
    final path = await widget.workspace.pickSavePath(name);
    if (path == null) return;
    await File(path).writeAsBytes(await png());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(key: const Key('er.exported'), content: Text('Saved $path')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SyntaxColors.of(context);
    final rects = layout();
    if (rects.isEmpty) return const Center(child: Text('No tables here.'));
    final size = Size(
      rects.values.map((r) => r.right).reduce(math.max) + 16,
      rects.values.map((r) => r.bottom).reduce(math.max) + 16,
    );
    final mono = theme.textTheme.bodySmall?.copyWith(
      fontFamily: editorFont,
      fontFamilyFallback: editorFontFallback,
      fontSize: 12,
    );
    final canvas = InteractiveViewer(
      transformationController: transform,
      constrained: false,
      minScale: 0.2,
      maxScale: 2.5,
      boundaryMargin: const EdgeInsets.all(200),
      child: RepaintBoundary(
        key: _canvas,
        child: Container(
          width: size.width,
          height: size.height,
          color: colors.background,
          child: Stack(
            children: [
              Positioned.fill(child: CustomPaint(painter: _FkPainter(widget.model.edges, rects, colors.relation))),
              for (final t in widget.model.tables)
                Positioned.fromRect(
                  rect: rects[t.object.key]!,
                  child: _TableBox(
                    key: Key('er.table.${t.object.key.qualified}'),
                    table: t,
                    mono: mono,
                    onTap: widget.window ? null : () => widget.workspace.goToSpan(t.object.primary.nameSpan),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final toolbar = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${widget.model.tables.where((t) => !t.external).length} tables, ${widget.model.edges.length} foreign keys',
          key: const Key('er.count'),
          style: theme.textTheme.labelSmall,
        ),
        const SizedBox(width: 8),
        _button('er.resetView', resetView),
        if (widget.scope != null && !widget.window)
          _button('er.newWindow', () => widget.workspace.openErWindow(widget.scope!)),
        const SizedBox(width: 4),
        FilledButton.tonalIcon(
          key: const Key('er.export'),
          onPressed: export,
          icon: const Icon(Icons.image_outlined, size: 16),
          label: const Text('Export PNG'),
        ),
      ],
    );
    final title = widget.title;
    if (title == null) {
      return Stack(
        children: [
          Positioned.fill(child: canvas),
          Positioned(right: 8, top: 4, child: toolbar),
        ],
      );
    }
    // A window of its own: the title and the buttons above the diagram, nothing covers a table.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: theme.colorScheme.surfaceContainer,
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  key: const Key('er.window.title'),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              toolbar,
            ],
          ),
        ),
        Expanded(child: canvas),
      ],
    );
  }

  /// An icon button of a registry command: its title and description as the tooltip.
  Widget _button(String id, VoidCallback onPressed) {
    final c = command(id);
    return IconButton(
      key: Key(id),
      tooltip: '${c.title}\n${c.description}',
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      onPressed: onPressed,
      icon: Icon(c.icon),
    );
  }
}

/// A window with only the ER diagram of a scope: `pg-studio <folder> --er=<scope>` (3.1). The index follows the
/// files on disk like in the main window.
class ErWindow extends StatelessWidget {
  const ErWindow({super.key, required this.workspace, required this.scope});

  final Workspace workspace;
  final String scope;

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: workspace.project, builder: _build);

  Widget _build(BuildContext context, Widget? _) {
    final project = workspace.project;
    final index = project.index;
    final what = scope.startsWith('module:') ? 'module ${scope.substring(7)}' : 'schema ${scope.split(':').last}';
    final title = 'ER diagram of $what - ${project.root ?? ''}';
    final Widget body;
    if (project.error != null) {
      body = Center(child: Text(project.error!));
    } else if (index == null) {
      body = Center(child: Text('Indexing ${project.root ?? ''}…'));
    } else {
      body = ErView(workspace: workspace, model: erModelFor(index, scope), scope: scope, title: title);
    }
    return Scaffold(body: body);
  }
}

class _TableBox extends StatelessWidget {
  const _TableBox({super.key, required this.table, required this.mono, required this.onTap});

  final ErTable table;
  final TextStyle? mono;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SyntaxColors.of(context);
    return Material(
      color: table.external ? theme.colorScheme.surfaceContainer : theme.colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: colors.relation.withValues(alpha: table.external ? 0.35 : 0.8)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: _header,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              color: colors.relation.withValues(alpha: table.external ? 0.08 : 0.22),
              alignment: Alignment.centerLeft,
              child: Text(
                table.object.key.qualified,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(fontStyle: table.external ? FontStyle.italic : null),
              ),
            ),
            for (final c in table.columns)
              SizedBox(
                height: _row,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 18,
                        child: c.primaryKey
                            ? Icon(Icons.key, size: 12, color: colors.routine)
                            : c.foreignKey
                            ? Icon(Icons.link, size: 12, color: colors.relation)
                            : null,
                      ),
                      Expanded(
                        child: Text(
                          c.name,
                          overflow: TextOverflow.ellipsis,
                          style: mono?.copyWith(fontWeight: c.primaryKey ? FontWeight.w700 : null),
                        ),
                      ),
                      Text(c.type, style: mono?.copyWith(color: colors.gutter)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FkPainter extends CustomPainter {
  _FkPainter(this.edges, this.rects, this.color);

  final List<ErEdge> edges;
  final Map<ObjectKey, Rect> rects;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final e in edges) {
      final from = rects[e.from];
      final to = rects[e.to];
      if (from == null || to == null) continue;
      if (e.from == e.to) {
        // A self reference: a loop on the right side.
        final r = from.topRight + const Offset(0, _header);
        canvas.drawPath(
          Path()
            ..moveTo(r.dx, r.dy)
            ..cubicTo(r.dx + 40, r.dy - 10, r.dx + 40, r.dy + 30, r.dx, r.dy + 20),
          paint,
        );
        continue;
      }
      final a = Offset(from.left, from.top + _header / 2);
      final b = Offset(to.right, to.top + _header / 2);
      final mid = (a.dx + b.dx) / 2;
      canvas.drawPath(
        Path()
          ..moveTo(a.dx, a.dy)
          ..cubicTo(mid, a.dy, mid, b.dy, b.dx, b.dy),
        paint,
      );
      canvas.drawPath(
        Path()
          ..moveTo(b.dx + 8, b.dy - 5)
          ..lineTo(b.dx, b.dy)
          ..lineTo(b.dx + 8, b.dy + 5),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_FkPainter old) => old.edges != edges || old.rects != rects;
}
