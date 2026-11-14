import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../app/terminals.dart';
import '../app/workspace.dart';
import 'command_menu.dart';
import 'theme.dart';

/// The Terminal panel (3.0 spec 003): shells in the project folder, one tab each; Ctrl+click on `file.sql:12:5`
/// opens the place.
class TerminalPanel extends StatefulWidget {
  const TerminalPanel({super.key, required this.workspace, this.onToggle});

  final Workspace workspace;

  /// Ctrl+` inside the terminal (it takes every other key).
  final VoidCallback? onToggle;

  @override
  State<TerminalPanel> createState() => TerminalPanelState();
}

class TerminalPanelState extends State<TerminalPanel> {
  final Map<TerminalSession, TerminalController> _controllers = {};
  final Map<TerminalSession, FocusNode> _focus = {};
  Timer? _titles;
  late int _focusSeen = terminals.focusRequests;

  Workspace get ws => widget.workspace;
  Terminals get terminals => ws.terminals;

  @override
  void initState() {
    super.initState();
    terminals.addListener(_changed);
    // Titles follow the program in the foreground (bash, vim, claude).
    _titles = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && terminals.sessions.isNotEmpty) setState(() {});
    });
    if (terminals.sessions.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => openNew());
    } else {
      focusCurrent();
    }
  }

  @override
  void dispose() {
    _titles?.cancel();
    terminals.removeListener(_changed);
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (terminals.focusRequests != _focusSeen) {
      _focusSeen = terminals.focusRequests;
      focusCurrent();
    }
    for (final s in _controllers.keys.where((s) => !terminals.sessions.contains(s)).toList()) {
      _controllers.remove(s)!.dispose();
      _focus.remove(s)!.dispose();
    }
    setState(() {});
  }

  /// Focuses the active terminal (after it is laid out).
  void focusCurrent() {
    final s = terminals.current;
    if (s == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus[s]?.requestFocus());
  }

  void openNew([String? dir]) {
    final root = ws.project.root;
    if (root == null && dir == null) return;
    terminals.open(dir ?? root!);
    focusCurrent();
  }

  /// What Ctrl+click on [cell] does: opens the path printed there.
  void openPathAt(TerminalSession s, CellOffset cell) {
    final root = ws.project.root;
    if (root == null || cell.y < 0 || cell.y >= s.terminal.buffer.lines.length) return;
    final text = s.terminal.buffer.lines[cell.y].getText();
    final at = Terminals.pathAt(text, cell.x, s.cwd, root);
    if (at != null) unawaited(ws.openAt(at.path, at.line, at.column));
  }

  Future<void> _menu(TerminalSession s, Offset global) async {
    final controller = _controllers[s]!;
    final selection = controller.selection;
    await showCommandMenu(context, global, [
      MenuEntry('terminal.copy', () => _copy(s), enabled: selection != null),
      MenuEntry('terminal.paste', () => _paste(s)),
      MenuEntry('terminal.clear', () => _clear(s)),
      const MenuEntry.divider(),
      MenuEntry('terminal.new', openNew),
      MenuEntry('terminal.close', () => terminals.close(terminals.sessions.indexOf(s))),
    ]);
  }

  Future<void> _copy(TerminalSession s) async {
    final range = _controllers[s]!.selection;
    if (range == null) return;
    await Clipboard.setData(ClipboardData(text: s.terminal.buffer.getText(range)));
    _controllers[s]!.clearSelection();
  }

  Future<void> _paste(TerminalSession s) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) s.terminal.paste(data!.text!);
  }

  void _clear(TerminalSession s) {
    s.terminal.eraseScrollbackOnly();
    s.pty.write(const Utf8Encoder().convert('\x0c')); // Ctrl+L: the shell redraws its prompt at the top
  }

  TerminalTheme _theme(BuildContext context) {
    final colors = SyntaxColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = TerminalThemes.defaultTheme;
    return TerminalTheme(
      cursor: Theme.of(context).colorScheme.primary,
      selection: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
      foreground: colors.text,
      background: colors.background,
      black: dark ? base.black : const Color(0xFF1F2328),
      red: base.red,
      green: dark ? base.green : const Color(0xFF067D17),
      yellow: dark ? base.yellow : const Color(0xFF8A6D00),
      blue: base.blue,
      magenta: base.magenta,
      cyan: dark ? base.cyan : const Color(0xFF00737A),
      white: dark ? base.white : const Color(0xFF6E7781),
      brightBlack: base.brightBlack,
      brightRed: base.brightRed,
      brightGreen: dark ? base.brightGreen : const Color(0xFF1A7F37),
      brightYellow: dark ? base.brightYellow : const Color(0xFF9A6700),
      brightBlue: base.brightBlue,
      brightMagenta: base.brightMagenta,
      brightCyan: dark ? base.brightCyan : const Color(0xFF1B7C83),
      brightWhite: dark ? base.brightWhite : const Color(0xFF8C959F),
      searchHitBackground: base.searchHitBackground,
      searchHitBackgroundCurrent: base.searchHitBackgroundCurrent,
      searchHitForeground: base.searchHitForeground,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = terminals.sessions;
    final current = terminals.current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 30,
          color: theme.colorScheme.surfaceContainerLow,
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final (i, s) in sessions.indexed)
                      InkWell(
                        key: Key('terminal.tab.$i'),
                        onTap: () {
                          terminals.activate(i);
                          focusCurrent();
                        },
                        child: Container(
                          padding: const EdgeInsets.only(left: 10, right: 2),
                          decoration: BoxDecoration(
                            color: s == current ? theme.colorScheme.surface : null,
                            border: Border(
                              bottom: BorderSide(
                                color: s == current ? theme.colorScheme.primary : Colors.transparent,
                                width: 2,
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.terminal, size: 14, color: s.exited ? theme.disabledColor : null),
                              const SizedBox(width: 6),
                              Text(s.title, key: Key('terminal.title.$i'), style: theme.textTheme.bodySmall),
                              IconButton(
                                key: Key('terminal.close.$i'),
                                visualDensity: VisualDensity.compact,
                                iconSize: 14,
                                tooltip: 'Close terminal (ends its processes)',
                                onPressed: () => terminals.close(i),
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                key: const Key('terminal.new'),
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                tooltip: 'New terminal (Ctrl+Shift+`)',
                onPressed: openNew,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        Expanded(
          child: sessions.isEmpty
              ? Center(
                  child: TextButton.icon(
                    onPressed: openNew,
                    icon: const Icon(Icons.terminal),
                    label: const Text('Open a terminal in the project folder'),
                  ),
                )
              : IndexedStack(
                  index: terminals.active.clamp(0, sessions.length - 1),
                  sizing: StackFit.expand,
                  children: [
                    for (final s in sessions)
                      TerminalView(
                        s.terminal,
                        key: ObjectKey(s),
                        controller: _controllers.putIfAbsent(s, TerminalController.new),
                        focusNode: _focus.putIfAbsent(s, () => FocusNode(debugLabel: 'terminal ${s.pid}')),
                        autofocus: s == current,
                        hardwareKeyboardOnly: true,
                        theme: _theme(context),
                        textStyle: TerminalStyle(
                          fontSize: ws.settings.fontSize,
                          fontFamily: editorFont,
                          fontFamilyFallback: editorFontFallback,
                        ),
                        padding: const EdgeInsets.all(4),
                        shortcuts: const {
                          SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true):
                              CopySelectionTextIntent.copy,
                          SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true): PasteTextIntent(
                            SelectionChangedCause.keyboard,
                          ),
                        },
                        onKeyEvent: (node, event) {
                          if (event is KeyDownEvent &&
                              event.logicalKey == LogicalKeyboardKey.backquote &&
                              HardwareKeyboard.instance.isControlPressed) {
                            HardwareKeyboard.instance.isShiftPressed ? openNew() : widget.onToggle?.call();
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        onTapUp: (details, cell) {
                          if (HardwareKeyboard.instance.isControlPressed) openPathAt(s, cell);
                        },
                        onSecondaryTapUp: (details, cell) => unawaited(_menu(s, details.globalPosition)),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
