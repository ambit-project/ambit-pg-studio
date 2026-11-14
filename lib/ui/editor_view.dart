import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pg_core/pg_core.dart';
import 'package:re_editor/re_editor.dart';

import '../app/workspace.dart';
import 'theme.dart';

/// Width of the line number gutter; pointer positions are mapped to text with it (ADR 0003).
/// Width of the line numbers at the default font size; it grows with the font (2.0 spec 013).
const gutterWidth = 56.0;
const _padding = EdgeInsets.only(left: 8, top: 6, right: 8, bottom: 24);

/// The editor of one tab: highlighting from libpg_query tokens and the index, Ctrl+click, hover, Ctrl+S.
class EditorView extends StatefulWidget {
  const EditorView({
    super.key,
    required this.workspace,
    required this.tab,
    required this.onChoose,
    required this.onSave,
    this.onContextMenu,
  });

  final Workspace workspace;
  final EditorTab tab;

  /// Lets the user pick one of several places (overloads, CREATE and ALTERs).
  final Future<Location?> Function(String title, List<(Location, String)> places) onChoose;
  final Future<void> Function(EditorTab tab) onSave;

  /// Right click at a global position; the cursor is already moved there (3.0 spec 001).
  final ValueChanged<Offset>? onContextMenu;

  @override
  State<EditorView> createState() => EditorViewState();
}

class EditorViewState extends State<EditorView> {
  double get _fontSize => widget.workspace.settings.fontSize;
  double get _gutterFont => _fontSize * 12 / 13.5;
  double get _gutter => (gutterWidth * _fontSize / 13.5).clamp(gutterWidth, 200);

  CodeIndicatorValueNotifier? _lines;
  SourceSpan? _link;
  Timer? _hoverTimer;
  String? _hoverText;
  Offset _hoverAt = Offset.zero;
  bool _ctrl = false;
  late SyntaxColors _colors;

  EditorTab get tab => widget.tab;

  SignatureHelp? _signature;

  @override
  void initState() {
    super.initState();
    tab.lineSpans = _lineSpans;
    tab.controller.addListener(_cursorMoved);
    HardwareKeyboard.instance.addHandler(_key);
  }

  /// Signature help while the cursor is inside the arguments of a known routine (2.0 spec 002).
  void _cursorMoved() {
    final index = widget.workspace.index;
    if (index == null || !mounted) return;
    final sel = tab.controller.selection;
    SignatureHelp? help;
    if (sel.isCollapsed) {
      final text = tab.controller.text;
      help = complete(index, text, _offsetIn(text, sel.extentIndex, sel.extentOffset)).signature;
    }
    if (help?.signatures.length == _signature?.signatures.length &&
        help?.activeParameter == _signature?.activeParameter) {
      return;
    }
    setState(() => _signature = help);
  }

  /// Completion items for the cursor: from the controller (the tab's copy may lag one notification behind).
  Completion completionAt(CodeLineSelection selection) {
    final text = tab.controller.text;
    return complete(widget.workspace.index!, text, _offsetIn(text, selection.extentIndex, selection.extentOffset));
  }

  /// The offset of (line, column) in [text] - from the controller's current text, not the tab's copy, which is
  /// refreshed by a listener that may run after this one.
  static int _offsetIn(String text, int line, int column) {
    var at = 0;
    for (var l = 0; l < line; l++) {
      final next = text.indexOf('\n', at);
      if (next < 0) return text.length;
      at = next + 1;
    }
    return (at + column).clamp(0, text.length);
  }

  @override
  void didUpdateWidget(EditorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.tab, tab)) {
      oldWidget.tab.lineSpans = null;
      oldWidget.tab.controller.removeListener(_cursorMoved);
      tab.controller.addListener(_cursorMoved);
      tab.lineSpans = _lineSpans;
      _clearHover();
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    tab.controller.removeListener(_cursorMoved);
    _hoverTimer?.cancel();
    if (identical(tab.lineSpans, _lineSpans)) tab.lineSpans = null;
    super.dispose();
  }

  /// The completion list on screen (registered by it): Enter/Tab pick its current item. Handled here, before the
  /// editor turns Enter into a newline.
  ({ValueNotifier<CodeAutocompleteEditingValue> notifier, ValueChanged<CodeAutocompleteResult> onSelected})?
  completionList;

  bool _key(KeyEvent event) {
    final list = completionList;
    if (list != null &&
        event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.tab) &&
        list.notifier.value.prompts.isNotEmpty) {
      list.onSelected(list.notifier.value.autocomplete);
      return true;
    }
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (ctrl != _ctrl) {
      _ctrl = ctrl;
      if (!ctrl && _link != null) _setLink(null);
    }
    return false;
  }

  // --- spans -------------------------------------------------------------------------------------------------------

  TextSpan _lineSpans(EditorTab tab, int line, String text, TextStyle style) {
    if (text.isEmpty) return TextSpan(text: text, style: style);
    final start = line < tab.lineStarts.length ? tab.lineStarts[line] : 0;
    final end = start + text.length;
    final index = widget.workspace.index;
    final file = index?.files[tab.path];
    final fresh = file != null && file.contentHash == tab.textHash;

    final cuts = <int>{0, text.length};
    void cut(int s, int e) {
      if (e <= start || s >= end) return;
      cuts.add((s - start).clamp(0, text.length));
      cuts.add((e - start).clamp(0, text.length));
    }

    final tokens = tab.tokens;
    final first = _firstEndingAfter(tokens, start);
    for (var i = first; i < tokens.length && tokens[i].start < end; i++) {
      cut(tokens[i].start, tokens[i].end);
    }
    final refs = fresh ? index!.referencesInFile(tab.path) : const <ResolvedReference>[];
    final lineRefs = [
      for (final r in refs)
        if (r.span.end > start && r.span.start < end) r,
    ];
    for (final r in lineRefs) {
      cut(r.span.start, r.span.end);
    }
    final defs = fresh
        ? [
            for (final d in file.definitions)
              if (d.nameSpan.end > start && d.nameSpan.start < end) d,
          ]
        : const <Definition>[];
    for (final d in defs) {
      cut(d.nameSpan.start, d.nameSpan.end);
    }
    final problems = fresh
        ? index!.problemsIn(tab.path).where((p) => p.span.end >= start && p.span.start <= end).toList()
        : const <Problem>[];
    for (final p in problems) {
      cut(p.span.start, p.span.end == p.span.start ? p.span.start + 1 : p.span.end);
    }
    final link = _link;
    if (link != null && link.file == tab.path) cut(link.start, link.end);

    final sorted = cuts.toList()..sort();
    final children = <TextSpan>[];
    var t = first;
    for (var k = 0; k + 1 < sorted.length; k++) {
      final a = sorted[k];
      final b = sorted[k + 1];
      if (a >= b) continue;
      final at = start + a;
      while (t < tokens.length && tokens[t].end <= at) {
        t++;
      }
      var color = _colors.text;
      var italic = false;
      if (t < tokens.length && tokens[t].start <= at && at < tokens[t].end) {
        color = _colors.forHighlight(tokens[t].kind);
        italic = tokens[t].kind == HighlightKind.comment || tokens[t].kind == HighlightKind.liquibase;
      }
      var bold = false;
      for (final r in lineRefs) {
        if (r.span.start <= at && at < r.span.end && r.targets.isNotEmpty) {
          color = _colors.forSpace(r.targets.first.space);
        }
      }
      for (final d in defs) {
        if (d.nameSpan.start <= at && at < d.nameSpan.end) {
          color = _colors.forSpace(d.key.space);
          bold = true;
        }
      }
      Color? underline;
      var wavy = false;
      for (final p in problems) {
        final pe = p.span.end == p.span.start ? p.span.start + 1 : p.span.end;
        if (p.span.start <= at && at < pe && p.severity != Severity.info) {
          underline = p.severity == Severity.error ? _colors.error : _colors.warning;
          wavy = true;
        }
      }
      if (link != null && link.file == tab.path && link.start <= at && at < link.end) {
        color = _colors.link;
        underline = _colors.link;
        wavy = false;
      }
      children.add(
        TextSpan(
          text: text.substring(a, b),
          style: style.copyWith(
            color: color,
            fontWeight: bold ? FontWeight.w700 : null,
            fontStyle: italic ? FontStyle.italic : null,
            decoration: underline == null ? null : TextDecoration.underline,
            decorationColor: underline,
            decorationStyle: wavy ? TextDecorationStyle.wavy : TextDecorationStyle.solid,
          ),
        ),
      );
    }
    return TextSpan(children: children, style: style);
  }

  static int _firstEndingAfter(List<HighlightToken> tokens, int offset) {
    var low = 0;
    var high = tokens.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (tokens[mid].end <= offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  // --- pointer -> text ---------------------------------------------------------------------------------------------

  /// The text offset under a pointer position local to the editor widget, or null outside the text.
  int? offsetAt(Offset local) {
    final lines = _lines?.value?.paragraphs;
    if (lines == null || lines.isEmpty) return null;
    // The notifier's line offsets are viewport coordinates (re_editor subtracts the scroll position).
    final x = local.dx - _gutter;
    final y = local.dy;
    if (x < 0) return null;
    for (final p in lines) {
      if (y >= p.top && y < p.bottom) {
        final pos = p.paragraph.getPosition(Offset(x - p.offset.dx, y - p.offset.dy));
        final lineText = p.index < tab.controller.codeLines.length ? tab.controller.codeLines[p.index].text : '';
        if (pos.offset >= lineText.length && x - p.offset.dx > p.paragraph.width) return null;
        return tab.offsetOf(p.index, pos.offset);
      }
    }
    return null;
  }

  /// The local position (inside the editor widget) of the middle of the character at [offset], when visible.
  Offset? pointOf(int offset) {
    final lines = _lines?.value?.paragraphs;
    if (lines == null) return null;
    final (line, column) = tab.lineColumn(offset);
    for (final p in lines) {
      if (p.index != line) continue;
      final at = p.paragraph.getOffset(TextPosition(offset: column));
      if (at == null) return null;
      return Offset(_gutter + p.offset.dx + at.dx + 3, p.offset.dy + at.dy + p.preferredLineHeight / 2);
    }
    return null;
  }

  void _setLink(SourceSpan? span) {
    if (span == _link) return;
    setState(() => _link = span);
    tab.controller.forceRepaint();
  }

  void _clearHover() {
    _hoverTimer?.cancel();
    if (_hoverText != null) setState(() => _hoverText = null);
  }

  void _hover(PointerHoverEvent e) {
    final offset = offsetAt(e.localPosition);
    _ctrl = HardwareKeyboard.instance.isControlPressed;
    _setLink(offset != null && _ctrl ? widget.workspace.linkAt(tab.path, offset) : null);
    _clearHover();
    if (offset == null) return;
    _hoverTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      final text = widget.workspace.hoverAt(tab.path, offset);
      if (text != null) {
        setState(() {
          _hoverText = text;
          _hoverAt = e.localPosition;
        });
      }
    });
  }

  Future<void> _pointerDown(PointerDownEvent e) async {
    _clearHover();
    if (e.buttons == kSecondaryButton) {
      _contextMenu(e);
      return;
    }
    if (!HardwareKeyboard.instance.isControlPressed || e.buttons != kPrimaryButton) return;
    final offset = offsetAt(e.localPosition);
    if (offset != null) await goToDefinition(offset);
  }

  /// Right click (3.0 spec 001): the cursor moves to the pointer unless it is inside the selection, then the menu.
  void _contextMenu(PointerDownEvent e) {
    final offset = offsetAt(e.localPosition);
    if (offset != null) {
      final sel = tab.controller.selection;
      final start = tab.offsetOf(sel.startIndex, sel.startOffset);
      final end = tab.offsetOf(sel.endIndex, sel.endOffset);
      if (sel.isCollapsed || offset < start || offset > end) tab.reveal(offset, offset);
    }
    final global = e.position;
    // After this pointer event: the editor would otherwise handle the down on the open menu's barrier.
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onContextMenu?.call(global));
    WidgetsBinding.instance.scheduleFrame();
  }

  /// Ctrl+click / F12: a single place opens, several are offered; on a definition name: its references.
  Future<void> goToDefinition(int offset) async {
    final ws = widget.workspace;
    final onDefinitionName =
        ws.index?.referenceAt(tab.path, offset) == null && ws.index?.definitionAt(tab.path, offset) != null;
    final places = ws.definitionsAt(tab.path, offset);
    if (places.isEmpty) return;
    if (onDefinitionName && places.length == 1) {
      ws.findReferencesAt(tab.path, offset);
      return;
    }
    if (places.length == 1) {
      await ws.goTo(places.single.$1);
      return;
    }
    final chosen = await widget.onChoose('Go to definition', places);
    if (chosen != null) await ws.goTo(chosen);
  }

  @override
  Widget build(BuildContext context) {
    _colors = SyntaxColors.of(context);
    final theme = Theme.of(context);
    return Stack(
      children: [
        MouseRegion(
          onHover: _hover,
          onExit: (_) {
            _clearHover();
            _setLink(null);
          },
          cursor: _link != null ? SystemMouseCursors.click : MouseCursor.defer,
          child: Listener(
            onPointerDown: _pointerDown,
            child: CodeAutocomplete(
              promptsBuilder: _SqlPrompts(this),
              viewBuilder: (context, notifier, onSelected) =>
                  _CompletionList(view: this, notifier: notifier, onSelected: onSelected),
              child: CodeEditor(
                key: ValueKey('editor:${tab.path}'),
                controller: tab.controller,
                scrollController: tab.scroll,
                wordWrap: false,
                padding: _padding,
                style: CodeEditorStyle(
                  fontSize: widget.workspace.settings.fontSize,
                  fontHeight: 1.45,
                  fontFamily: editorFont,
                  fontFamilyFallback: editorFontFallback,
                  textColor: _colors.text,
                  backgroundColor: _colors.background,
                  cursorColor: theme.colorScheme.primary,
                  selectionColor: theme.colorScheme.primary.withValues(alpha: 0.28),
                  cursorLineColor: theme.colorScheme.onSurface.withValues(alpha: 0.05),
                ),
                indicatorBuilder: (context, editingController, chunkController, notifier) {
                  _lines = notifier;
                  return SizedBox(
                    width: _gutter,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: DefaultCodeLineNumber(
                        controller: editingController,
                        notifier: notifier,
                        textStyle: TextStyle(color: _colors.gutter, fontSize: _gutterFont, fontFamily: editorFont),
                        focusedTextStyle: TextStyle(color: _colors.text, fontSize: _gutterFont, fontFamily: editorFont),
                      ),
                    ),
                  );
                },
                shortcutsActivatorsBuilder: const EditorShortcuts(),
                shortcutOverrideActions: {
                  CodeShortcutSaveIntent: CallbackAction<CodeShortcutSaveIntent>(
                    onInvoke: (_) {
                      unawaited(widget.onSave(tab));
                      return null;
                    },
                  ),
                },
              ),
            ),
          ),
        ),
        if (_signature != null)
          // Placed above the cursor line when it is laid out; at the top of the editor until then.
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, box) {
                final at = pointOf(tab.cursorOffset) ?? Offset(_gutter + 8, 60);
                // Kept inside the editor: at most 720 px wide, moved left when the cursor is near the right edge.
                final width = box.maxWidth < 760 ? box.maxWidth - 16 : 720.0;
                final left = (at.dx - 8).clamp(0.0, (box.maxWidth - width - 8).clamp(0.0, double.infinity));
                final top = at.dy - 52 < 0 ? at.dy + 22 : at.dy - 52;
                return Stack(
                  children: [
                    Positioned(
                      left: left,
                      top: top,
                      child: IgnorePointer(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: width),
                          child: _SignatureCard(help: _signature!),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        if (_hoverText != null)
          Positioned(
            left: (_hoverAt.dx + 12).clamp(0, double.infinity),
            top: _hoverAt.dy + 18,
            child: IgnorePointer(child: _HoverCard(text: _hoverText!)),
          ),
      ],
    );
  }
}

class _HoverCard extends StatelessWidget {
  const _HoverCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: const Key('editor.hover'),
      elevation: 6,
      borderRadius: BorderRadius.circular(6),
      color: theme.colorScheme.surfaceContainerHighest,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: editorFont,
              fontFamilyFallback: editorFontFallback,
              height: 1.4,
            ),
          ),
        ),
      ),
    );
  }
}

/// re_editor's shortcuts with Linux IDE word moves (Ctrl+Left/Right), so Alt+Left/Right stay free for back/forward.
class EditorShortcuts extends CodeShortcutsActivatorsBuilder {
  const EditorShortcuts();

  static const _default = DefaultCodeShortcutsActivatorsBuilder();

  @override
  List<ShortcutActivator>? build(CodeShortcutType type) => switch (type) {
    CodeShortcutType.cursorMoveWordBoundaryBackward => const [
      SingleActivator(LogicalKeyboardKey.arrowLeft, control: true),
    ],
    CodeShortcutType.cursorMoveWordBoundaryForward => const [
      SingleActivator(LogicalKeyboardKey.arrowRight, control: true),
    ],
    CodeShortcutType.selectionExtendWordBoundaryBackward => const [
      SingleActivator(LogicalKeyboardKey.arrowLeft, control: true, shift: true),
    ],
    CodeShortcutType.selectionExtendWordBoundaryForward => const [
      SingleActivator(LogicalKeyboardKey.arrowRight, control: true, shift: true),
    ],
    CodeShortcutType.cursorMoveLineStart => const [SingleActivator(LogicalKeyboardKey.home)],
    CodeShortcutType.cursorMoveLineEnd => const [SingleActivator(LogicalKeyboardKey.end)],
    CodeShortcutType.selectionExtendLineStart => const [SingleActivator(LogicalKeyboardKey.home, shift: true)],
    CodeShortcutType.selectionExtendLineEnd => const [SingleActivator(LogicalKeyboardKey.end, shift: true)],
    _ => _default.build(type),
  };
}

/// re_editor asks for prompts while typing: ours come from the index (pg_core complete()).
class _SqlPrompts implements CodeAutocompletePromptsBuilder {
  _SqlPrompts(this.view);

  final EditorViewState view;

  @override
  CodeAutocompleteEditingValue? build(BuildContext context, CodeLine codeLine, CodeLineSelection selection) {
    if (view.widget.workspace.index == null || !selection.isCollapsed) return null;
    final c = view.completionAt(selection);
    if (c.items.isEmpty) return null;
    return CodeAutocompleteEditingValue(input: c.prefix, prompts: [for (final i in c.items) _Prompt(i)], index: 0);
  }
}

class _Prompt extends CodeFieldPrompt {
  _Prompt(this.item) : super(word: item.insert, type: item.detail);

  final CompletionItem item;

  @override
  bool match(String input) => true;
}

IconData _completionIcon(CompletionKind k) => switch (k) {
  CompletionKind.schema => Icons.folder_special_outlined,
  CompletionKind.table => Icons.table_chart_outlined,
  CompletionKind.view => Icons.view_list_outlined,
  CompletionKind.function => Icons.functions,
  CompletionKind.procedure => Icons.play_arrow_outlined,
  CompletionKind.type => Icons.data_object,
  CompletionKind.sequence => Icons.format_list_numbered,
  CompletionKind.column => Icons.view_column_outlined,
  CompletionKind.keyword => Icons.short_text,
};

class _CompletionList extends StatefulWidget implements PreferredSizeWidget {
  const _CompletionList({required this.view, required this.notifier, required this.onSelected});

  final EditorViewState view;

  final ValueNotifier<CodeAutocompleteEditingValue> notifier;
  final ValueChanged<CodeAutocompleteResult> onSelected;

  static const _row = 24.0;

  @override
  Size get preferredSize => Size(520, (notifier.value.prompts.length.clamp(1, 10)) * _row + 8);

  @override
  State<_CompletionList> createState() => _CompletionListState();
}

class _CompletionListState extends State<_CompletionList> {
  @override
  void initState() {
    super.initState();
    widget.view.completionList = (notifier: widget.notifier, onSelected: widget.onSelected);
  }

  @override
  void dispose() {
    if (widget.view.completionList?.notifier == widget.notifier) widget.view.completionList = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notifier = widget.notifier;
    final onSelected = widget.onSelected;
    final preferredSize = widget.preferredSize;
    const row = _CompletionList._row;
    final theme = Theme.of(context);
    final colors = SyntaxColors.of(context);
    return ValueListenableBuilder<CodeAutocompleteEditingValue>(
      valueListenable: notifier,
      builder: (context, value, _) => Container(
        key: const Key('editor.completion'),
        width: preferredSize.width,
        height: preferredSize.height,
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
          boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black38)],
        ),
        child: ListView.builder(
          itemCount: value.prompts.length,
          itemExtent: row,
          itemBuilder: (context, i) {
            final item = (value.prompts[i] as _Prompt).item;
            return InkWell(
              key: Key('editor.completion.$i'),
              onTap: () => onSelected(value.copyWith(index: i).autocomplete),
              child: Container(
                color: i == value.index ? theme.colorScheme.primary.withValues(alpha: 0.22) : null,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Icon(
                      _completionIcon(item.kind),
                      size: 14,
                      color: item.kind == CompletionKind.keyword ? colors.keyword : colors.relation,
                    ),
                    const SizedBox(width: 6),
                    Text(item.label, style: theme.textTheme.bodySmall?.copyWith(fontFamily: editorFont)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        item.detail,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SignatureCard extends StatelessWidget {
  const _SignatureCard({required this.help});

  final SignatureHelp help;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(fontFamily: editorFont, fontFamilyFallback: editorFontFallback);
    return Material(
      key: const Key('editor.signature'),
      elevation: 6,
      borderRadius: BorderRadius.circular(6),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in help.signatures.take(3))
              Text.rich(
                TextSpan(
                  style: style,
                  children: [
                    TextSpan(text: '${o.key.qualified}('),
                    for (var i = 0; i < o.latest.parameters.length; i++) ...[
                      if (i > 0) const TextSpan(text: ', '),
                      TextSpan(
                        text: o.latest.parameters[i].toString(),
                        style: i == help.activeParameter
                            ? TextStyle(fontWeight: FontWeight.w700, color: theme.colorScheme.primary)
                            : null,
                      ),
                    ],
                    TextSpan(text: ')${o.latest.returns == null ? '' : ' RETURNS ${o.latest.returns}'}'),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
