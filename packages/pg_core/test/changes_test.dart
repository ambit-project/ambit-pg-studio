import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

const _view = 'changelog/modules/10-sales/views/sales_app.order_list.sql';
const _ddl = 'changelog/2026/1-ddl/20260101-01-sales-create-schemas-and-tables.sql';
const _new = 'changelog/modules/10-sales/views/sales_app.customer_list.sql';

void git(String dir, List<String> args) {
  final r = Process.runSync('git', ['-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t.invalid', ...args]);
  if (r.exitCode != 0) throw StateError('git $args: ${r.stderr}');
}

void main() {
  test('a branch: changed and added objects, uses, new problems, a changed deployed changeset', () async {
    final repo = Directory.systemTemp.createTempSync('pg_branch_');
    addTearDown(() => repo.deleteSync(recursive: true));
    final db = p.join(repo.path, 'db');
    Directory(db).createSync();
    Process.runSync('cp', ['-r', '${p.join(Directory.current.path, 'test', 'fixtures', 'shop')}/.', db]);
    git(repo.path, ['init', '-q', '-b', 'main']);
    git(repo.path, ['add', '.']);
    git(repo.path, ['commit', '-q', '-m', 'main']);
    git(repo.path, ['checkout', '-q', '-b', 'feature']);
    // A changed view (committed), a new view with a broken reference (untracked), a deployed DDL edited (working tree).
    final view = File(p.join(db, _view));
    view.writeAsStringSync(view.readAsStringSync().replaceFirst('o.note', 'o.note, o.id AS order_id'));
    git(repo.path, ['commit', '-q', '-am', 'view']);
    File(p.join(db, _new)).writeAsStringSync(
      '--liquibase formatted sql\n--changeset shop:v runOnChange:true\n'
      'CREATE VIEW sales_app.customer_list AS SELECT c.id FROM sales.nope AS c;\n',
    );
    final ddl = File(p.join(db, _ddl));
    ddl.writeAsStringSync(ddl.readAsStringSync().replaceFirst('name text NOT NULL', 'name text'));

    final index = (await Indexer.open(db)).$1;
    final r = (await reviewBranch(index))!;
    expect((r.branch, r.base), ('feature', 'main'));
    expect({for (final f in r.files) '${f.status} ${f.path}'}, {'M $_view', 'M $_ddl', 'A $_new'});
    expect({
      for (final o in r.objects) '${o.change} ${o.object.key.qualified}',
    }, containsAll(['changed sales_app.order_list', 'added sales_app.customer_list', 'changed sales.customers']));
    expect(r.newProblems.map((x) => x.message), ['relation sales.nope is not defined in the project']);
    expect(r.warnings.single.$2, startsWith('$_ddl: a deployed changeset was changed'));
  });

  test('outside a repository: no review', () async {
    final dir = Directory.systemTemp.createTempSync('pg_nogit_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, 'a.sql')).writeAsStringSync('CREATE TABLE t (id int);');
    final index = (await Indexer.open(dir.path)).$1;
    expect(await reviewBranch(index), isNull);
  });
}
