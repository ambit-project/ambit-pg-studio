// The phase 1 cache on halycon (read only; the cache is in a temp folder): what spec 2.0/013 promises.
@Tags(['corpus'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

final _root = p.normalize(p.join(Directory.current.path, '..', '..', '..', 'halycon.app.dev', 'db'));

void main() {
  test('halycon: the second open comes from the cache, faster, with the same index', () async {
    final tmp = Directory.systemTemp.createTempSync('pg_cache_corpus_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final cache = Phase1Cache.at(tmp.path);
    final (fresh, cold) = await Indexer.open(_root, cache: cache);
    expect(cold.cached, 0);
    // Best of three each (the JIT compiles both paths first; the app is compiled ahead of time).
    Future<(ProjectIndex, IndexTiming)> best(Phase1Cache? c) async {
      (ProjectIndex, IndexTiming)? b;
      for (var i = 0; i < 3; i++) {
        final r = await Indexer.open(_root, cache: c);
        if (b == null || r.$2.total < b.$2.total) b = r;
      }
      return b!;
    }

    final (_, plain) = await best(null);
    final (cached, warm) = await best(cache);
    print('halycon without cache: $plain');
    print('halycon filling the cache: $cold');
    print('halycon from the cache: $warm');
    expect(warm.cached, warm.files);
    expect(cached.references.length, fresh.references.length);
    expect(cached.problems.length, fresh.problems.length);
    expect(warm.total, lessThan(plain.total));
  }, skip: Directory(_root).existsSync() ? false : 'missing $_root');
}
