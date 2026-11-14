// Opens a folder: finds the SQL files, orders them like Liquibase, analyses them in parallel isolates, links.
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../analysis/extract.dart';
import '../model.dart';
import 'cache.dart';
import 'project_index.dart';

const _skippedDirectories = {'.git', '.dart_tool', 'node_modules', 'build', 'bin', 'obj', 'target', '.idea', '.vscode'};
const _masterChangelogs = [
  'changelog.yaml',
  'changelog.yml',
  'db.changelog-master.yaml',
  'db.changelog-master.yml',
  'changelog/db.changelog-master.yaml',
  'changelog/db.changelog-master.yml',
];

final class IndexTiming {
  const IndexTiming(this.files, this.analysis, this.link, {this.cached = 0});

  final int files;

  /// Files whose phase 1 came from the cache.
  final int cached;
  final Duration analysis;
  final Duration link;

  Duration get total => analysis + link;

  @override
  String toString() =>
      '$files files${cached > 0 ? ' ($cached cached)' : ''}: analysis ${analysis.inMilliseconds} ms, link ${link.inMilliseconds} ms';
}

abstract final class Indexer {
  /// Indexes [root] (absolute). [workers] isolates analyse the files (default: processors, at most 8); with
  /// [cache] unchanged files take their phase 1 from it (2.0 spec 013).
  static Future<(ProjectIndex, IndexTiming)> open(String root, {int? workers, Phase1Cache? cache}) async {
    final watch = Stopwatch()..start();
    final paths = listSqlFiles(root);
    final order = changelogOrder(root, paths);
    final (analyses, cached) = await _analyze(root, order, workers: workers, cache: cache);
    final analysis = watch.elapsed;
    final index = ProjectIndex.link(root, analyses, order);
    final timing = IndexTiming(paths.length, analysis, watch.elapsed - analysis, cached: cached);
    cache?.prune();
    return (index, timing);
  }

  /// Re-analyses [changed] paths (relative; missing files are removed) and re-links; other files keep their phase 1.
  static Future<ProjectIndex> update(
    ProjectIndex index,
    Iterable<String> changed, {
    Map<String, String>? texts,
    Phase1Cache? cache,
  }) async {
    final files = Map<String, FileAnalysis>.of(index.files);
    final toRead = <String>[];
    for (final path in changed) {
      final text = texts?[path];
      if (text != null) {
        files[path] = analyzeSafely(path, text);
      } else if (File(p.join(index.root, path)).existsSync()) {
        toRead.add(path);
      } else {
        files.remove(path);
      }
    }
    if (toRead.isNotEmpty) files.addAll((await _analyze(index.root, toRead, workers: 1, cache: cache)).$1);
    final paths = files.keys.toList();
    return ProjectIndex.link(index.root, files, changelogOrder(index.root, paths));
  }

  /// `.sql` files under [root], relative with `/`, without build and tool folders.
  static List<String> listSqlFiles(String root) {
    final result = <String>[];
    void visit(Directory dir) {
      final entries = dir.listSync(followLinks: false)..sort((a, b) => a.path.compareTo(b.path));
      for (final e in entries) {
        final name = p.basename(e.path);
        if (e is Directory) {
          if (!_skippedDirectories.contains(name) && !name.startsWith('.')) visit(e);
        } else if (e is File && name.toLowerCase().endsWith('.sql')) {
          result.add(p.relative(e.path, from: root).replaceAll(r'\', '/'));
        }
      }
    }

    visit(Directory(root));
    return result;
  }

  /// Liquibase order: the files the master changelog includes (include, includeAll by path), then the others by path.
  static List<String> changelogOrder(String root, List<String> paths) {
    final sorted = [...paths]..sort();
    for (final master in _masterChangelogs) {
      final file = File(p.join(root, master));
      if (!file.existsSync()) continue;
      final ordered = <String>[];
      final seen = <String>{};
      void addAll(Iterable<String> list) {
        for (final x in list) {
          if (seen.add(x)) ordered.add(x);
        }
      }

      try {
        final doc = loadYaml(file.readAsStringSync());
        final entries = (doc is YamlMap ? doc['databaseChangeLog'] : null) as YamlList? ?? YamlList();
        final base = p.dirname(master);
        for (final entry in entries) {
          if (entry is! YamlMap) continue;
          final include = entry['include'];
          final includeAll = entry['includeAll'];
          if (include is YamlMap && include['file'] is String) {
            final rel = include['relativeToChangelogFile'] == true;
            addAll([_normalize(rel ? p.join(base, include['file'] as String) : include['file'] as String)]);
          } else if (includeAll is YamlMap && includeAll['path'] is String) {
            final rel = includeAll['relativeToChangelogFile'] == true;
            var dir = _normalize(rel ? p.join(base, includeAll['path'] as String) : includeAll['path'] as String);
            if (!dir.endsWith('/')) dir = '$dir/';
            if (dir == './') dir = '';
            addAll(sorted.where((x) => x.startsWith(dir)));
          }
        }
      } on Object {
        return sorted;
      }
      addAll(sorted);
      return ordered.where(paths.contains).toList();
    }
    return sorted;
  }

  static String _normalize(String path) => p.normalize(path).replaceAll(r'\', '/');

  /// Phase 1 for [paths] in parallel isolates.
  static Future<Map<String, FileAnalysis>> analyzeFiles(String root, List<String> paths, {int? workers}) async =>
      (await _analyze(root, paths, workers: workers)).$1;

  static Future<(Map<String, FileAnalysis>, int cached)> _analyze(
    String root,
    List<String> paths, {
    int? workers,
    Phase1Cache? cache,
  }) async {
    final count = math.max(1, math.min(workers ?? Platform.numberOfProcessors, math.min(8, paths.length)));
    final batches = List.generate(count, (_) => <String>[]);
    for (var i = 0; i < paths.length; i++) {
      batches[i % count].add(paths[i]);
    }
    final results = await Future.wait([
      for (final batch in batches) Isolate.run(() => [for (final path in batch) _analyzePath(root, path, cache)]),
    ]);
    var cached = 0;
    final map = <String, FileAnalysis>{};
    for (final list in results) {
      for (final (a, hit) in list) {
        map[a.path] = a;
        if (hit) cached++;
      }
    }
    return (map, cached);
  }

  static (FileAnalysis, bool cached) _analyzePath(String root, String path, Phase1Cache? cache) {
    final String text;
    try {
      text = File(p.join(root, path)).readAsStringSync();
    } on Object catch (e) {
      return (_failed(path, 'Cannot read the file: $e', 'io'), false);
    }
    final hit = cache?.read(path, text);
    if (hit != null) return (hit, true);
    final analysis = analyzeSafely(path, text);
    cache?.write(analysis, text);
    return (analysis, false);
  }

  /// Phase 1 of one file; an exception becomes a visible problem (code `internal`) instead of failing the folder.
  static FileAnalysis analyzeSafely(String path, String text) {
    try {
      return analyzeFile(path, text);
    } on Object catch (e, stack) {
      // A bug in the analysis must not stop the folder from opening; the problem is visible (code internal).
      return _failed(
        path,
        'Internal analysis error: $e\n${stack.toString().split('\n').take(5).join('\n')}',
        'internal',
      );
    }
  }

  static FileAnalysis _failed(String path, String message, String code) => FileAnalysis(
    path: path,
    lineStarts: const [0],
    changesets: const [],
    definitions: const [],
    references: const [],
    problems: [Problem(Severity.error, message, SourceSpan(path, 0, 0), code: code)],
    errorCodes: const [],
    isPsqlScript: false,
    contentHash: 0,
  );
}
