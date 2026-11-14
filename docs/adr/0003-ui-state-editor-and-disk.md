# 0003. UI: ChangeNotifier state, re_editor with our own spans, one editor per tab, the disk watched

Status: accepted (2026-11-14)

## Decision

- **State**: two `ChangeNotifier`s, no state library. `ProjectController` holds the opened folder and its index
  (`Indexer.open` in `Isolate.run`; updates queued one after another on the newest index). `Workspace` holds tabs,
  navigation history, the bottom panel, Find references results and the graph. One window, one project: Riverpod would
  add ceremony without a second consumer of the state.
- **Editor**: `re_editor` 0.10 (`CodeEditor`, `CodeLineEditingController(spanBuilder:)`). Highlighting does not use
  re_highlight: every line gets spans from libpg_query tokens (`highlight()` in pg_core, dollar-quoted bodies scanned
  again) plus what the index knows (objects coloured by kind, definitions bold, problems underlined, the Ctrl+hover
  link). Index overlays are drawn only when `FileAnalysis.contentHash` equals the tab's text hash.
- **Pointer -> text**: `indicatorBuilder` receives `CodeIndicatorValueNotifier`; its visible lines carry `offset`
  in viewport coordinates (re_editor subtracts the scroll) and `paragraph.getPosition`. With a fixed gutter
  (`gutterWidth`), a pointer position maps to (line, column) without private API. Used by hover and Ctrl+click.
- **One editor per tab** in an `IndexedStack`: each tab keeps its scroll position, and a focused editor is never
  disposed by a tab switch (re_editor's cursor blink timer outlives a disposed editor - an assertion in debug).
  Closing a tab unfocuses it first.
- **Shortcuts**: re_editor's Linux defaults move by word with Alt+Left/Right; `EditorShortcuts` moves by word with
  Ctrl+Left/Right (Linux IDEs), so Alt+Left/Right go back/forward in the navigation history. Ctrl+S goes through
  `CodeShortcutSaveIntent`.
- **Live analysis**: 350 ms after the last keystroke the tab's text is re-analysed (`Indexer.update` with texts), so
  syntax errors and references follow unsaved edits; saving writes the file and re-indexes from disk.
- **Disk**: `watcher` (`DirectoryWatcher`) on the folder, `.sql` only, events grouped for 200 ms. A clean tab reloads, a
  tab with unsaved edits gets a conflict and the window asks (reload / keep mine) - never a silent overwrite. Closing
  the window with unsaved tabs asks through `AppLifecycleListener.onExitRequested`.
- **Graphs**: drawn with `CustomPainter` (no graph package): three columns for an object, an arc diagram for modules
  in number order (allowed arcs go up, violations are red).

## Evidence

Widget tests in `test/{ui,nav,editor,graph}` (`./verify ui|nav|editor|graph`) and the real-window scenario
`integration_test/screens_test.dart -d linux`, which also writes `docs/screens/*.png`.
