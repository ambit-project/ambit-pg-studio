// New files from templates pass the project's own check-module-changesets.sh (2.0 spec 004).
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

final _repos = p.normalize(p.join(Directory.current.path, '..', '..', '..'));

void main() {
  for (final (name, module) in [('ambit.wms.app', 'orders'), ('ambit.jobtron.app', 'scheduling')]) {
    final db = p.join(_repos, name, 'db');
    test(
      '$name: a procedure, a function and a view (_app and _internal) and two dated changesets pass its script',
      () async {
        final copy = Directory.systemTemp.createTempSync('pg_tpl_');
        addTearDown(() => copy.deleteSync(recursive: true));
        Process.runSync('cp', ['-r', '$db/.', copy.path]);
        final index = (await Indexer.open(copy.path)).$1;
        final made = <String>[];
        for (final (kind, internal, n) in [
          (NewKind.procedure, false, 'pg_studio_save'),
          (NewKind.procedure, true, 'pg_studio_check'),
          (NewKind.function, false, 'pg_studio_list'),
          (NewKind.view, false, 'pg_studio_overview'),
          (NewKind.ddlChangeset, false, 'pg_studio_table'),
          (NewKind.dataChangeset, false, 'pg_studio_seed'),
        ]) {
          final r = newFromTemplate(index, kind: kind, module: module, name: n, internal: internal, today: '20991231');
          expect(r.error, isNull);
          createNewFile(copy.path, r.file!);
          made.add(r.file!.path);
        }
        final run = Process.runSync('bash', [p.join(copy.path, 'scripts', 'check-module-changesets.sh')]);
        final errors = '${run.stdout}${run.stderr}'.split('\n').where((l) => l.startsWith('ERROR: ')).toList();
        print('$name: ${made.length} files, script exit ${run.exitCode}, errors: $errors');
        expect(errors, isEmpty);
        expect(run.exitCode, 0);
        // And the editor agrees: no module rule problem in the new files.
        final after = (await Indexer.open(copy.path)).$1;
        expect(after.allProblems.where((x) => made.contains(x.span.file)), isEmpty);
        expect(made.where((m) => m.contains('/2099/1-ddl/20991231-01-')), hasLength(1));
      },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: Directory(db).existsSync() ? false : 'missing $db',
    );
  }

  test('errors: unknown module, bad name, existing file', () async {
    final index = (await Indexer.open(p.join(Directory.current.path, 'test', 'fixtures', 'modules'))).$1;
    expect(
      newFromTemplate(index, kind: NewKind.view, module: 'nope', name: 'x', today: '20991231').error,
      contains('No module'),
    );
    expect(
      newFromTemplate(index, kind: NewKind.view, module: 'orders', name: 'Bad', today: '20991231').error,
      isNotNull,
    );
    expect(
      newFromTemplate(index, kind: NewKind.procedure, module: 'orders', name: 'order_save', today: '20991231').error,
      contains('already exists'),
    );
  });
}
