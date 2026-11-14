// Conventions of our stack (D5), the same rules as db/scripts/check-module-changesets.sh of the apps:
// modules changelog/modules/<nn>-<module>/ own the schemas <module>, <module>_app (the contract) and
// <module>_internal; a module uses only the _app objects of modules with a lower number (and platform.<function>(),
// and foreign keys to tables of lower modules). ERRCODE values are listed with their descriptions.
import 'dart:io';

import 'package:path/path.dart' as p;

import '../index/project_index.dart';
import '../model.dart';
import 'rules.dart';

// The folder opened may be db/ or db/changelog/, so `changelog/` is optional.
final _moduleFolder = RegExp(r'(?:^|/)modules/(\d{2})-([a-z][a-z0-9_]*)/');
final _datedChangeset = RegExp(r'(?:^|/)\d{4}/(?:1-ddl|2-data)/\d{8}-\d{2}-([a-z][a-z0-9_]*)-[a-z0-9-]+\.sql$');

final class ModuleInfo {
  const ModuleInfo(this.number, this.name, this.folder);

  /// `60` for `60-orders`.
  final String number;
  final String name;

  /// The folder path relative to the project root, e.g. `changelog/modules/60-orders`.
  final String folder;

  String get label => '$number-$name';

  Set<String> get schemas => {name, '${name}_app', '${name}_internal'};
}

/// A use across module boundaries that the rules forbid.
final class ModuleViolation {
  const ModuleViolation(this.own, this.other, this.schema, this.problem);

  final ModuleInfo own;
  final ModuleInfo other;
  final String schema;
  final Problem problem;
}

final class Conventions {
  Conventions._(
    this.modules,
    this.violations,
    this.problems,
    this.errorCodes,
    this._moduleOfFile,
    this._moduleOfSchema,
  );

  /// Modules by number order; empty when the folder does not follow the convention.
  final List<ModuleInfo> modules;
  final List<ModuleViolation> violations;
  final List<Problem> problems;

  /// ERRCODE values with every place they are raised, by code.
  final Map<String, List<ErrorCodeUse>> errorCodes;
  final Map<String, ModuleInfo> _moduleOfFile;
  final Map<String, ModuleInfo> _moduleOfSchema;

  bool get applies => modules.isNotEmpty;

  /// The module a file belongs to (its folder, or a dated changeset named after it).
  ModuleInfo? moduleOfFile(String path) => _moduleOfFile[path];

  ModuleInfo? moduleOfSchema(String schema) => _moduleOfSchema[schema];

  /// The contract of a module: objects in `<module>_app`, sorted by name.
  List<DbObject> contractOf(ModuleInfo module, ProjectIndex index) {
    final schema = '${module.name}_app';
    return index.objects.values.where((o) => o.key.schema == schema && o.isDefinedHere).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
  }

  static Conventions of(ProjectIndex index) {
    final byName = <String, ModuleInfo>{};
    for (final path in index.order) {
      final m = _moduleFolder.firstMatch(path);
      if (m == null) continue;
      final folder = path.substring(0, m.end - 1);
      byName.putIfAbsent(m.group(2)!, () => ModuleInfo(m.group(1)!, m.group(2)!, folder));
    }
    final modules = byName.values.toList()..sort((a, b) => a.number.compareTo(b.number));
    final moduleOfSchema = {
      for (final m in modules)
        for (final s in m.schemas) s: m,
    };

    final moduleOfFile = <String, ModuleInfo>{};
    for (final path in index.order) {
      final folder = _moduleFolder.firstMatch(path);
      if (folder != null) {
        moduleOfFile[path] = byName[folder.group(2)!]!;
        continue;
      }
      final dated = _datedChangeset.firstMatch(path);
      if (dated != null && byName.containsKey(dated.group(1))) moduleOfFile[path] = byName[dated.group(1)]!;
    }

    final violations = <ModuleViolation>[];
    if (modules.isNotEmpty) {
      for (final path in index.order) {
        final own = moduleOfFile[path];
        final file = index.files[path];
        if (own == null || file == null) continue;
        for (final r in file.references) {
          final schema = r.name.schema;
          if (schema == null) continue;
          final v = _check(own, schema, r.space, r.kind, r.span, moduleOfSchema);
          if (v != null) violations.add(v);
        }
        for (final d in file.definitions) {
          final schema = d.key.schema;
          if (schema.isEmpty) continue;
          final v = _check(own, schema, d.key.space, RefKind.alter, d.nameSpan, moduleOfSchema);
          if (v != null) violations.add(v);
        }
      }
    }

    final problems = [for (final v in violations) v.problem];
    if (modules.isNotEmpty) problems.addAll(_scriptRules(index));
    final errorCodes = <String, List<ErrorCodeUse>>{};
    for (final path in index.order) {
      for (final e in index.files[path]?.errorCodes ?? const <ErrorCodeUse>[]) {
        (errorCodes[e.code] ??= []).add(e);
      }
    }
    // The same code with different HTTP statuses in its descriptions ("U1101 (404)" here, "U1101 (409)" there).
    for (final e in errorCodes.entries) {
      final statuses = {for (final u in e.value) ?httpStatusOf(e.key, u.description)};
      if (statuses.length < 2) continue;
      for (final u in e.value) {
        problems.add(
          Problem(
            Severity.warning,
            'ERRCODE ${e.key} is described with different HTTP statuses: ${(statuses.toList()..sort()).join(', ')}',
            u.span,
            code: 'errcode-status',
          ),
        );
      }
    }
    final sorted = Map.fromEntries(errorCodes.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    return Conventions._(modules, violations, problems, sorted, moduleOfFile, moduleOfSchema);
  }

  /// The other rules of check-module-changesets.sh (spec 2.0/006), on the texts of the index (unsaved edits included).
  static List<Problem> _scriptRules(ProjectIndex index) {
    // The script runs in db/ with paths changelog/...; the opened folder may be db/ or db/changelog/.
    final underChangelog = index.order.any((x) => x.startsWith('changelog/'));
    final prefix = underChangelog ? '' : (p.basename(index.root) == 'changelog' ? 'changelog/' : null);
    if (prefix == null) return const [];
    final base = prefix.isEmpty ? index.root : p.dirname(index.root);
    // The rules of that script apply where the project uses it (or .pgstudio.json says so).
    final options = RuleOptions.forFolder(index.root);
    final enabled = options.enabled ?? File(p.join(base, 'scripts', 'check-module-changesets.sh')).existsSync();
    if (!enabled) return const [];
    String? changelogMd;
    try {
      final f = File(p.join(base, 'CHANGELOG.md'));
      if (f.existsSync()) changelogMd = f.readAsStringSync();
    } on Object {
      changelogMd = null;
    }
    final files = [
      for (final path in index.order)
        if (index.files[path] != null && '$prefix$path'.startsWith('changelog/'))
          (scriptPath: '$prefix$path', path: path, text: index.files[path]!.text),
    ];
    return moduleRules(files, changelogMd: changelogMd, options: options);
  }

  static ModuleViolation? _check(
    ModuleInfo own,
    String schema,
    ObjectSpace space,
    RefKind kind,
    SourceSpan span,
    Map<String, ModuleInfo> moduleOfSchema,
  ) {
    final other = moduleOfSchema[schema];
    if (other == null || other.name == own.name) return null;
    final isContract = schema == '${other.name}_app';
    // A module uses only lower modules (their _app, their tables through foreign keys, platform functions).
    if (other.number.compareTo(own.number) > 0 && schema != '${other.name}_internal') {
      return ModuleViolation(
        own,
        other,
        schema,
        Problem(
          Severity.warning,
          'module ${own.label} uses ${other.label} ($schema) - only modules with a lower number',
          span,
          code: 'module-order',
        ),
      );
    }
    if (isContract) return null;
    final platformFunction = schema == 'platform' && other.name == 'platform' && space == ObjectSpace.routine;
    if (kind == RefKind.foreignKey || platformFunction) return null;
    return ModuleViolation(
      own,
      other,
      schema,
      Problem(
        Severity.warning,
        'module ${own.label} uses tables or internal routines of ${other.label} ($schema) - use ${other.name}_app',
        span,
        code: 'module-boundary',
      ),
    );
  }

  /// The HTTP status a description gives the code: `U1012 (400)`, `U1015 = 400`, `(404): ...`.
  static String? httpStatusOf(String code, String description) {
    final near = RegExp('${RegExp.escape(code)}\\s*(?:\\(|=\\s*)([1-5]\\d\\d)\\b').firstMatch(description);
    if (near != null) return near.group(1);
    return RegExp(r'\(([1-5]\d\d)\)').firstMatch(description)?.group(1);
  }
}
