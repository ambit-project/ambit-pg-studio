import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

/// Where a command is described in the help (3.0 spec 002), in this order.
enum CommandSection {
  files('Files and tabs'),
  navigation('Navigation'),
  writing('Writing'),
  refactoring('Changes and refactoring'),
  review('Review and history'),
  view('View'),
  terminal('Terminal'),
  help('Help');

  const CommandSection(this.title);

  final String title;
}

/// One command of the app: the keyboard shortcuts, the context menus, the help and the command palette all take
/// its name, description and keys from here (3.0 spec 001, a decision of the 3.0 product).
@immutable
class AppCommand {
  const AppCommand(
    this.id,
    this.title,
    this.description,
    this.section, {
    this.keys = const [],
    this.icon,
    this.editorKeys = false,
    this.global = true,
  });

  final String id;
  final String title;
  final String description;
  final CommandSection section;

  /// The first one is shown next to the title.
  final List<SingleActivator> keys;
  final IconData? icon;

  /// The keys belong to the editor itself (cut, copy, paste): listed, never bound app-wide.
  final bool editorKeys;

  /// Runs without a target picked by the user (keyboard, palette); false for menu-only commands on a row or a node.
  final bool global;

  String? get shortcut => keys.isEmpty ? null : shortcutLabel(keys.first);
}

const _ctrl = true;

/// Every command. Keep ids stable: tests, menu keys (`menu.<id>`) and the help refer to them.
const List<AppCommand> appCommands = [
  // Files and tabs
  AppCommand(
    'folder.open',
    'Open folder…',
    'Opens a folder with database files (SQL, Liquibase changesets) and analyses it without a database connection. '
        'The last folder opens again at start, with its tabs and cursors.',
    CommandSection.files,
    keys: [SingleActivator(LogicalKeyboardKey.keyO, control: _ctrl)],
    icon: Icons.folder_open_outlined,
  ),
  AppCommand(
    'file.goto',
    'Go to file…',
    'Finds a file by a part of its path.',
    CommandSection.files,
    keys: [SingleActivator(LogicalKeyboardKey.keyP, control: _ctrl)],
    icon: Icons.find_in_page_outlined,
  ),
  AppCommand(
    'file.new',
    'New object or changeset…',
    'A procedure, function or view in a module (the _app contract or _internal), or a dated DDL/data changeset, '
        'from a template that passes the module rules. Only in folders with changelog/modules/.',
    CommandSection.files,
    keys: [SingleActivator(LogicalKeyboardKey.keyN, control: _ctrl)],
    icon: Icons.note_add_outlined,
  ),
  AppCommand(
    'file.save',
    'Save',
    'Writes the tab to disk (formatted first when formatOnSave is set in .pgstudio.json).',
    CommandSection.files,
    keys: [SingleActivator(LogicalKeyboardKey.keyS, control: _ctrl)],
    icon: Icons.save_outlined,
  ),
  AppCommand(
    'tab.close',
    'Close tab',
    'Closes the tab; unsaved changes are asked about first.',
    CommandSection.files,
    keys: [SingleActivator(LogicalKeyboardKey.keyW, control: _ctrl)],
    icon: Icons.close,
  ),
  AppCommand('tab.closeOthers', 'Close other tabs', 'Closes every tab but this one.', CommandSection.files),
  AppCommand('tab.closeSaved', 'Close saved tabs', 'Closes the tabs without unsaved changes.', CommandSection.files),
  AppCommand('tab.closeAll', 'Close all tabs', 'Closes every tab (unsaved ones ask first).', CommandSection.files),
  AppCommand(
    'path.copy',
    'Copy path',
    'Copies the path of the file relative to the opened folder.',
    CommandSection.files,
    icon: Icons.content_copy,
    global: false,
  ),
  AppCommand(
    'file.reveal',
    'Show in file manager',
    'Opens the folder of the file in the desktop file manager.',
    CommandSection.files,
    icon: Icons.folder_outlined,
    global: false,
  ),
  AppCommand(
    'file.newInModule',
    'New object in this module…',
    'The New dialog with this module chosen.',
    CommandSection.files,
    icon: Icons.note_add_outlined,
    global: false,
  ),

  // Navigation
  AppCommand(
    'object.goto',
    'Go to object…',
    'Finds a table, view, function, procedure, type or other object by name.',
    CommandSection.navigation,
    keys: [SingleActivator(LogicalKeyboardKey.keyT, control: _ctrl)],
    icon: Icons.manage_search,
  ),
  AppCommand(
    'nav.definition',
    'Go to definition',
    'Opens where the name at the cursor is defined (Ctrl+click does the same). Several places: pick one; on a '
        'definition name: its references.',
    CommandSection.navigation,
    keys: [SingleActivator(LogicalKeyboardKey.f12)],
    icon: Icons.open_in_new,
  ),
  AppCommand(
    'nav.references',
    'Find references',
    'Every use of the object or column at the cursor; tables are grouped into reads, writes and other uses, '
        'references from dynamic SQL are marked.',
    CommandSection.navigation,
    keys: [SingleActivator(LogicalKeyboardKey.f12, shift: true)],
    icon: Icons.link,
  ),
  AppCommand(
    'nav.back',
    'Back',
    'Returns to the previous place (every jump is remembered).',
    CommandSection.navigation,
    keys: [SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true)],
    icon: Icons.arrow_back,
  ),
  AppCommand(
    'nav.forward',
    'Forward',
    'Goes forward again after Back.',
    CommandSection.navigation,
    keys: [SingleActivator(LogicalKeyboardKey.arrowRight, alt: true)],
    icon: Icons.arrow_forward,
  ),
  AppCommand(
    'nav.graph',
    'Dependency graph',
    'What the object at the cursor uses and what uses it; the Graph panel also has the module graph and the ER '
        'diagram.',
    CommandSection.navigation,
    keys: [SingleActivator(LogicalKeyboardKey.keyG, control: _ctrl, shift: true)],
    icon: Icons.account_tree_outlined,
  ),
  AppCommand(
    'object.er',
    'ER diagram of the schema',
    'Tables of the schema with keys, foreign keys as arrows; PNG export.',
    CommandSection.navigation,
    icon: Icons.schema_outlined,
    global: false,
  ),
  AppCommand(
    'er.newWindow',
    'ER diagram in a new window',
    'Opens the ER diagram in its own window (e.g. on a second monitor); it follows the changes of the files.',
    CommandSection.navigation,
    icon: Icons.open_in_new,
    global: false,
  ),
  AppCommand(
    'er.resetView',
    'Reset the diagram view',
    'Back to the default size and position of the ER diagram: zoom 100%, the top left corner.',
    CommandSection.view,
    icon: Icons.fit_screen_outlined,
    global: false,
  ),

  // Writing
  AppCommand(
    'edit.format',
    'Format',
    'Formats the selection or the file: whitespace only, the token stream stays the same; deployed changesets are '
        'left as written.',
    CommandSection.writing,
    keys: [SingleActivator(LogicalKeyboardKey.keyI, control: _ctrl, shift: true)],
    icon: Icons.format_align_left,
  ),
  AppCommand(
    'edit.quickFix',
    'Quick fix',
    'Applies the quick fix of the problem at the cursor (for example json to jsonb) as one undoable edit.',
    CommandSection.writing,
    keys: [SingleActivator(LogicalKeyboardKey.period, control: _ctrl)],
    icon: Icons.auto_fix_high_outlined,
  ),
  AppCommand(
    'edit.cut',
    'Cut',
    'Cuts the selection.',
    CommandSection.writing,
    keys: [SingleActivator(LogicalKeyboardKey.keyX, control: _ctrl)],
    icon: Icons.content_cut,
    editorKeys: true,
  ),
  AppCommand(
    'edit.copy',
    'Copy',
    'Copies the selection.',
    CommandSection.writing,
    keys: [SingleActivator(LogicalKeyboardKey.keyC, control: _ctrl)],
    icon: Icons.content_copy,
    editorKeys: true,
  ),
  AppCommand(
    'edit.paste',
    'Paste',
    'Pastes the clipboard.',
    CommandSection.writing,
    keys: [SingleActivator(LogicalKeyboardKey.keyV, control: _ctrl)],
    icon: Icons.content_paste,
    editorKeys: true,
  ),
  AppCommand(
    'edit.selectAll',
    'Select all',
    'Selects the whole file.',
    CommandSection.writing,
    keys: [SingleActivator(LogicalKeyboardKey.keyA, control: _ctrl)],
    icon: Icons.select_all,
    editorKeys: true,
  ),
  AppCommand(
    'edit.undo',
    'Undo',
    'Undoes the last edit (formatting, a quick fix and a rename in an open tab are single edits).',
    CommandSection.writing,
    keys: [SingleActivator(LogicalKeyboardKey.keyZ, control: _ctrl)],
    icon: Icons.undo,
    editorKeys: true,
  ),
  AppCommand(
    'edit.complete',
    'Completion',
    'While typing: objects, columns by alias, routine parameters; inside CALL x( the signature with the current '
        'parameter. Enter or Tab picks.',
    CommandSection.writing,
    editorKeys: true,
  ),

  // Changes and refactoring
  AppCommand(
    'edit.rename',
    'Rename…',
    'Renames the object or column at the cursor in the whole project: a preview of every change with warnings '
        '(API contract changes, deployed changesets) and a dated ALTER ... RENAME changeset.',
    CommandSection.refactoring,
    keys: [SingleActivator(LogicalKeyboardKey.f2)],
    icon: Icons.drive_file_rename_outline,
  ),
  AppCommand(
    'nav.impact',
    'Impact of a change',
    'What changes or breaks when the object or column at the cursor changes: users directly and through views.',
    CommandSection.refactoring,
    keys: [SingleActivator(LogicalKeyboardKey.f12, shift: true, alt: true)],
    icon: Icons.crisis_alert_outlined,
  ),
  AppCommand(
    'search.project',
    'Search in all files',
    'Text or a regular expression in every file (whole word, case, a path filter), replace with a preview; '
        'deployed changesets are skipped.',
    CommandSection.refactoring,
    keys: [SingleActivator(LogicalKeyboardKey.keyF, control: _ctrl, shift: true)],
    icon: Icons.search,
  ),

  // Review and history
  AppCommand(
    'nav.history',
    'Object history',
    'Every changeset that created or changed the object at the cursor, in Liquibase order; for a table also the '
        'effective DDL after all of them.',
    CommandSection.review,
    keys: [SingleActivator(LogicalKeyboardKey.keyH, control: _ctrl, shift: true)],
    icon: Icons.history_edu_outlined,
  ),
  AppCommand(
    'review.changes',
    'Branch changes',
    'What the current git branch changed against main: objects added and changed, new problems, deployed '
        'changesets that were edited.',
    CommandSection.review,
    icon: Icons.difference_outlined,
  ),

  // Panels and rows
  AppCommand('row.open', 'Open', 'Opens the place in the editor.', CommandSection.view, global: false),
  AppCommand(
    'row.copy',
    'Copy line',
    'Copies the text of the row.',
    CommandSection.view,
    icon: Icons.content_copy,
    global: false,
  ),
  AppCommand(
    'row.copyLocation',
    'Copy path:line',
    'Copies file:line:column, the form pg-studio check prints.',
    CommandSection.view,
    global: false,
  ),

  // View
  AppCommand(
    'view.zoomIn',
    'Larger font',
    'Makes the editor font larger (saved).',
    CommandSection.view,
    keys: [
      SingleActivator(LogicalKeyboardKey.equal, control: _ctrl),
      SingleActivator(LogicalKeyboardKey.equal, control: _ctrl, shift: true),
      SingleActivator(LogicalKeyboardKey.numpadAdd, control: _ctrl),
    ],
    icon: Icons.zoom_in,
  ),
  AppCommand(
    'view.zoomOut',
    'Smaller font',
    'Makes the editor font smaller (saved).',
    CommandSection.view,
    keys: [
      SingleActivator(LogicalKeyboardKey.minus, control: _ctrl),
      SingleActivator(LogicalKeyboardKey.numpadSubtract, control: _ctrl),
    ],
    icon: Icons.zoom_out,
  ),
  AppCommand(
    'view.zoomReset',
    'Default font size',
    'Back to the default editor font size.',
    CommandSection.view,
    keys: [SingleActivator(LogicalKeyboardKey.digit0, control: _ctrl)],
  ),
  AppCommand(
    'terminal.toggle',
    'Terminal',
    'Shows the Terminal panel with a shell in the project folder and puts the keyboard there; pressed in the '
        'terminal, goes back to the previous panel.',
    CommandSection.terminal,
    keys: [SingleActivator(LogicalKeyboardKey.backquote, control: _ctrl)],
    icon: Icons.terminal,
  ),
  AppCommand(
    'terminal.new',
    'New terminal',
    'Another shell in the project folder, in its own tab.',
    CommandSection.terminal,
    keys: [SingleActivator(LogicalKeyboardKey.backquote, control: _ctrl, shift: true)],
    icon: Icons.add,
  ),
  AppCommand(
    'terminal.here',
    'Terminal here',
    'A shell in this folder.',
    CommandSection.terminal,
    icon: Icons.terminal,
    global: false,
  ),
  AppCommand(
    'terminal.copy',
    'Copy',
    'Copies the selected text of the terminal (Ctrl+C stays an interrupt for the shell).',
    CommandSection.terminal,
    keys: [SingleActivator(LogicalKeyboardKey.keyC, control: _ctrl, shift: true)],
    icon: Icons.content_copy,
    editorKeys: true,
    global: false,
  ),
  AppCommand(
    'terminal.paste',
    'Paste',
    'Pastes the clipboard into the terminal.',
    CommandSection.terminal,
    keys: [SingleActivator(LogicalKeyboardKey.keyV, control: _ctrl, shift: true)],
    icon: Icons.content_paste,
    editorKeys: true,
    global: false,
  ),
  AppCommand(
    'terminal.clear',
    'Clear',
    'Clears the scrollback and redraws the prompt at the top.',
    CommandSection.terminal,
    icon: Icons.clear_all,
    global: false,
  ),
  AppCommand(
    'terminal.close',
    'Close terminal',
    'Closes the terminal and ends the shell with everything started from it.',
    CommandSection.terminal,
    icon: Icons.close,
    global: false,
  ),
  AppCommand(
    'terminal.openPath',
    'Open a path from the output',
    'Ctrl+click file.sql, file.sql:12 or file.sql:12:5 in the output (pg-studio check, git, grep) opens the file '
        'at that line and column.',
    CommandSection.terminal,
    editorKeys: true,
  ),
  AppCommand(
    'help.open',
    'Help',
    'This help: what every command does, all shortcuts, what each problem means. On a line with a problem it '
        'opens the description of that problem.',
    CommandSection.help,
    keys: [SingleActivator(LogicalKeyboardKey.f1)],
    icon: Icons.help_outline,
  ),
  AppCommand(
    'palette.open',
    'Command palette',
    'Every command by name: type a part of its name or description, Enter runs it. Commands that cannot run here '
        'are listed with the reason.',
    CommandSection.help,
    keys: [SingleActivator(LogicalKeyboardKey.keyP, control: _ctrl, shift: true)],
    icon: Icons.keyboard_command_key,
  ),
  AppCommand(
    'help.problem',
    'What does this mean?',
    'The description of the problem with an example of a fix.',
    CommandSection.help,
    icon: Icons.help_outline,
    global: false,
  ),
  AppCommand(
    'view.settings',
    'Settings…',
    'Theme (system, light, dark) and the editor font size.',
    CommandSection.view,
    icon: Icons.settings_outlined,
  ),
];

final Map<String, AppCommand> _byId = {for (final c in appCommands) c.id: c};

AppCommand command(String id) => _byId[id] ?? (throw ArgumentError('unknown command $id'));

/// `Ctrl+Shift+F12`-style label of a shortcut.
String shortcutLabel(SingleActivator a) {
  final parts = [if (a.control) 'Ctrl', if (a.shift) 'Shift', if (a.alt) 'Alt', if (a.meta) 'Super'];
  final key = a.trigger;
  final name = switch (key) {
    LogicalKeyboardKey.arrowLeft => 'Left',
    LogicalKeyboardKey.arrowRight => 'Right',
    LogicalKeyboardKey.arrowUp => 'Up',
    LogicalKeyboardKey.arrowDown => 'Down',
    LogicalKeyboardKey.equal => '=',
    LogicalKeyboardKey.minus => '-',
    LogicalKeyboardKey.period => '.',
    LogicalKeyboardKey.backquote => '`',
    LogicalKeyboardKey.numpadAdd => 'Num +',
    LogicalKeyboardKey.numpadSubtract => 'Num -',
    _ => key.keyLabel.length == 1 ? key.keyLabel.toUpperCase() : key.keyLabel,
  };
  return [...parts, name].join('+');
}
