import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:pg_core/pg_core.dart';

import 'settings_store.dart';

/// The opened folder and its index. Indexing runs in an isolate (pg_core analyses files in more isolates).
class ProjectController extends ChangeNotifier {
  ProjectController({this.recentLimit = 10, SettingsStore? settings, this.cache})
    : settings = settings ?? SettingsStore();

  final int recentLimit;

  /// The phase 1 cache (2.0 spec 013); null in tests.
  final Phase1Cache? cache;
  final SettingsStore settings;
  static const _recentKey = 'recentFolders';

  String? root;
  ProjectIndex? index;
  IndexTiming? timing;
  bool indexing = false;
  String? error;
  List<String> recent = const [];

  /// Bumped on every new index, so views can rebuild cheaply.
  int generation = 0;

  Future<void> loadRecent() async {
    recent = [
      for (final r in (settings.read()[_recentKey] as List? ?? const []))
        if (r is String) r,
    ];
    notifyListeners();
  }

  Future<void> open(String folder) async {
    root = folder;
    index = null;
    timing = null;
    error = null;
    indexing = true;
    notifyListeners();
    try {
      final cache = this.cache;
      final (result, t) = await Isolate.run(() => Indexer.open(folder, cache: cache));
      if (root != folder) return; // another folder was opened meanwhile
      index = result;
      timing = t;
      generation++;
      await _remember(folder);
    } on Object catch (e) {
      error = 'Cannot index $folder: $e';
    } finally {
      if (root == folder) {
        indexing = false;
        notifyListeners();
      }
    }
  }

  Future<void> _updates = Future.value();

  /// Re-analyses [paths]; [texts] are editor contents not saved yet (they win over the disk). Updates run one after
  /// another, each on the newest index, so none is lost.
  Future<void> reindex(Iterable<String> paths, {Map<String, String>? texts}) {
    final changed = paths.toList();
    final folder = root;
    final next = _updates.then((_) async {
      final current = index;
      if (current == null || root != folder) return;
      final updated = await Indexer.update(current, changed, texts: texts, cache: cache);
      if (root != folder) return;
      index = updated;
      generation++;
      notifyListeners();
    });
    _updates = next.catchError((Object _) {});
    return next;
  }

  Future<void> _remember(String folder) async {
    recent = [folder, ...recent.where((r) => r != folder)].take(recentLimit).toList();
    settings.write(_recentKey, recent);
  }
}
