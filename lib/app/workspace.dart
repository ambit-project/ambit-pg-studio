import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart' hide ObjectKey;
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:re_editor/re_editor.dart';
import 'package:watcher/watcher.dart';

import 'app_settings.dart';
import 'describe.dart';
import 'project_controller.dart';
import 'terminals.dart';

/// A place in a file: where navigation goes and what back/forward remembers.
@immutable
class Location {
  const Location(this.path, this.offset, [this.length = 0]);

  final String path;
  final int offset;
  final int length;

  @override
  bool operator ==(Object other) => other is Location && other.path == path && other.offset == offset;

  @override
  int get hashCode => Object.hash(path, offset);
}

/// One open file.
class EditorTab {
  EditorTab(this.path, this.savedText) {
    controller = CodeLineEditingController(codeLines: CodeLines.fromText(savedText), spanBuilder: _span);
    _refresh(savedText);
    controller.addListener(_changed);
  }

  final String path;

  /// The text on disk the tab was loaded from or last saved as.
  String savedText;
  late final CodeLineEditingController controller;
  final CodeScrollController scroll = CodeScrollController();

  /// Builds the spans of one line; set by the editor view (it knows the theme and the index).
  TextSpan Function(EditorTab tab, int line, String text, TextStyle style)? lineSpans;

  /// Called when the text changes (not on selection moves).
  VoidCallback? onTextChanged;

  String _text = '';

  /// `text.hashCode`, compared with FileAnalysis.contentHash: overlays from the index are drawn only when the index
  /// was built from the text in the tab.
  int textHash = 0;
  List<int> lineStarts = const [0];
  List<HighlightToken> tokens = const [];
  bool dirty = false;

  /// The text on disk changed while the tab had unsaved edits (spec 006): the view asks what to do.
  bool diskConflict = false;

  String get text => _text;

  String get name => p.basename(path);

  void _changed() {
    final now = controller.text;
    if (now == _text) return;
    _refresh(now);
    onTextChanged?.call();
  }

  void _refresh(String text) {
    _text = text;
    textHash = text.hashCode;
    dirty = text != savedText;
    final starts = <int>[0];
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) starts.add(i + 1);
    }
    lineStarts = starts;
    tokens = highlight(text);
  }

  TextSpan _span({
    required BuildContext context,
    required int index,
    required CodeLine codeLine,
    required TextSpan textSpan,
    required TextStyle style,
  }) {
    final builder = lineSpans;
    if (builder == null) return textSpan;
    return builder(this, index, codeLine.text, style);
  }

  /// UTF-16 offset of a line and column.
  int offsetOf(int line, int column) {
    if (line < 0) return 0;
    if (line >= lineStarts.length) return _text.length;
    return (lineStarts[line] + column).clamp(0, _text.length);
  }

  (int line, int column) lineColumn(int offset) {
    var low = 0;
    var high = lineStarts.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (lineStarts[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return (low, offset - lineStarts[low]);
  }

  int get cursorOffset {
    final e = controller.selection.extent;
    return offsetOf(e.index, e.offset);
  }

  /// Selects [start, end) and scrolls it to the middle of the editor when it is not visible.
  void reveal(int start, int end) {
    final (sl, sc) = lineColumn(start.clamp(0, _text.length));
    final (el, ec) = lineColumn(end.clamp(0, _text.length));
    controller.selection = CodeLineSelection(baseIndex: sl, baseOffset: sc, extentIndex: el, extentOffset: ec);
    controller.makePositionCenterIfInvisible(CodeLinePosition(index: sl, offset: sc));
  }

  /// Replaces the text with what is on disk (reload), keeping the undo history out of it.
  void reload(String disk) {
    savedText = disk;
    diskConflict = false;
    controller.text = disk;
    _refresh(controller.text);
  }

  void dispose() {
    controller.removeListener(_changed);
    controller.dispose();
    scroll.dispose();
  }
}

enum BottomPanel { problems, references, search, history, changes, graph, errorCodes, contract, terminal }

/// A titled list of places, e.g. the result of Find references.
class PlaceList {
  const PlaceList(this.title, this.places);

  final String title;

  /// Groups in order (for a table: reads, writes, other uses); each place with the kind shown next to it.
  final List<(String group, List<(Location place, String kind)> items)> places;

  int get count => places.fold(0, (n, g) => n + g.$2.length);
}

/// Open tabs, the active one, navigation history and the bottom panel.
class Workspace extends ChangeNotifier {
  Workspace(this.project, {this.watchDisk = true, this.keepSession = true}) : settings = AppSettings(project.settings) {
    project.addListener(_projectChanged);
  }

  /// Theme and font size.
  final AppSettings settings;

  /// False in a window with only the ER diagram (3.1): it neither restores nor writes the tabs of the folder.
  final bool keepSession;

  /// Shells of the Terminal panel (3.0 spec 003).
  final Terminals terminals = Terminals();

  /// Watch the opened folder for changes made outside (an agent, git); off in widget tests.
  final bool watchDisk;
  StreamSubscription<WatchEvent>? _watch;
  final Set<String> _diskPending = {};
  Timer? _diskTimer;

  /// Delay that groups a burst of disk events (a git checkout, an agent writing several files).
  static const diskDelay = Duration(milliseconds: 200);

  final ProjectController project;
  final List<EditorTab> tabs = [];
  int active = -1;
  BottomPanel panel = BottomPanel.problems;
  PlaceList? references;

  /// The object in the middle of the graph (by key: the index changes under it), or the module graph.
  ObjectKey? graphKey;
  bool moduleGraph = false;

  /// The ER diagram (2.0 spec 009) instead of the object or module graph; its scope `schema:<s>` or `module:<m>`.
  bool erGraph = false;
  String? erScope;

  /// Starts another process of the app with [args] (3.1: the ER diagram in a new window); replaced in tests.
  Future<void> Function(List<String> args) launchWindow = _defaultLaunchWindow;

  /// Replaced in tests: where an exported PNG goes (null = cancelled).
  Future<String?> Function(String suggestedName) pickSavePath = _defaultSavePath;
  final List<Location> _back = [];
  final List<Location> _forward = [];
  final Map<String, Timer> _liveTimers = {};
  String? _root;

  /// Delay after the last keystroke before an edited file is analysed again (spec 006).
  static const liveDelay = Duration(milliseconds: 350);

  EditorTab? get current => active >= 0 && active < tabs.length ? tabs[active] : null;

  ProjectIndex? get index => project.index;

  bool get canGoBack => _back.isNotEmpty;

  bool get canGoForward => _forward.isNotEmpty;

  void _projectChanged() {
    if (project.root != _root) {
      saveSession();
      _root = project.root;
      _restorePending = _root != null && keepSession;
      for (final t in tabs) {
        t.dispose();
      }
      tabs.clear();
      active = -1;
      references = null;
      _back.clear();
      _forward.clear();
      formatOptions = _root == null ? const FormatOptions() : FormatOptions.forFolder(_root!);
      _startWatching();
    }
    for (final t in tabs) {
      t.controller.forceRepaint();
    }
    if (searchQuery.isNotEmpty && project.index != null) {
      final r = searchProject(
        project.index!,
        searchQuery,
        regex: searchRegex,
        caseSensitive: searchCase,
        wholeWord: searchWord,
        pathFilter: searchPaths,
      );
      searchHits = r.hits;
      searchError = r.error;
    }
    notifyListeners();
    if (_restorePending && project.index != null && project.root == _root) {
      _restorePending = false;
      unawaited(restoreSession());
    }
  }

  // --- the session (2.0 spec 013) ----------------------------------------------------------------------------------

  static const _sessionsKey = 'sessions';
  bool _restorePending = false;
  bool _restoring = false;

  /// The open tabs of this folder with their cursors, and the active one.
  Map<String, Object?> get session => {
    'tabs': [
      for (final t in tabs) {'path': t.path, 'offset': t.cursorOffset},
    ],
    'active': active,
  };

  /// Tabs opened, closed or switched: written at once (cursor moves are written on exit, when the window loses
  /// focus and before another folder opens).
  void _sessionChanged() => saveSession();

  /// Writes the session of the open folder. Sessions of folders that are no longer recent are dropped.
  void saveSession() {
    final root = _root;
    if (root == null || _restoring || !keepSession) return;
    final all = (project.settings.read()[_sessionsKey] as Map?)?.cast<String, Object?>() ?? {};
    all[root] = session;
    all.removeWhere((k, _) => k != root && !project.recent.contains(k));
    project.settings.write(_sessionsKey, all);
  }

  /// Opens the tabs saved for this folder with their cursors (missing files are skipped).
  Future<void> restoreSession() async {
    final root = _root;
    final saved = ((project.settings.read()[_sessionsKey] as Map?)?[root] as Map?)?.cast<String, Object?>();
    if (root == null || saved == null) return;
    _restoring = true;
    try {
      final list = (saved['tabs'] as List?) ?? const [];
      for (final t in list.whereType<Map<Object?, Object?>>()) {
        final path = t['path'];
        if (path is! String || !File(_absolute(path)).existsSync()) continue;
        final offset = t['offset'];
        await open(path, select: offset is int ? offset : 0, remember: false);
        if (project.root != root) return;
      }
      final a = saved['active'];
      if (a is int && a >= 0 && a < tabs.length) {
        active = a;
        notifyListeners();
      }
    } finally {
      _restoring = false;
    }
  }

  String _absolute(String path) => p.join(project.root!, path);

  // --- the disk ----------------------------------------------------------------------------------------------------

  static const _ignoredFolders = {'.git', '.dart_tool', 'node_modules', 'build', 'bin', 'obj', 'target'};

  void _startWatching() {
    unawaited(_watch?.cancel());
    _watch = null;
    final root = project.root;
    if (!watchDisk || root == null) return;
    _watch = DirectoryWatcher(root).events.listen((e) {
      final rel = p.relative(e.path, from: root).replaceAll(r'\', '/');
      if (!rel.toLowerCase().endsWith('.sql')) return;
      if (rel.split('/').any((s) => s.startsWith('.') || _ignoredFolders.contains(s))) return;
      _diskPending.add(rel);
      _diskTimer?.cancel();
      _diskTimer = Timer(diskDelay, () {
        final changed = _diskPending.toList();
        _diskPending.clear();
        unawaited(diskChanged(changed));
      });
    }, onError: (Object _) {});
  }

  /// Files changed, added or removed on disk: clean tabs reload, tabs with unsaved edits get a conflict the view
  /// asks about (never overwritten silently), then the index follows (unsaved texts still win).
  Future<void> diskChanged(List<String> paths) async {
    if (project.root == null) return;
    for (final path in paths) {
      final tab = tabs.where((t) => t.path == path).firstOrNull;
      if (tab == null) continue;
      final file = File(_absolute(path));
      final disk = file.existsSync() ? file.readAsStringSync() : null;
      if (disk == null && !tab.dirty) {
        close(tabs.indexOf(tab)); // deleted, nothing to lose
        continue;
      }
      if (disk == tab.text) {
        tab.savedText = disk!;
        tab.dirty = false;
        continue;
      }
      if (disk == tab.savedText) continue; // our own save
      if (!tab.dirty && disk != null) {
        tab.reload(disk);
      } else {
        tab.diskConflict = true;
      }
    }
    notifyListeners();
    await project.reindex(paths, texts: unsavedTexts);
  }

  /// The answer to a disk conflict: reload the disk version, or keep the edits (a save will overwrite the disk).
  Future<void> resolveConflict(EditorTab tab, {required bool reload}) async {
    final file = File(_absolute(tab.path));
    final disk = file.existsSync() ? file.readAsStringSync() : '';
    if (reload) {
      tab.reload(disk);
    } else {
      tab.savedText = disk;
      tab.diskConflict = false;
      tab.dirty = tab.text != disk;
    }
    notifyListeners();
    await project.reindex([tab.path], texts: unsavedTexts);
  }

  /// Opens [path] (relative) in a tab, or activates it; with [select] selects that range.
  Future<EditorTab?> open(String path, {int? select, int length = 0, bool remember = true}) async {
    if (project.root == null) return null;
    if (remember) _remember();
    var i = tabs.indexWhere((t) => t.path == path);
    if (i < 0) {
      final String text;
      try {
        // SQL files are small; a synchronous read keeps open() a single step (no frame with a half-open tab).
        text = File(_absolute(path)).readAsStringSync();
      } on Object {
        return null;
      }
      final tab = EditorTab(path, text);
      tab.onTextChanged = () => _textChanged(tab);
      tabs.add(tab);
      i = tabs.length - 1;
    }
    active = i;
    notifyListeners();
    _sessionChanged();
    final tab = tabs[i];
    if (select != null) {
      // The editor lays the text out in the next frame; reveal after it.
      WidgetsBinding.instance.addPostFrameCallback((_) => tab.reveal(select, select + length));
      WidgetsBinding.instance.scheduleFrame();
    }
    return tab;
  }

  Future<void> goTo(Location to) async {
    await open(to.path, select: to.offset, length: to.length);
  }

  /// Opens [path] at a 1-based [line] and [column] (paths printed in the terminal).
  Future<void> openAt(String path, int line, int column) async {
    final tab = await open(path);
    if (tab == null) return;
    final at = tab.offsetOf(line - 1, column - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) => tab.reveal(at, at));
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> goToSpan(SourceSpan span) => goTo(Location(span.file, span.start, span.end - span.start));

  void activate(int i) {
    if (i < 0 || i >= tabs.length || i == active) return;
    _remember();
    active = i;
    notifyListeners();
    _sessionChanged();
  }

  /// Closes a tab without asking; the view asks about unsaved changes first.
  void close(int i) {
    if (i < 0 || i >= tabs.length) return;
    final tab = tabs.removeAt(i);
    _liveTimers.remove(tab.path)?.cancel();
    final wasDirty = tab.dirty;
    tab.dispose();
    if (active >= tabs.length) active = tabs.length - 1;
    if (i < active) active--;
    notifyListeners();
    _sessionChanged();
    // The index followed the unsaved text; going back to the disk version.
    if (wasDirty) unawaited(project.reindex([tab.path]));
  }

  Future<void> save(EditorTab tab) async {
    if (formatOptions.formatOnSave) format(tab);
    final text = tab.controller.text;
    await File(_absolute(tab.path)).writeAsString(text);
    tab.savedText = text;
    tab.dirty = false;
    tab.diskConflict = false;
    _liveTimers.remove(tab.path)?.cancel();
    notifyListeners();
    await project.reindex([tab.path]);
  }

  void _textChanged(EditorTab tab) {
    _liveTimers.remove(tab.path)?.cancel();
    _liveTimers[tab.path] = Timer(liveDelay, () {
      _liveTimers.remove(tab.path);
      unawaited(project.reindex([tab.path], texts: {tab.path: tab.controller.text}));
    });
    notifyListeners();
  }

  /// Texts of tabs with unsaved changes (they win over the disk when re-indexing).
  Map<String, String> get unsavedTexts => {
    for (final t in tabs)
      if (t.dirty) t.path: t.controller.text,
  };

  // --- navigation history ------------------------------------------------------------------------------------------

  Location? get here {
    final tab = current;
    if (tab == null) return null;
    return Location(tab.path, tab.cursorOffset);
  }

  void _remember() {
    final h = here;
    if (h == null) return;
    if (_back.isEmpty || _back.last != h) _back.add(h);
    if (_back.length > 100) _back.removeAt(0);
    _forward.clear();
  }

  Future<void> back() async {
    if (_back.isEmpty) return;
    final h = here;
    final to = _back.removeLast();
    if (h != null) _forward.add(h);
    await open(to.path, select: to.offset, remember: false);
  }

  Future<void> forward() async {
    if (_forward.isEmpty) return;
    final h = here;
    final to = _forward.removeLast();
    if (h != null) _back.add(h);
    await open(to.path, select: to.offset, remember: false);
  }

  // --- formatting (2.0 spec 001) ------------------------------------------------------------------------------------

  /// The `format` options of the project's `.pgstudio.json` (read when a folder opens).
  FormatOptions formatOptions = const FormatOptions();

  /// Replaced in tests: whether a file is already in the main branch (git).
  bool Function(String root, String path) inMainBranch = Git.inMainBranch;

  /// Formats the selection (or the whole file) of [tab] as one undoable edit; returns what was done.
  FormatResult format(EditorTab tab) {
    final sel = tab.controller.selection;
    final a = tab.offsetOf(sel.baseIndex, sel.baseOffset);
    final b = tab.offsetOf(sel.extentIndex, sel.extentOffset);
    final hasRange = a != b;
    final result = formatSql(
      tab.text,
      options: formatOptions,
      rangeStart: hasRange ? (a < b ? a : b) : null,
      rangeEnd: hasRange ? (a < b ? b : a) : null,
      fileIsNew: project.root != null && !inMainBranch(project.root!, tab.path),
    );
    if (result.text != tab.text) {
      final (line, _) = tab.lineColumn(tab.cursorOffset);
      tab.controller.selectAll();
      tab.controller.replaceSelection(result.text);
      final lines = tab.lineStarts.length;
      final keep = line < lines ? line : lines - 1;
      tab.controller.selection = CodeLineSelection.collapsed(index: keep, offset: 0);
    }
    return result;
  }

  /// Opens the file of [problem] and applies its quick fix as one undoable edit (saving stays with the user).
  Future<void> applyFix(Problem problem) async {
    final fix = problem.fix;
    if (fix == null) return;
    final tab = await open(problem.span.file, select: problem.span.start);
    if (tab == null) return;
    final fixed = applyQuickFix(tab.text, fix);
    if (fixed == tab.text) return;
    tab.controller.selectAll();
    tab.controller.replaceSelection(fixed);
    notifyListeners();
  }

  /// Replaced in tests: paths in the main branch (null = unknown: every dated changeset counts as deployed).
  Set<String>? Function(String root) filesInMain = Git.filesInMain;

  /// What F2 renames at [offset]: an object, or a column (2.0 spec 003).
  ({ObjectKey object, String? column, String old, String label})? renameTarget(String path, int offset) {
    final index = this.index;
    if (index == null) return null;
    final objects = objectsAt(path, offset);
    if (objects.isNotEmpty) {
      final o = objects.first;
      return (object: o.key, column: null, old: o.key.name, label: '${o.kind.label} ${o.key.qualified}');
    }
    final c = index.columnAt(path, offset);
    if (c == null) return null;
    return (object: c.relation, column: c.column, old: c.column, label: 'column ${c.relation.qualified}.${c.column}');
  }

  RenamePlan planRenameOf(ObjectKey object, String? column, String newName, {DateTime? now}) {
    final d = now ?? DateTime.now();
    final today = '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
    return planRename(
      index!,
      object: object,
      column: column,
      newName: newName,
      inMain: filesInMain(project.root!),
      today: today,
    );
  }

  /// Writes [plan]; refuses when a file it touches has unsaved edits. Renamed open files reopen under the new name.
  Future<String?> applyRename(RenamePlan plan) async {
    final touched = {...plan.edits.keys, ...plan.renames.keys};
    final dirty = tabs.where((t) => t.dirty && touched.contains(t.path)).map((t) => t.path).toList();
    if (dirty.isNotEmpty) return 'Save or close first: ${dirty.join(', ')}';
    final changed = applyRenamePlan(project.root!, plan);
    for (final r in plan.renames.entries) {
      final i = tabs.indexWhere((t) => t.path == r.key);
      if (i >= 0) {
        close(i);
        await open(r.value);
      }
    }
    await diskChanged(changed);
    return null;
  }

  /// Writes a new file from a template, re-indexes it and opens it with the cursor where writing starts.
  Future<void> createFile(NewFile file) async {
    createNewFile(project.root!, file);
    await diskChanged([file.path]);
    await open(file.path, select: file.cursor);
  }

  // --- search in the project (2.0 spec 007) -------------------------------------------------------------------------

  String searchQuery = '';
  bool searchRegex = false;
  bool searchCase = false;
  bool searchWord = false;
  String searchPaths = '';
  List<SearchHit> searchHits = const [];
  String? searchError;

  /// Bumped by Ctrl+Shift+F so the panel focuses its query field.
  int searchFocus = 0;

  void openSearch({String? query}) {
    if (query != null && query.isNotEmpty) searchQuery = query;
    panel = BottomPanel.search;
    searchFocus++;
    runSearch();
  }

  void runSearch() {
    final index = this.index;
    if (index == null) return;
    final r = searchProject(
      index,
      searchQuery,
      regex: searchRegex,
      caseSensitive: searchCase,
      wholeWord: searchWord,
      pathFilter: searchPaths,
    );
    searchHits = r.hits;
    searchError = r.error;
    notifyListeners();
  }

  RenamePlan replaceAllPlan(String replacement) =>
      replacePlan(index!, searchHits, replacement, regex: searchRegex, inMain: filesInMain(project.root!));

  /// The object of the History panel (2.0 spec 008).
  ObjectKey? historyKey;

  void showHistory(DbObject object) {
    historyKey = object.key;
    panel = BottomPanel.history;
    notifyListeners();
  }

  bool showHistoryAt(String path, int offset) {
    final objects = objectsAt(path, offset);
    if (objects.isNotEmpty) {
      showHistory(objects.first);
      return true;
    }
    final c = index?.columnAt(path, offset);
    final table = c == null ? null : index!.objects[c.relation];
    if (table == null) return false;
    showHistory(table);
    return true;
  }

  // --- the branch against main (2.0 spec 010) ----------------------------------------------------------------------

  BranchReview? review;
  bool reviewing = false;
  bool reviewDone = false;

  Future<void> refreshReview() async {
    final index = this.index;
    if (index == null || reviewing) return;
    reviewing = true;
    notifyListeners();
    try {
      review = await reviewBranch(index);
    } finally {
      reviewing = false;
      reviewDone = true;
      notifyListeners();
    }
  }

  Future<void> showChanges() async {
    panel = BottomPanel.changes;
    notifyListeners();
    await refreshReview();
  }

  // --- what is under the cursor -------------------------------------------------------------------------------------

  /// Objects at [offset] of [path]: the targets of a reference there, or the object defined there.
  List<DbObject> objectsAt(String path, int offset) {
    final index = this.index;
    if (index == null) return const [];
    final ref = index.referenceAt(path, offset);
    if (ref != null) return [for (final t in ref.targets) ?index.objects[t]];
    final def = index.definitionAt(path, offset);
    return def == null ? const [] : [def];
  }

  /// The span to underline as a link at [offset] (a resolved reference or a definition name).
  SourceSpan? linkAt(String path, int offset) {
    final index = this.index;
    if (index == null) return null;
    final ref = index.referenceAt(path, offset);
    if (ref != null) return ref.targets.isEmpty ? null : ref.span;
    for (final d in index.files[path]?.definitions ?? const <Definition>[]) {
      if (d.nameSpan.start <= offset && offset <= d.nameSpan.end) return d.nameSpan;
    }
    return index.columnAt(path, offset)?.use?.span;
  }

  String? hoverAt(String path, int offset) {
    final index = this.index;
    if (index == null) return null;
    final objects = objectsAt(path, offset);
    if (objects.isEmpty) {
      final c = index.columnAt(path, offset);
      if (c == null) return null;
      final info = index.objects[c.relation]?.columns.where((x) => x.name == c.column).firstOrNull;
      final def = index.columnDefinition(c.relation, c.column);
      final uses = index.columnUsesOf(c.relation, c.column);
      return 'column ${c.relation.qualified}.${c.column}${info == null || info.type.isEmpty ? '' : ' ${info.type}'}'
          '${info?.notNull == true ? ' NOT NULL' : ''}\n'
          '${uses.where((u) => u.kind == RefKind.read).length} reads, ${uses.where((u) => u.kind == RefKind.write).length} writes'
          '${def == null ? '' : '\n${def.file}:${index.files[def.file]!.lineColumn(def.start).$1 + 1}'}';
    }
    return objects.map((o) => describe(o, index)).join('\n\n');
  }

  /// Places Go to definition offers for [offset]: the defining statement of each target. On a definition name itself
  /// it is the other places of that object (CREATE and every ALTER).
  List<(Location place, String label)> definitionsAt(String path, int offset) {
    final index = this.index;
    if (index == null) return const [];
    final ref = index.referenceAt(path, offset);
    final places = <(Location, String)>[];
    if (ref != null) {
      for (final t in ref.targets) {
        final o = index.objects[t];
        if (o == null) continue;
        final d = o.primary;
        places.add((Location(d.nameSpan.file, d.nameSpan.start, d.nameSpan.end - d.nameSpan.start), o.signature));
      }
      return places;
    }
    final def = index.definitionAt(path, offset);
    if (def == null) {
      final c = index.columnAt(path, offset);
      if (c == null || c.use == null) return const [];
      final at = index.columnDefinition(c.relation, c.column);
      if (at == null) return const [];
      return [(Location(at.file, at.start, at.end - at.start), 'column ${c.relation.qualified}.${c.column}')];
    }
    for (final d in def.definitions) {
      places.add((
        Location(d.nameSpan.file, d.nameSpan.start, d.nameSpan.end - d.nameSpan.start),
        '${d.isAlter ? 'ALTER' : 'CREATE'} ${def.key.qualified} - ${d.nameSpan.file}',
      ));
    }
    return places;
  }

  /// Find references at [offset]; false when nothing there.
  bool findReferencesAt(String path, int offset) {
    final objects = objectsAt(path, offset);
    if (objects.isNotEmpty) {
      findReferences(objects.first);
      return true;
    }
    final c = index?.columnAt(path, offset);
    if (c == null) return false;
    findColumnReferences(c.relation, c.column);
    return true;
  }

  /// Find references of a column: reads and writes apart (2.0 spec 005).
  void findColumnReferences(ObjectKey relation, String column) {
    final index = this.index;
    if (index == null) return;
    final uses = index.columnUsesOf(relation, column);
    List<(Location, String)> of(RefKind k) => [
      for (final u in uses)
        if (u.kind == k) (Location(u.span.file, u.span.start, u.span.end - u.span.start), u.from?.qualified ?? k.label),
    ];
    references = PlaceList('column ${relation.qualified}.$column: ${uses.length} uses', [
      if (of(RefKind.read).isNotEmpty) ('Reads', of(RefKind.read)),
      if (of(RefKind.write).isNotEmpty) ('Writes', of(RefKind.write)),
    ]);
    panel = BottomPanel.references;
    notifyListeners();
  }

  /// Impact analysis (Shift+Alt+F12): what changes or breaks when the object or column at [offset] changes.
  bool impactAt(String path, int offset) {
    final index = this.index;
    if (index == null) return false;
    ObjectKey? relation;
    String? column;
    final objects = objectsAt(path, offset);
    if (objects.isNotEmpty) {
      relation = objects.first.key;
    } else {
      final c = index.columnAt(path, offset);
      if (c == null) return false;
      relation = c.relation;
      column = c.column;
    }
    final impact = index.impactOf(relation, column: column);
    final levels = <int, List<(Location, String)>>{};
    for (final i in impact) {
      final d = i.object.primary.nameSpan;
      (levels[i.level] ??= []).add((
        Location(d.file, d.start, d.end - d.start),
        '${i.object.kind.label}: ${i.how.map((k) => k.label).join(', ')}',
      ));
    }
    final what = column == null ? relation.qualified : '${relation.qualified}.$column';
    references = PlaceList('Impact of changing $what: ${impact.length} objects', [
      for (final e in levels.entries) (e.key == 1 ? 'Uses it directly' : 'Through views (level ${e.key})', e.value),
    ]);
    panel = BottomPanel.references;
    notifyListeners();
    return true;
  }

  // --- panels ------------------------------------------------------------------------------------------------------

  void showPanel(BottomPanel p) {
    panel = p;
    notifyListeners();
  }

  void showEr(String scope) {
    erScope = scope;
    erGraph = true;
    moduleGraph = false;
    panel = BottomPanel.graph;
    notifyListeners();
  }

  /// The ER diagram of [scope] in a new window: the same app with `<folder> --er=<scope>` (3.1).
  Future<void> openErWindow(String scope) async {
    final root = project.root;
    if (root == null) return;
    await launchWindow([root, '$erArg$scope']);
  }

  void showGraph(DbObject object) {
    graphKey = object.key;
    moduleGraph = false;
    erGraph = false;
    panel = BottomPanel.graph;
    notifyListeners();
  }

  void showModuleGraph() {
    moduleGraph = true;
    erGraph = false;
    panel = BottomPanel.graph;
    notifyListeners();
  }

  /// The graph of the object at [offset]; false when nothing there.
  bool showGraphAt(String path, int offset) {
    final objects = objectsAt(path, offset);
    if (objects.isEmpty) return false;
    showGraph(objects.first);
    return true;
  }

  /// Find references of [object]: for tables reads and writes apart, then the other uses.
  void findReferences(DbObject object) {
    final index = this.index;
    if (index == null) return;
    final uses = index.referencesTo(object.key);
    final groups = <String, List<(Location, String)>>{};
    final isRelation = object.key.space == ObjectSpace.relation;
    for (final r in uses) {
      final group = !isRelation
          ? 'References'
          : switch (r.kind) {
              RefKind.read => 'Reads',
              RefKind.write => 'Writes',
              _ => 'Other uses',
            };
      (groups[group] ??= []).add((
        Location(r.span.file, r.span.start, r.span.end - r.span.start),
        r.reference.dynamic ? '${r.kind.label} (dynamic SQL)' : r.kind.label,
      ));
    }
    final order = ['Reads', 'Writes', 'Other uses', 'References'];
    references = PlaceList('${object.kind.label} ${object.key.qualified}: ${uses.length} references', [
      for (final g in order)
        if (groups[g] != null) (g, groups[g]!),
    ]);
    panel = BottomPanel.references;
    notifyListeners();
  }

  @override
  void dispose() {
    project.removeListener(_projectChanged);
    terminals.closeAll();
    unawaited(_watch?.cancel());
    _diskTimer?.cancel();
    for (final t in _liveTimers.values) {
      t.cancel();
    }
    for (final t in tabs) {
      t.dispose();
    }
    super.dispose();
  }
}

Future<String?> _defaultSavePath(String suggestedName) async => (await getSaveLocation(
  suggestedName: suggestedName,
  acceptedTypeGroups: const [
    XTypeGroup(label: 'PNG', extensions: ['png']),
  ],
))?.path;

/// The argument that opens a window with only the ER diagram: `--er=schema:<s>` or `--er=module:<m>` (3.1).
const erArg = '--er=';

Future<void> _defaultLaunchWindow(List<String> args) async {
  await Process.start(Platform.resolvedExecutable, args, mode: ProcessStartMode.detached);
}
