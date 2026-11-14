// The real database folders of the neighbouring repositories (read only). Skipped when a folder is missing.
@Tags(['corpus'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

final _repos = p.normalize(p.join(Directory.current.path, '..', '..', '..'));
final _folders = {
  'ambit.jobtron.app/db': p.join(_repos, 'ambit.jobtron.app', 'db'),
  'ambit.wms.app/db': p.join(_repos, 'ambit.wms.app', 'db'),
  'halycon.app.dev/db/changelog': p.join(_repos, 'halycon.app.dev', 'db', 'changelog'),
};

void main() {
  for (final MapEntry(key: name, value: root) in _folders.entries) {
    final skip = Directory(root).existsSync() ? false : 'missing $root';
    test('$name: indexes without an exception or a parse error', () async {
      final (index, timing) = await Indexer.open(root);
      final byCode = <String, int>{};
      for (final problem in index.problems) {
        byCode[problem.code ?? '?'] = (byCode[problem.code ?? '?'] ?? 0) + 1;
      }
      print('$name: $timing; objects ${index.objects.length}, references ${index.references.length}, problems $byCode');
      expect(index.problems.where((x) => x.code == 'internal'), isEmpty);
      expect(
        index.problems.where((x) => x.severity == Severity.error).map((x) => '${x.span.file}: ${x.message}'),
        isEmpty,
      );
      expect(timing.total, lessThan(const Duration(seconds: 5)));
    }, skip: skip);
  }

  final wms = _folders['ambit.wms.app/db']!;
  test('ambit.wms.app/db: orders_app.asn_save and its references', () async {
    final (index, _) = await Indexer.open(wms);
    final asn = index.objects.values.singleWhere((o) => o.key.qualified == 'orders_app.asn_save');
    expect(asn.primary.nameSpan.file, 'changelog/modules/60-orders/procedures/orders_app.asn_save.sql');
    final uses = {
      for (final r in index.referencesFrom(asn.key))
        for (final t in r.targets) (t.qualified, r.kind),
    };
    expect(
      uses,
      containsAll([
        ('platform.require_actor_id', RefKind.call),
        ('platform.require_role', RefKind.call),
        ('orders.purchase_orders', RefKind.read),
        ('orders_app.asn_line_input', RefKind.type),
        ('orders.asns', RefKind.write),
      ]),
    );
    final role = index.objects.values.singleWhere((o) => o.key.qualified == 'platform.require_role');
    final modules = index
        .referencesTo(role.key)
        .map((r) => r.span.file.split('/'))
        .where((s) => s[1] == 'modules')
        .map((s) => s[2])
        .toSet();
    print('platform.require_role: ${index.referencesTo(role.key).length} references in modules $modules');
    expect(modules.length, greaterThan(5));
  }, skip: Directory(wms).existsSync() ? false : 'missing $wms');
}
