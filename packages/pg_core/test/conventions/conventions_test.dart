@Tags(['conventions'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

final _fixture = p.join(Directory.current.path, 'test', 'fixtures', 'modules');
final _repos = p.normalize(p.join(Directory.current.path, '..', '..', '..'));
final _script = p.join(_repos, 'ambit.wms.app', 'db', 'scripts', 'check-module-changesets.sh');
const _save = 'changelog/modules/20-orders/procedures/orders_app.order_save.sql';
const _ordersDdl = 'changelog/2026/1-ddl/20260101-03-orders-create-tables.sql';

/// (file, other module) pairs the app's own script reports for the module rules, run on a temporary copy of [root].
Future<Set<(String, String)>> scriptViolations(String root, String owner) async {
  final copy = await Directory.systemTemp.createTemp('pg_core_conventions_');
  try {
    await Process.run('cp', ['-r', '$root/.', copy.path]);
    Directory(p.join(copy.path, 'scripts')).createSync(recursive: true);
    File(_script).copySync(p.join(copy.path, 'scripts', 'check-module-changesets.sh'));
    File(p.join(copy.path, 'CHANGELOG.md')).createSync();
    final run = await Process.run(
      'bash',
      [p.join(copy.path, 'scripts', 'check-module-changesets.sh')],
      environment: {'MODULE_OWNER_ROLE': owner},
    );
    final pairs = <(String, String)>{};
    for (final line in '${run.stdout}${run.stderr}'.split('\n')) {
      final a = RegExp(r"^ERROR: (\S+): uses tables or internal routines of module '([a-z0-9_]+)'").firstMatch(line);
      final b = RegExp(r"^ERROR: (\S+): module '[a-z0-9_]+' \(\d+\) uses '([a-z0-9_]+)'").firstMatch(line);
      final m = a ?? b;
      if (m != null) pairs.add((m.group(1)!, m.group(2)!));
    }
    return pairs;
  } finally {
    await copy.delete(recursive: true);
  }
}

Set<(String, String)> ours(ProjectIndex index) => {
  for (final v in index.conventions.violations) (v.problem.span.file, v.other.name),
};

void main() {
  late ProjectIndex index;
  setUpAll(() async {
    index = (await Indexer.open(_fixture)).$1;
  });

  test('modules come from changelog/modules/<nn>-<module> in number order, files belong to them', () {
    final c = index.conventions;
    expect(c.modules.map((m) => m.label), ['00-platform', '10-partners', '20-orders', '30-billing']);
    expect(c.moduleOfFile(_save)!.name, 'orders');
    expect(c.moduleOfFile(_ordersDdl)!.name, 'orders');
    expect(c.moduleOfFile('changelog/2026/1-ddl/20260101-01-platform-create-schemas.sql')!.name, 'platform');
    expect(c.moduleOfSchema('partners_internal')!.name, 'partners');
  });

  test(
    'violations: tables and _internal of another module, a higher module; not _app, FK down, platform functions',
    () {
      final found = [
        for (final v in index.conventions.violations)
          (
            v.problem.code,
            v.schema,
            index.files[v.problem.span.file]!.lineColumn(v.problem.span.start).$1 + 1,
            p.basename(v.problem.span.file),
          ),
      ];
      expect(
        found,
        unorderedEquals([
          ('module-order', 'billing', 9, p.basename(_ordersDdl)),
          ('module-boundary', 'partners', 16, p.basename(_save)),
          ('module-boundary', 'partners_internal', 17, p.basename(_save)),
          ('module-boundary', 'platform', 18, p.basename(_save)),
          ('module-order', 'billing_app', 19, p.basename(_save)),
        ]),
      );
      expect(index.allProblems.where((x) => x.code == 'module-order' || x.code == 'module-boundary'), hasLength(5));
    },
  );

  test('the same files and modules as check-module-changesets.sh', () async {
    final script = await scriptViolations(_fixture, 'fx_owner');
    expect(script, isNotEmpty);
    expect(ours(index), script);
  }, skip: File(_script).existsSync() ? false : 'missing $_script');

  test('the contract of a module: its _app objects with signatures', () {
    final c = index.conventions;
    final orders = c.modules.singleWhere((m) => m.name == 'orders');
    expect(c.contractOf(orders, index).map((o) => o.signature), [
      'orders_app.order_cancel(p_id uuid)',
      'orders_app.order_save(p_id uuid, p_customer_id uuid)',
    ]);
  });

  test('error codes with their places and descriptions', () {
    final u1101 = index.conventions.errorCodes['U1101']!;
    expect(u1101.map((e) => (e.from!.qualified, e.description)), [
      ('partners_internal.customer_check', 'U1101 (404): klient nie istnieje.'),
      ('orders_app.order_save', 'U1101 (404): zamówienie nie istnieje.'),
    ]);
    expect(index.allProblems.where((x) => x.code == 'errcode-status'), isEmpty);
  });

  test('the HTTP status of a description; one code with two statuses is a warning', () {
    expect(Conventions.httpStatusOf('U1012', 'Brak id = wspólny kod U1012 (400).'), '400');
    expect(Conventions.httpStatusOf('U1015', 'opcjonalny, do 100 znaków. U1015 = 400.'), '400');
    expect(Conventions.httpStatusOf('U1431', 'U1431 (404): brak dokumentu'), '404');
    expect(Conventions.httpStatusOf('U1005', 'inna wartość = U1005.'), isNull);
    const body = r'''CREATE PROCEDURE m_app.p() LANGUAGE plpgsql AS $$
BEGIN
  -- U1101 (404): nie ma.
  RAISE EXCEPTION 'a' USING ERRCODE = 'U1101';
  -- U1101 (409): konflikt.
  RAISE EXCEPTION 'b' USING ERRCODE = 'U1101';
END $$;''';
    final file = analyzeFile('changelog/modules/10-m/procedures/m_app.p.sql', body);
    final index = ProjectIndex.link('/tmp', {file.path: file}, [file.path]);
    final warnings = index.allProblems.where((x) => x.code == 'errcode-status').toList();
    expect(warnings, hasLength(2));
    expect(warnings.first.message, contains('404, 409'));
  });

  test('the changelog folder itself can be opened (paths without changelog/)', () async {
    final inner = (await Indexer.open(p.join(_fixture, 'changelog'))).$1;
    expect(inner.conventions.modules.map((m) => m.label), ['00-platform', '10-partners', '20-orders', '30-billing']);
    expect(inner.conventions.violations, hasLength(5));
  });

  test('a folder without modules has no conventions and no convention problems', () async {
    final shop = (await Indexer.open(p.join(Directory.current.path, 'test', 'fixtures', 'shop'))).$1;
    expect(shop.conventions.modules.map((m) => m.name), ['sales']);
    final plain = analyzeFile('a.sql', 'CREATE TABLE t (id int);');
    final index = ProjectIndex.link('/tmp', {'a.sql': plain}, ['a.sql']);
    expect(index.conventions.applies, isFalse);
    expect(index.conventions.problems, isEmpty);
  });

  group('real folders', () {
    final folders = {
      'ambit.jobtron.app': ('jobtron_owner', p.join(_repos, 'ambit.jobtron.app', 'db')),
      'ambit.wms.app': ('stocktron_owner', p.join(_repos, 'ambit.wms.app', 'db')),
      'halycon.app.dev': (r'${role_prefix}_owner', p.join(_repos, 'halycon.app.dev', 'db')),
    };
    for (final MapEntry(key: name, value: (owner, root)) in folders.entries) {
      test(
        '$name: the same violations as its check-module-changesets.sh; U-codes listed',
        () async {
          final index = (await Indexer.open(root)).$1;
          final script = await scriptViolations(root, owner);
          final mine = ours(index);
          final codes = index.conventions.errorCodes;
          final statuses = index.allProblems.where((x) => x.code == 'errcode-status').map((x) => x.message).toSet();
          print(
            '$name: modules ${index.conventions.modules.length}, violations ${mine.length} (script ${script.length}), '
            'error codes ${codes.length}, places ${codes.values.fold(0, (n, l) => n + l.length)}, '
            'codes with different HTTP statuses: ${statuses.length} $statuses',
          );
          expect(mine, script);
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: Directory(root).existsSync() ? false : 'missing $root',
      );
    }

    test('ambit.wms.app: U1445 is raised in orders_app.asn_save', () async {
      final index = (await Indexer.open(folders['ambit.wms.app']!.$2)).$1;
      final places = index.conventions.errorCodes['U1445']!;
      final asn = places
          .where((e) => e.span.file == 'changelog/modules/60-orders/procedures/orders_app.asn_save.sql')
          .toList();
      expect(asn, isNotEmpty);
      expect(asn.first.description, startsWith('U1445 (404)'));
    }, skip: Directory(folders['ambit.wms.app']!.$2).existsSync() ? false : 'missing');
  });
}
