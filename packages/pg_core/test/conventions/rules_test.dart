// The module rules against check-module-changesets.sh itself: the same files and messages (2.0 spec 006).
@Tags(['conventions'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

final _home = Platform.environment['HOME'] ?? '';
final _skillScript = p.join(
  _home,
  '.claude',
  'skills',
  'postgresql-procedures-views',
  'scripts',
  'check-module-changesets.sh',
);
final _repos = p.normalize(p.join(Directory.current.path, '..', '..', '..'));

/// The script's messages (`<file>: <message>`) for a db/ folder, run on a copy with [script].
Future<Set<String>> scriptMessages(String db, String script, {String? owner}) async {
  final copy = await Directory.systemTemp.createTemp('pg_rules_');
  try {
    await Process.run('cp', ['-r', '$db/.', copy.path]);
    Directory(p.join(copy.path, 'scripts')).createSync(recursive: true);
    File(script).copySync(p.join(copy.path, 'scripts', 'check-module-changesets.sh'));
    final run = await Process.run(
      'bash',
      [p.join(copy.path, 'scripts', 'check-module-changesets.sh')],
      environment: {'MODULE_OWNER_ROLE': ?owner},
    );
    return {
      for (final line in '${run.stdout}${run.stderr}'.split('\n'))
        if (line.startsWith('ERROR: ')) line.substring('ERROR: '.length),
    };
  } finally {
    await copy.delete(recursive: true);
  }
}

/// Our messages in the script's words: the module rules plus the two boundary rules of spec 003.
Set<String> ours(ProjectIndex index, String prefix) => {
  for (final x in index.allProblems)
    if (x.code == 'module-rule') x.message,
  for (final v in index.conventions.violations)
    if (v.problem.code == 'module-boundary')
      "$prefix${v.problem.span.file}: uses tables or internal routines of module '${v.other.name}' - read ${v.other.name}_app views, call ${v.other.name}_app procedures"
    else
      "$prefix${v.problem.span.file}: module '${v.own.name}' (${v.own.number}) uses '${v.other.name}' (${v.other.number}) - only modules with a lower number",
};

void main() {
  test('fixture with every rule broken: the same 41 messages as the skill\'s script', () async {
    final db = p.join(Directory.current.path, 'test', 'fixtures', 'rules');
    final script = await scriptMessages(db, _skillScript, owner: 'rx_owner');
    final index = (await Indexer.open(db)).$1;
    final mine = ours(index, '');
    expect(script.length, 41);
    expect(mine.difference(script), isEmpty, reason: 'only ours');
    expect(script.difference(mine), isEmpty, reason: 'only the script\'s');
  }, skip: File(_skillScript).existsSync() ? false : 'missing $_skillScript');

  test('the owner role is detected from the module files; .pgstudio.json can set it and the actor rule', () async {
    final db = p.join(Directory.current.path, 'test', 'fixtures', 'rules');
    final index = (await Indexer.open(db)).$1;
    expect(index.allProblems.any((x) => x.message.contains("must be 'SET LOCAL ROLE rx_owner;'")), isTrue);
    final copy = Directory.systemTemp.createTempSync('pg_rules_opts_');
    addTearDown(() => copy.deleteSync(recursive: true));
    Process.runSync('cp', ['-r', '$db/.', copy.path]);
    File(p.join(copy.path, '.pgstudio.json'))
        .writeAsStringSync('{"conventions": {"rules": true, "ownerRole": "other_owner", "actorRule": "routines"}}');
    final other = (await Indexer.open(copy.path)).$1;
    expect(other.allProblems.any((x) => x.message.contains("must be 'SET LOCAL ROLE other_owner;'")), isTrue);
    expect(
      other.allProblems.any((x) => x.message.contains('a contract routine starts with platform.require_actor_id()')),
      isTrue,
    );
  });

  test('quick fixes: offered in module object files only, and the rule is satisfied after them', () async {
    final db = p.join(Directory.current.path, 'test', 'fixtures', 'rules');
    final index = (await Indexer.open(db)).$1;
    final fixes = {
      for (final x in index.allProblems)
        if (x.fix != null) '${x.span.file} ${x.fix}',
    };
    expect(fixes, {
      'changelog/modules/10-shop/views/shop_app.bad_view.sql add-reset-role',
      'changelog/modules/10-shop/views/shop_app.bad_view.sql json-to-jsonb',
      'changelog/modules/10-shop/functions/shop_app.bad_fn.sql add-reset-role',
      'changelog/modules/10-shop/functions/shop_app.bad_fn.sql add-set-local-role:rx_owner',
      'changelog/modules/10-shop/procedures/shop_app.no_actor.sql add-reset-role',
    });
    // Dated changesets (deployed) get no fix even for the same kind of rule.
    expect(index.allProblems.where((x) => x.span.file.contains('/2026/') && x.fix != null), isEmpty);

    var view = index.files['changelog/modules/10-shop/views/shop_app.bad_view.sql']!.text;
    view = applyQuickFix(applyQuickFix(view, 'json-to-jsonb'), 'add-reset-role');
    expect(view, contains("'{}'::jsonb AS doc"));
    expect(view.trimRight(), endsWith('RESET ROLE;'));
    var fn = index.files['changelog/modules/10-shop/functions/shop_app.bad_fn.sql']!.text;
    fn = applyQuickFix(fn, 'add-set-local-role:rx_owner');
    expect(fn, contains('--rollback DROP FUNCTION shop_app.bad_fn;\nSET LOCAL ROLE rx_owner;\nDROP FUNCTION'));
    expect(
      applyQuickFix(
        '-- timestamp in a comment\nCREATE TABLE t (a timestamp, b timestamp with time zone, c text);',
        'timestamp-to-timestamptz',
      ),
      '-- timestamp in a comment\nCREATE TABLE t (a timestamptz, b timestamp with time zone, c text);',
    );
  });

  test('off in a folder without the script and without .pgstudio.json', () async {
    final shop = (await Indexer.open(p.join(Directory.current.path, 'test', 'fixtures', 'shop'))).$1;
    expect(shop.allProblems.where((x) => x.code == 'module-rule'), isEmpty);
  });

  group('real folders with their own scripts', () {
    for (final (name, owner) in <(String, String?)>[
      ('ambit.jobtron.app', null),
      ('ambit.wms.app', null),
      ('halycon.app.dev', null),
    ]) {
      final db = p.join(_repos, name, 'db');
      final script = p.join(db, 'scripts', 'check-module-changesets.sh');
      test(
        '$name: the same messages as its check-module-changesets.sh',
        () async {
          final fromScript = await scriptMessages(db, script, owner: owner);
          final index = (await Indexer.open(db)).$1;
          final mine = ours(index, '');
          print('$name: script ${fromScript.length}, editor ${mine.length}: $mine');
          expect(mine, fromScript);
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: File(script).existsSync() ? false : 'missing $script',
      );
    }
  });
}
