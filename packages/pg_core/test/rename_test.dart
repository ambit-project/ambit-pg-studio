import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

final _shop = p.join(Directory.current.path, 'test', 'fixtures', 'shop');
const _view = 'changelog/modules/10-sales/views/sales_app.order_list.sql';
const _save = 'changelog/modules/10-sales/procedures/sales_app.order_save.sql';
const _ddl = 'changelog/2026/1-ddl/20260101-01-sales-create-schemas-and-tables.sql';
const _grants = 'changelog/2026/1-ddl/20260101-03-grants.sql';

Directory copy() {
  final d = Directory.systemTemp.createTempSync('pg_rename_');
  Process.runSync('cp', ['-r', '$_shop/.', d.path]);
  return d;
}

ObjectKey key(ProjectIndex index, String q) => index.objects.values.firstWhere((o) => o.key.qualified == q).key;

void main() {
  late ProjectIndex index;
  late Set<String> deployed;
  setUpAll(() async {
    index = (await Indexer.open(_shop)).$1;
    deployed = index.order.toSet(); // everything is in main
  });

  test('a view: definition, file, changeset id, uses; ALTER VIEW changeset; a deployed GRANT is a warning', () async {
    final plan = planRename(
      index,
      object: key(index, 'sales_app.order_list'),
      newName: 'order_overview',
      inMain: deployed,
      today: '20261115',
    );
    expect(plan.error, isNull);
    expect(plan.renames, {_view: 'changelog/modules/10-sales/views/sales_app.order_overview.sql'});
    expect(plan.newFiles.keys, ['changelog/2026/1-ddl/20261115-01-sales-rename-order-list.sql']);
    expect(plan.newFiles.values.single, contains('ALTER VIEW sales_app.order_list RENAME TO order_overview;'));
    expect(plan.newFiles.values.single, contains('--changeset shop:20261115-01-sales-rename-order-list'));
    expect(plan.warnings.single, startsWith('$_grants:5: grant left as it is (deployed changeset)'));

    final dir = copy();
    addTearDown(() => dir.deleteSync(recursive: true));
    final changed = applyRenamePlan(dir.path, plan);
    expect(changed, containsAll([_view, 'changelog/modules/10-sales/views/sales_app.order_overview.sql']));
    final text = File(p.join(dir.path, 'changelog/modules/10-sales/views/sales_app.order_overview.sql'))
        .readAsStringSync();
    expect(text, contains('--changeset shop:view-sales-app-order-overview runOnChange:true'));
    expect(text, contains('CREATE OR REPLACE VIEW sales_app.order_overview AS'));
    final after = (await Indexer.open(dir.path)).$1;
    expect(after.objects.values.where((o) => o.key.qualified == 'sales_app.order_overview'), hasLength(1));
  });

  test('a table: ALTER TABLE ... RENAME TO and every editable use; the deployed foreign key stays', () {
    final plan = planRename(
      index,
      object: key(index, 'sales.customers'),
      newName: 'clients',
      inMain: deployed,
      today: '20261115',
    );
    expect(plan.newFiles.values.single, contains('ALTER TABLE sales.customers RENAME TO clients;'));
    expect(plan.edits.keys.toSet(), {_save, _view});
    expect(plan.warnings.where((w) => w.startsWith('$_ddl:')), isNotEmpty);
    final dir = copy();
    addTearDown(() => dir.deleteSync(recursive: true));
    applyRenamePlan(dir.path, plan);
    expect(File(p.join(dir.path, _view)).readAsStringSync(), contains('JOIN sales.clients AS c'));
    expect(File(p.join(dir.path, _save)).readAsStringSync(), contains('FROM sales.clients AS c'));
  });

  test('a column: ALTER TABLE ... RENAME COLUMN, uses edited, a view whose output column changes is a warning', () {
    final plan = planRename(
      index,
      object: key(index, 'sales.orders'),
      column: 'note',
      newName: 'remark',
      inMain: deployed,
      today: '20261115',
    );
    expect(plan.newFiles.values.single, contains('ALTER TABLE sales.orders RENAME COLUMN note TO remark;'));
    expect(plan.edits.keys, [_view]);
    expect(plan.warnings.single, contains('view sales_app.order_list: its output column note becomes remark'));
  });

  test('nothing deployed yet: CREATE TABLE is edited, no ALTER changeset', () {
    final plan = planRename(
      index,
      object: key(index, 'sales.customers'),
      newName: 'clients',
      inMain: const {},
      today: '20261115',
    );
    expect(plan.newFiles, isEmpty);
    expect(plan.edits.keys, contains(_ddl));
    expect(plan.warnings, isEmpty);
  });

  test('errors: an invalid name, a name taken, an unsupported kind', () {
    expect(
      planRename(
        index,
        object: key(index, 'sales.orders'),
        newName: 'Bad Name',
        inMain: deployed,
        today: '20261115',
      ).error,
      isNotNull,
    );
    expect(
      planRename(
        index,
        object: key(index, 'sales.orders'),
        newName: 'customers',
        inMain: deployed,
        today: '20261115',
      ).error,
      'sales.customers already exists.',
    );
    final seq = index.objects.values.firstWhere((o) => o.kind == ObjectKind.sequence).key;
    expect(
      planRename(index, object: seq, newName: 'x', inMain: deployed, today: '20261115').error,
      contains('not supported'),
    );
  });
}
