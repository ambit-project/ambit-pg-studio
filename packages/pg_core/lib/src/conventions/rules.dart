// The rules of check-module-changesets.sh (skill postgresql-procedures-views) as problems in the editor
// (2.0 spec 006). Same rules, same messages, checked line by line like the script's `grep -P`. The two module boundary
// rules (another module's tables / a higher module) are the semantic ones of conventions.dart (spec 003).
import 'dart:convert';
import 'dart:io';

import '../model.dart';

/// Variants of the script: the skill's (and wms/jobtron) checks `_app` procedures for platform.require_actor_id();
/// halycon's checks all `_app` routines and knows `--no-actor:`.
enum ActorRule { procedures, routines }

final class RuleOptions {
  const RuleOptions({this.ownerRole, this.actorRule, this.enabled});

  /// true/false from `.pgstudio.json`; null: on when the project has db/scripts/check-module-changesets.sh.
  final bool? enabled;

  /// `SET LOCAL ROLE <owner>;` - null: the most frequent one in the module files.
  final String? ownerRole;

  /// null: `routines` when a file has `--no-actor:`, else `procedures`.
  final ActorRule? actorRule;

  /// The `conventions` section of the nearest `.pgstudio.json` in [folder] or above.
  static RuleOptions forFolder(String folder) {
    var dir = Directory(folder).absolute;
    while (true) {
      final file = File('${dir.path}/.pgstudio.json');
      if (file.existsSync()) {
        try {
          final json =
              (jsonDecode(file.readAsStringSync()) as Map<String, Object?>)['conventions'] as Map<String, Object?>?;
          return RuleOptions(
            enabled: json?['rules'] as bool?,
            ownerRole: json?['ownerRole'] as String?,
            actorRule: switch (json?['actorRule']) {
              'routines' => ActorRule.routines,
              'procedures' => ActorRule.procedures,
              _ => null,
            },
          );
        } on Object {
          return const RuleOptions();
        }
      }
      final parent = dir.parent;
      if (parent.path == dir.path) return const RuleOptions();
      dir = parent;
    }
  }
}

final _objectRe = RegExp(
  r'^changelog/modules/([0-9]{2})-([a-z][a-z0-9_]*)/(views|functions|procedures)/([a-z][a-z0-9_]*)\.([a-z][a-z0-9_]*)\.sql$',
);
final _datedRe = RegExp(r'^changelog/[0-9]{4}/(1-ddl|2-data)/[0-9]{8}-[0-9]{2}-([a-z][a-z0-9_]*)-[a-z0-9-]+\.sql$');
final _moduleFolderRe = RegExp(r'^changelog/modules/([^/]+)/');
final _setLocalRole = RegExp(r'^SET LOCAL ROLE (\S+);$');

/// One file as the script sees it: its path from the db/ folder (`changelog/...`) and its text.
typedef RuleFile = ({String scriptPath, String path, String text});

/// Problems of the module rules for [files] (paths relative to the opened folder). [prefix] turns a path into the
/// script's (`changelog/` when the opened folder is db/changelog). [changelogMd]: the text of db/CHANGELOG.md, or null
/// when the folder has none (that rule is then not checked).
List<Problem> moduleRules(List<RuleFile> files, {String? changelogMd, RuleOptions options = const RuleOptions()}) {
  final problems = <Problem>[];
  final byScript = {for (final f in files) f.scriptPath: f};
  final sorted = byScript.keys.toList()..sort();

  // Modules: changelog/modules/<nn>-<module>/.
  final order = <String, String>{};
  final badFolders = <String>{};
  for (final path in sorted) {
    final m = _moduleFolderRe.firstMatch(path);
    if (m == null) continue;
    final folder = RegExp(r'^([0-9]{2})-([a-z][a-z0-9_]*)$').firstMatch(m.group(1)!);
    if (folder == null) {
      if (!badFolders.add(m.group(1)!)) continue; // the script reports a folder once
      _fail(problems, byScript[path]!, 0, 'changelog/modules/${m.group(1)}/: module folders are <nn>-<module>');
      continue;
    }
    order[folder.group(2)!] = folder.group(1)!;
  }
  if (order.isEmpty) return problems;

  final objectFiles = [
    for (final p in sorted)
      if (p.startsWith('changelog/modules/')) p,
  ];
  final owner = options.ownerRole ?? _detectOwner([for (final p in objectFiles) byScript[p]!.text]);
  if (owner == null) return problems;
  final actorRule =
      options.actorRule ??
      (files.any((f) => RegExp(r'^--no-actor: ', multiLine: true).hasMatch(f.text))
          ? ActorRule.routines
          : ActorRule.procedures);

  for (final path in objectFiles) {
    final f = byScript[path]!;
    final m = _objectRe.firstMatch(path);
    if (m == null) {
      _fail(
        problems,
        f,
        0,
        '$path: path must be changelog/modules/<nn>-<module>/{views|functions|procedures}/<schema>.<name>.sql',
      );
      continue;
    }
    final module = m.group(2)!;
    final kind = m.group(3)!;
    final schema = m.group(4)!;
    final name = m.group(5)!;
    final singular = kind.substring(0, kind.length - 1);
    final lines = f.text.split('\n');
    final header = lines.firstWhere((l) => l.startsWith('--changeset '), orElse: () => '');
    final id = RegExp(r'^--changeset [^:]+:([^ ]+)').firstMatch(header)?.group(1) ?? header;
    final c = _Code(f);
    _common(problems, f, c, changelogMd);

    if (schema != '${module}_app' && schema != '${module}_internal') {
      _fail(problems, f, 0, '$path: schema must be ${module}_app or ${module}_internal');
    }
    final expectedId = '$singular-${schema.replaceAll('_', '-')}-${name.replaceAll('_', '-')}';
    if (id != expectedId) _fail(problems, f, f.text.indexOf(header), "$path: changeset id '$id' must be '$expectedId'");
    if (!header.contains('runOnChange:true')) {
      _fail(problems, f, f.text.indexOf(header), '$path: objects need runOnChange:true');
    }
    if (!header.contains('splitStatements:false')) {
      _fail(problems, f, f.text.indexOf(header), '$path: objects need splitStatements:false (bodies have semicolons)');
    }
    final rollback = RegExp(r'^--rollback', multiLine: true).firstMatch(f.text);
    if (rollback != null) {
      _fail(problems, f, rollback.start, '$path: no --rollback in objects - the file itself is the state');
    }

    final nonBlank = [
      for (final l in c.lines)
        if (l.$1.trim().isNotEmpty) l,
    ];
    final first = nonBlank.isEmpty ? '' : nonBlank.first.$1;
    final last = nonBlank.isEmpty ? '' : nonBlank.last.$1;
    if (first != 'SET LOCAL ROLE $owner;') {
      _fail(
        problems,
        f,
        nonBlank.isEmpty ? 0 : nonBlank.first.$2,
        "$path: first statement must be 'SET LOCAL ROLE $owner;' - the owner must not bypass row-level security",
      );
    }
    if (last != 'RESET ROLE;') {
      _fail(
        problems,
        f,
        nonBlank.isEmpty ? 0 : nonBlank.last.$2,
        "$path: last statement must be 'RESET ROLE;' (Liquibase writes its changelog row as the session user)",
      );
    }
    c.any(
      problems,
      r'\bSELECT\s+(DISTINCT\s+(ON\s*\([^)]*\)\s*)?)?\*|\b[a-z0-9_]+\.\*',
      '$path: no SELECT * - list columns, a table change must not change the contract silently',
    );

    switch (kind) {
      case 'views':
        c.any(
          problems,
          r'(?<!SELECT )\bplatform\.actor_[a-z_]+\(',
          '$path: platform.actor_*() in a view outside (SELECT ...) - evaluated per row',
        );
        c.none(
          problems,
          '^CREATE OR REPLACE VIEW ${RegExp.escape(schema)}\\.${RegExp.escape(name)} AS\\b',
          "$path: must contain 'CREATE OR REPLACE VIEW $schema.$name AS' (keeps grants and dependent views)",
        );
        c.any(
          problems,
          r'\bDROP\s+VIEW\b',
          '$path: no DROP VIEW - add columns at the end; a breaking change is a new view (${name}_v2)',
        );
      case 'functions':
        c.none(
          problems,
          '^CREATE OR REPLACE FUNCTION ${RegExp.escape(schema)}\\.${RegExp.escape(name)}\\(',
          "$path: must contain 'CREATE OR REPLACE FUNCTION $schema.$name('",
        );
        c.none(problems, r'\bRETURNS\s+TABLE\b', '$path: a read function RETURNS TABLE (...)');
        c.none(
          problems,
          r'^\s*(STABLE|IMMUTABLE)\s*$',
          '$path: a read function is STABLE (it runs in a READ ONLY transaction)',
        );
      case 'procedures':
        c.none(
          problems,
          '^CREATE OR REPLACE PROCEDURE ${RegExp.escape(schema)}\\.${RegExp.escape(name)}\\(',
          "$path: must contain 'CREATE OR REPLACE PROCEDURE $schema.$name('",
        );
        c.any(
          problems,
          r'\b(COMMIT|ROLLBACK)\s*;',
          '$path: no transaction control - the API request is the transaction',
        );
        c.any(
          problems,
          r'\bEXCEPTION\s+WHEN\b',
          '$path: no EXCEPTION block - it hides errors and costs a subtransaction per call',
        );
        if (actorRule == ActorRule.procedures && schema.endsWith('_app')) {
          c.noneFixed(
            problems,
            'platform.require_actor_id()',
            '$path: a contract procedure starts with v_actor_id uuid := platform.require_actor_id()',
          );
        }
    }
    if (actorRule == ActorRule.routines) {
      final noActor = RegExp(r'^--no-actor: ', multiLine: true).firstMatch(f.text);
      if (kind != 'views' && schema.endsWith('_app') && noActor == null) {
        c.noneFixed(
          problems,
          'platform.require_actor_id()',
          '$path: a contract routine starts with platform.require_actor_id()',
        );
      }
      if (noActor != null) {
        if (!schema.endsWith('_app')) _fail(problems, f, noActor.start, '$path: --no-actor is for contract routines');
        c.none(
          problems,
          '\\bp_[a-z_]*_hash\\b|\\b${RegExp.escape(module)}_internal\\.authorize_',
          '$path: --no-actor without a secret - take p_<x>_hash or call ${module}_internal.authorize_*',
          caseSensitive: true,
        );
        c.anyFixed(
          problems,
          'platform.require_actor_id()',
          '$path: --no-actor and platform.require_actor_id() - one or the other',
        );
      }
    }
    if (kind != 'views') {
      c.none(problems, r'^\s*SECURITY DEFINER\s*$', '$path: SECURITY DEFINER - the API role has no rights on tables');
      c.none(
        problems,
        r'^\s*SET search_path = pg_catalog, pg_temp\s*$',
        "$path: SET search_path = pg_catalog, pg_temp (a SECURITY DEFINER routine never trusts the caller's search_path)",
      );
      for (final d in c.matches(r'\bDROP\s+(FUNCTION|PROCEDURE|ROUTINE)\s+IF\s+EXISTS\s+([a-z0-9_.]+)', group: 2)) {
        if (d.$1 != '$schema.$name') {
          _fail(problems, f, d.$2, "$path: DROP only for an old signature of $schema.$name, not '${d.$1}'");
        }
      }
    }
  }

  // Dated changesets: changelog/<yyyy>/(1-ddl|2-data)/<yyyymmdd>-<nn>-<module>-<description>.sql, in path order.
  final rls = <String>{};
  for (final path in sorted.where((p) => !p.startsWith('changelog/modules/'))) {
    final m = _datedRe.firstMatch(path);
    if (m == null) continue;
    final f = byScript[path]!;
    final c = _Code(f);
    final module = m.group(2)!;
    if (rls.isNotEmpty && c.containsFixed('SET LOCAL ROLE $owner;')) {
      for (final table in rls) {
        final t = RegExp.escape(table);
        if (!c.has('\\b(INSERT\\s+INTO|UPDATE|DELETE\\s+FROM)\\s+$t\\b')) continue;
        if (c.has('\\bALTER\\s+TABLE\\s+$t\\s+NO\\s+FORCE\\s+ROW\\s+LEVEL\\s+SECURITY\\b')) {
          c.none(
            problems,
            '\\bALTER\\s+TABLE\\s+$t\\s+FORCE\\s+ROW\\s+LEVEL\\s+SECURITY\\b',
            '$path: NO FORCE ROW LEVEL SECURITY on $table without FORCE again before RESET ROLE',
          );
        } else if (!c.has(r"set_config\(\s*'[a-z_]+\.actor_id'")) {
          _fail(
            problems,
            f,
            0,
            '$path: writes $table (row-level security) as $owner without an actor - set <app>.actor_id to a person of the client, or lift FORCE for the transaction',
          );
        }
      }
    }
    for (final t in c.matches(
      r'\bALTER\s+TABLE\s+([a-z0-9_]+\.[a-z0-9_]+)(?=\s+ENABLE\s+ROW\s+LEVEL\s+SECURITY)',
      group: 1,
    )) {
      rls.add(t.$1.toLowerCase());
    }
    if (!order.containsKey(module)) continue;
    _common(problems, f, c, changelogMd);
    if (c.has(r'\bCREATE\s+(TABLE|TYPE|FUNCTION|POLICY|INDEX|TRIGGER|VIEW|PROCEDURE)\b|\bINSERT\s+INTO\b')) {
      c.noneFixed(
        problems,
        'SET LOCAL ROLE $owner;',
        '$path: create module objects as $owner (SET LOCAL ROLE $owner; ... RESET ROLE;)',
      );
    }
    if (c.has(r'\bCREATE\s+SCHEMA\b') &&
        !c.has('\\bCREATE\\s+SCHEMA\\s+[a-z0-9_]+\\s+AUTHORIZATION\\s+${RegExp.escape(owner)}\\b')) {
      c.any(problems, r'\bCREATE\s+SCHEMA\b', '$path: CREATE SCHEMA ... AUTHORIZATION $owner');
    }
    c.any(
      problems,
      r'\bCREATE\s+(OR\s+REPLACE\s+)?(VIEW|PROCEDURE)\b',
      '$path: views and procedures live in changelog/modules/<nn>-<module>/ with runOnChange',
    );
    if (c.has(r'\bENABLE\s+ROW\s+LEVEL\s+SECURITY\b')) {
      c.none(
        problems,
        r'\bFORCE\s+ROW\s+LEVEL\s+SECURITY\b',
        '$path: FORCE ROW LEVEL SECURITY - views and procedures run as the table owner',
      );
    }
  }
  return problems;
}

String? _detectOwner(List<String> texts) {
  final counts = <String, int>{};
  for (final t in texts) {
    for (final line in t.split('\n')) {
      final m = _setLocalRole.firstMatch(line.trim());
      if (m != null) counts[m.group(1)!] = (counts[m.group(1)!] ?? 0) + 1;
    }
  }
  if (counts.isEmpty) return null;
  return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
}

void _common(List<Problem> problems, RuleFile f, _Code c, String? changelogMd) {
  final path = f.scriptPath;
  if (f.text.split('\n').first != '--liquibase formatted sql') {
    _fail(problems, f, 0, "$path: first line must be '--liquibase formatted sql'");
  }
  if (RegExp(r'^--changeset ', multiLine: true).allMatches(f.text).length != 1) {
    _fail(problems, f, 0, '$path: exactly one changeset per file');
  }
  if (!RegExp(r'^--comment: ', multiLine: true).hasMatch(f.text)) {
    _fail(problems, f, 0, "$path: no '--comment:' - say why the change exists");
  }
  final short = path.substring('changelog/'.length);
  if (changelogMd != null && !changelogMd.contains(short)) {
    _fail(problems, f, 0, "$path: not described in CHANGELOG.md (add an entry with '$short')");
  }
  c.any(
    problems,
    r'(?<!::)\btimestamp\b(?!\s*tz)(?!\s+with\s+time\s+zone)',
    '$path: timestamp without time zone - use timestamptz (a ::timestamp cast for AT TIME ZONE is fine)',
  );
  c.any(
    problems,
    r'\b(money|real|double\s+precision|float[48]?|smallserial|serial|bigserial)\b',
    '$path: type not allowed (money, real, float, double precision, serial) - references/tables.md',
  );
  c.any(problems, r'\bjson\b(?!b)', '$path: json - use jsonb');
  for (final code in c.matches(r"ERRCODE\s*=\s*'([^']+)", group: 1)) {
    if (!RegExp(r'^(U0001|U1[0-9]{3})$').hasMatch(code.$1)) {
      _fail(
        problems,
        f,
        code.$2,
        "$path: ERRCODE '${code.$1}' outside the catalog (U0001, U1000-U1999) - references/procedures.md",
      );
    }
  }
  if (c.has(r'CREATE POLICY')) {
    c.any(
      problems,
      r'\bsession_user\b',
      '$path: a policy tests session_user - work outside the API runs as BYPASSRLS, with an actor or with FORCE lifted for its transaction',
    );
    c.any(
      problems,
      r'(?<!SELECT )\bplatform\.actor_[a-z_]+\(',
      '$path: platform.actor_*() in a policy outside (SELECT ...) - evaluated per row, not indexable',
    );
  }
}

void _fail(List<Problem> problems, RuleFile f, int offset, String message) {
  final at = offset < 0 ? 0 : offset;
  // Quick fixes only in module object files (runOnChange): a dated changeset is deployed, an edit changes its checksum.
  String? fix;
  if (f.scriptPath.startsWith('changelog/modules/')) {
    if (message.contains("last statement must be 'RESET ROLE;'")) fix = 'add-reset-role';
    if (message.contains(': json - use jsonb')) fix = 'json-to-jsonb';
    if (message.contains(': timestamp without time zone')) fix = 'timestamp-to-timestamptz';
    final role = RegExp(r"first statement must be 'SET LOCAL ROLE (\S+);'").firstMatch(message);
    if (role != null) fix = 'add-set-local-role:${role.group(1)}';
  }
  problems.add(Problem(Severity.warning, message, SourceSpan(f.path, at, at), code: 'module-rule', fix: fix));
}

/// The title of a quick fix for the UI.
String quickFixTitle(String fix) => switch (fix) {
  'add-reset-role' => 'Add RESET ROLE; at the end',
  'json-to-jsonb' => 'Use jsonb instead of json',
  'timestamp-to-timestamptz' => 'Use timestamptz instead of timestamp',
  _ when fix.startsWith('add-set-local-role:') =>
    'Start with SET LOCAL ROLE ${fix.substring('add-set-local-role:'.length)};',
  _ => fix,
};

/// Applies [fix] to [text]; comment lines are never changed (the rules ignore them too).
String applyQuickFix(String text, String fix) {
  String onCode(String Function(String line) change) =>
      [for (final line in text.split('\n')) RegExp(r'^\s*--').hasMatch(line) ? line : change(line)].join('\n');
  switch (fix) {
    case 'add-reset-role':
      return '${text.trimRight()}\nRESET ROLE;\n';
    case 'json-to-jsonb':
      return onCode((l) => l.replaceAll(RegExp(r'\bjson\b(?!b)', caseSensitive: false), 'jsonb'));
    case 'timestamp-to-timestamptz':
      return onCode(
        (l) => l.replaceAll(
          RegExp(r'(?<!::)\btimestamp\b(?!\s*tz)(?!\s+with\s+time\s+zone)', caseSensitive: false),
          'timestamptz',
        ),
      );
    default:
      if (fix.startsWith('add-set-local-role:')) {
        final role = fix.substring('add-set-local-role:'.length);
        final lines = text.split('\n');
        final first = lines.indexWhere((l) => l.trim().isNotEmpty && !RegExp(r'^\s*--').hasMatch(l));
        lines.insert(first < 0 ? lines.length : first, 'SET LOCAL ROLE $role;');
        return lines.join('\n');
      }
      return text;
  }
}

/// The lines of a file without the comment lines (the script's `grep -v '^[[:space:]]*--'`), each with its offset.
final class _Code {
  _Code(this.file) {
    var offset = 0;
    for (final line in file.text.split('\n')) {
      if (!RegExp(r'^\s*--').hasMatch(line)) lines.add((line, offset));
      offset += line.length + 1;
    }
  }

  final RuleFile file;
  final List<(String, int)> lines = [];

  bool has(String pattern, {bool caseSensitive = false}) => _first(pattern, caseSensitive) != null;

  bool containsFixed(String s) => lines.any((l) => l.$1.contains(s));

  int? _first(String pattern, bool caseSensitive) {
    final re = RegExp(pattern, caseSensitive: caseSensitive);
    for (final l in lines) {
      final m = re.firstMatch(l.$1);
      if (m != null) return l.$2 + m.start;
    }
    return null;
  }

  /// A problem at the first line matching [pattern].
  void any(List<Problem> problems, String pattern, String message, {bool caseSensitive = false}) {
    final at = _first(pattern, caseSensitive);
    if (at != null) _fail(problems, file, at, message);
  }

  /// A problem when no line matches [pattern].
  void none(List<Problem> problems, String pattern, String message, {bool caseSensitive = false}) {
    if (_first(pattern, caseSensitive) == null) _fail(problems, file, 0, message);
  }

  void anyFixed(List<Problem> problems, String s, String message) {
    final l = lines.where((l) => l.$1.contains(s)).firstOrNull;
    if (l != null) _fail(problems, file, l.$2 + l.$1.indexOf(s), message);
  }

  void noneFixed(List<Problem> problems, String s, String message) {
    if (!containsFixed(s)) _fail(problems, file, 0, message);
  }

  /// Every match of [group] on every line, with its offset.
  List<(String, int)> matches(String pattern, {required int group, bool caseSensitive = false}) {
    final re = RegExp(pattern, caseSensitive: caseSensitive);
    return [
      for (final l in lines)
        for (final m in re.allMatches(l.$1))
          if (m.group(group) != null) (m.group(group)!, l.$2 + m.start),
    ];
  }
}
