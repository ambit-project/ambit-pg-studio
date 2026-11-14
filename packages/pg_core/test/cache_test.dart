import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

final _shop = p.join(Directory.current.path, 'test', 'fixtures', 'shop');

String snapshot(ProjectIndex index) => jsonEncode([
  for (final path in index.order) encodeAnalysis(index.files[path]!),
  index.references.length,
  [for (final x in index.problems) x.toString()],
]);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('pg_cache_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the second open takes every file from the cache and gives the same index', () async {
    final cache = Phase1Cache.at(tmp.path);
    final (fresh, t1) = await Indexer.open(_shop, cache: cache);
    expect(t1.cached, 0);
    final (cached, t2) = await Indexer.open(_shop, cache: cache);
    expect(t2.cached, t2.files);
    expect(snapshot(cached), snapshot(fresh));
    expect(cached.files.values.first.text, isNotEmpty);
    expect(
      Directory(p.join(tmp.path, 'phase1-v$analysisVersion')).listSync().where((e) => e.path.endsWith('.json')).length,
      t1.files,
    );
  });

  test('a changed file is analysed again; other analysis versions are removed', () async {
    final copy = Directory(p.join(tmp.path, 'shop'))..createSync();
    for (final f in Directory(_shop).listSync(recursive: true).whereType<File>()) {
      final target = File(p.join(copy.path, p.relative(f.path, from: _shop)));
      target.parent.createSync(recursive: true);
      f.copySync(target.path);
    }
    final cache = Phase1Cache.at(p.join(tmp.path, 'cache'));
    Directory(p.join(tmp.path, 'cache', 'phase1-v0')).createSync(recursive: true);
    final (_, t1) = await Indexer.open(copy.path, cache: cache);
    expect(Directory(p.join(tmp.path, 'cache', 'phase1-v0')).existsSync(), isFalse);

    const view = 'changelog/modules/10-sales/views/sales_app.order_list.sql';
    final file = File(p.join(copy.path, view));
    file.writeAsStringSync(file.readAsStringSync().replaceAll('sales.customers', 'sales.nope'));
    final (index, t2) = await Indexer.open(copy.path, cache: cache);
    expect(t2.cached, t1.files - 1);
    expect(index.problems.map((x) => x.message), contains('relation sales.nope is not defined in the project'));
  });
}
