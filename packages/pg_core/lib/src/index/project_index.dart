// Phase 2 of the analysis: objects from all files, references resolved to objects, problems of the project.
import '../analysis/columns.dart';
import '../conventions/conventions.dart';
import '../model.dart';

/// An object with every place it is defined or changed, in changelog order.
final class DbObject {
  DbObject(this.key, this.definitions);

  final ObjectKey key;
  final List<Definition> definitions;

  /// The defining statement (the first CREATE), or the first change when the object is only altered here.
  Definition get primary => definitions.firstWhere((d) => !d.isAlter, orElse: () => definitions.first);

  ObjectKind get kind => primary.kind;

  bool get isDefinedHere => definitions.any((d) => !d.isAlter);

  /// Columns after every ALTER TABLE in order (tables, views, composite types).
  List<ColumnInfo> get columns {
    final columns = <ColumnInfo>[];
    for (final d in definitions) {
      if (!d.isAlter) columns.clear();
      columns.removeWhere((c) => d.droppedColumns.contains(c.name));
      for (final c in d.columns) {
        columns.removeWhere((x) => x.name == c.name);
        columns.add(c);
      }
    }
    return columns;
  }

  /// The primary key after every change (the last statement declaring one).
  List<String> get primaryKey {
    var pk = const <String>[];
    for (final d in definitions) {
      if (d.primaryKey.isNotEmpty) pk = d.primaryKey;
    }
    final columnNames = {for (final c in columns) c.name};
    return [
      for (final c in pk)
        if (columnNames.contains(c)) c,
    ];
  }

  /// Foreign keys of every statement, without the ones whose columns were dropped.
  List<ForeignKeyInfo> get foreignKeys {
    final columnNames = {for (final c in columns) c.name};
    return [
      for (final d in definitions)
        for (final fk in d.foreignKeys)
          if (fk.columns.every(columnNames.contains)) fk,
    ];
  }

  /// The latest CREATE OR REPLACE wins for routines.
  Definition get latest => definitions.lastWhere((d) => !d.isAlter, orElse: () => definitions.last);

  /// `orders_app.asn_save(p_id uuid, ..., INOUT p_row_version bigint)` / `... RETURNS int`.
  String get signature {
    final d = latest;
    final params = d.parameters.join(', ');
    return switch (kind) {
      ObjectKind.function => '${key.qualified}($params)${d.returns == null ? '' : ' RETURNS ${d.returns}'}',
      ObjectKind.procedure => '${key.qualified}($params)',
      _ => key.qualified,
    };
  }
}

/// A reference with the objects it points to (empty = unresolved).
final class ResolvedReference {
  const ResolvedReference(this.reference, this.targets);

  final Reference reference;
  final List<ObjectKey> targets;

  SourceSpan get span => reference.span;
  RefKind get kind => reference.kind;
}

final class ProjectIndex {
  ProjectIndex._(this.root, this.files, this.order, this.objects, this.references, this.problems, this.schemas);

  /// Absolute path of the opened folder.
  final String root;

  /// Phase 1 results by path relative to [root].
  final Map<String, FileAnalysis> files;

  /// File paths in changelog order (Liquibase includes, then the rest by path).
  final List<String> order;
  final Map<ObjectKey, DbObject> objects;
  final List<ResolvedReference> references;
  final List<Problem> problems;

  /// Schemas defined in the project (CREATE SCHEMA) or owning a defined object.
  final Set<String> schemas;

  /// The conventions of our stack (modules, contract, error codes); empty when the folder has no modules.
  late final Conventions conventions = Conventions.of(this);

  /// Problems of the files and of the conventions, in changelog order of files.
  late final List<Problem> allProblems = () {
    final position = {for (var i = 0; i < order.length; i++) order[i]: i};
    return [...problems, ...conventions.problems]..sort((a, b) {
      final byFile = (position[a.span.file] ?? 0).compareTo(position[b.span.file] ?? 0);
      return byFile != 0 ? byFile : a.span.start.compareTo(b.span.start);
    });
  }();

  late final Map<ObjectKey, List<ResolvedReference>> _byTarget = () {
    final map = <ObjectKey, List<ResolvedReference>>{};
    for (final r in references) {
      for (final t in r.targets) {
        (map[t] ??= []).add(r);
      }
    }
    return map;
  }();

  late final Map<String, List<ResolvedReference>> _byFile = () {
    final map = <String, List<ResolvedReference>>{};
    for (final r in references) {
      (map[r.span.file] ??= []).add(r);
    }
    for (final list in map.values) {
      list.sort((a, b) => a.span.start.compareTo(b.span.start));
    }
    return map;
  }();

  late final Map<ObjectKey, List<ResolvedReference>> _byFrom = () {
    final map = <ObjectKey, List<ResolvedReference>>{};
    for (final r in references) {
      final from = r.reference.from;
      if (from != null) (map[from] ??= []).add(r);
    }
    return map;
  }();

  late final Map<String, List<Problem>> _problemsByFile = () {
    final map = <String, List<Problem>>{};
    for (final x in allProblems) {
      (map[x.span.file] ??= []).add(x);
    }
    return map;
  }();

  /// Problems (files and conventions) of one file.
  List<Problem> problemsIn(String path) => _problemsByFile[path] ?? const [];

  /// Column uses of the whole project (computed on first use: it scans every statement again).
  late final List<ColumnUse> columnUses = findColumnUses(this);

  late final Map<(ObjectKey, String), List<ColumnUse>> _columnIndex = () {
    final map = <(ObjectKey, String), List<ColumnUse>>{};
    for (final u in columnUses) {
      (map[(u.relation, u.column)] ??= []).add(u);
    }
    return map;
  }();

  late final Map<String, List<ColumnUse>> _columnsByFile = () {
    final map = <String, List<ColumnUse>>{};
    for (final u in columnUses) {
      (map[u.span.file] ??= []).add(u);
    }
    return map;
  }();

  List<ColumnUse> columnUsesOf(ObjectKey relation, String column) => _columnIndex[(relation, column)] ?? const [];

  /// The column use at [offset] of [path], or the column defined there (CREATE TABLE / ALTER TABLE ADD COLUMN).
  ({ObjectKey relation, String column, ColumnUse? use})? columnAt(String path, int offset) {
    for (final u in _columnsByFile[path] ?? const <ColumnUse>[]) {
      if (u.span.start <= offset && offset <= u.span.end) return (relation: u.relation, column: u.column, use: u);
    }
    for (final d in files[path]?.definitions ?? const <Definition>[]) {
      for (final c in d.columns) {
        final s = c.span;
        if (s != null && s.start <= offset && offset <= s.end) return (relation: d.key, column: c.name, use: null);
      }
    }
    return null;
  }

  /// Where a column is defined: the ColumnDef of its CREATE/ALTER TABLE, or the definition of a view.
  SourceSpan? columnDefinition(ObjectKey relation, String column) {
    final o = objects[relation];
    if (o == null) return null;
    for (final d in o.definitions.reversed) {
      for (final c in d.columns) {
        if (c.name == column && c.span != null) return c.span;
      }
    }
    return o.primary.nameSpan;
  }

  /// What changes or breaks when [relation] (or one of its columns) changes: the objects that use it, and the
  /// objects that use those views in turn - with how. A table: its references; a column: its uses.
  List<({DbObject object, Set<RefKind> how, int level})> impactOf(ObjectKey relation, {String? column}) {
    final result = <ObjectKey, ({DbObject object, Set<RefKind> how, int level})>{};
    void add(ObjectKey? key, RefKind how, int level) {
      if (key == null || key == relation) return;
      final o = objects[key];
      if (o == null) return;
      final now = result[key];
      if (now == null) {
        result[key] = (object: o, how: {how}, level: level);
      } else {
        now.how.add(how);
      }
    }

    if (column != null) {
      for (final u in columnUsesOf(relation, column)) {
        add(u.from, u.kind, 1);
      }
    } else {
      for (final r in referencesTo(relation)) {
        add(r.reference.from, r.kind, 1);
      }
    }
    // Views built on the affected views change too (a level further, until nothing new).
    var frontier = [
      for (final e in result.values)
        if (e.object.kind == ObjectKind.view) e.object.key,
    ];
    var level = 2;
    while (frontier.isNotEmpty && level < 10) {
      final next = <ObjectKey>[];
      for (final v in frontier) {
        for (final r in referencesTo(v)) {
          final from = r.reference.from;
          if (from == null || result.containsKey(from)) continue;
          add(from, r.kind, level);
          if (objects[from]?.kind == ObjectKind.view) next.add(from);
        }
      }
      frontier = next;
      level++;
    }
    return result.values.toList()
      ..sort((a, b) => a.level != b.level ? a.level - b.level : a.object.key.compareTo(b.object.key));
  }

  /// Uses of [key] (Find references).
  List<ResolvedReference> referencesTo(ObjectKey key) => _byTarget[key] ?? const [];

  /// References inside the definition of [key] (what it uses).
  List<ResolvedReference> referencesFrom(ObjectKey key) => _byFrom[key] ?? const [];

  List<ResolvedReference> referencesInFile(String path) => _byFile[path] ?? const [];

  /// The reference whose span contains [offset] in [path].
  ResolvedReference? referenceAt(String path, int offset) {
    for (final r in referencesInFile(path)) {
      if (r.span.start <= offset && offset <= r.span.end) return r;
      if (r.span.start > offset) break;
    }
    return null;
  }

  /// The object whose definition name contains [offset] in [path].
  DbObject? definitionAt(String path, int offset) {
    for (final d in files[path]?.definitions ?? const <Definition>[]) {
      if (d.nameSpan.start <= offset && offset <= d.nameSpan.end) return objects[d.key];
    }
    return null;
  }

  /// The innermost definition statement containing [offset] (e.g. the procedure a line belongs to).
  Definition? enclosingDefinition(String path, int offset) {
    Definition? best;
    for (final d in files[path]?.definitions ?? const <Definition>[]) {
      if (d.statementSpan.start <= offset && offset <= d.statementSpan.end) {
        if (best == null ||
            d.statementSpan.end - d.statementSpan.start < best.statementSpan.end - best.statementSpan.start) {
          best = d;
        }
      }
    }
    return best;
  }

  /// Objects by name, any kind (Ctrl+T).
  Iterable<DbObject> search(String query) {
    final q = query.toLowerCase();
    return objects.values.where((o) => o.key.qualified.toLowerCase().contains(q));
  }

  int get definitionCount => files.values.fold(0, (n, f) => n + f.definitions.length);

  static const _builtinSchemas = {'pg_catalog', 'information_schema', 'pg_toast', 'pg_temp'};

  /// Links phase 1 results: builds objects and resolves every reference.
  static ProjectIndex link(String root, Map<String, FileAnalysis> files, List<String> order) {
    final position = {for (var i = 0; i < order.length; i++) order[i]: i};
    final definitions = <ObjectKey, List<Definition>>{};
    for (final path in order) {
      final file = files[path];
      if (file == null) continue;
      for (final d in file.definitions) {
        (definitions[d.key] ??= []).add(d);
      }
    }
    final objects = <ObjectKey, DbObject>{};
    for (final e in definitions.entries) {
      e.value.sort((a, b) {
        final byFile = (position[a.nameSpan.file] ?? 0).compareTo(position[b.nameSpan.file] ?? 0);
        return byFile != 0 ? byFile : a.nameSpan.start.compareTo(b.nameSpan.start);
      });
      objects[e.key] = DbObject(e.key, e.value);
    }

    final schemas = <String>{
      for (final k in objects.keys)
        if (k.space == ObjectSpace.schema) k.name else if (k.schema.isNotEmpty) k.schema,
    };

    final byName = <String, List<ObjectKey>>{};
    for (final k in objects.keys) {
      (byName['${k.space.index}|${k.schema}|${k.name}'] ??= []).add(k);
    }

    List<ObjectKey> lookup(ObjectSpace space, String schema, String name) =>
        byName['${space.index}|$schema|$name'] ?? const [];

    List<ObjectKey> resolve(Reference r) {
      final name = r.name;
      if (r.space == ObjectSpace.schema) return lookup(ObjectSpace.schema, '', name.name);
      if (r.space == ObjectSpace.extension) return lookup(ObjectSpace.extension, '', name.name);
      final candidates = name.schema != null ? [name.schema!] : r.searchPath;
      final spaces = switch (r.space) {
        ObjectSpace.type => const [ObjectSpace.type, ObjectSpace.relation],
        ObjectSpace.relation => const [ObjectSpace.relation, ObjectSpace.type],
        _ => [r.space],
      };
      for (final schema in candidates) {
        for (final space in spaces) {
          var found = lookup(space, schema, name.name);
          if (found.isEmpty) continue;
          if (space == ObjectSpace.routine && r.argCount != null && found.length > 1) {
            final matching = found.where((k) => _accepts(objects[k]!, r.argCount!)).toList();
            if (matching.isNotEmpty) found = matching;
          }
          return found;
        }
      }
      return const [];
    }

    final references = <ResolvedReference>[];
    final problems = <Problem>[];
    for (final path in order) {
      final file = files[path];
      if (file == null) continue;
      problems.addAll(file.problems);
      for (final r in file.references) {
        final targets = resolve(r);
        if (targets.isNotEmpty) {
          references.add(ResolvedReference(r, targets));
          continue;
        }
        final schema = r.name.schema;
        if (r.reportUnresolved && schema != null && !_builtinSchemas.contains(schema) && schemas.contains(schema)) {
          references.add(ResolvedReference(r, const []));
          problems.add(
            Problem(
              Severity.warning,
              '${r.space.name} ${r.name} is not defined in the project',
              r.span,
              code: 'unresolved',
            ),
          );
        }
      }
    }
    return ProjectIndex._(root, files, order, objects, references, problems, schemas);
  }

  static bool _accepts(DbObject o, int args) {
    // CALL passes OUT parameters of a procedure too (PostgreSQL 14+).
    final isProcedure = o.kind == ObjectKind.procedure;
    final inputs = o.latest.parameters.where((p) => p.isInput || (isProcedure && p.mode == 'out')).toList();
    final required = inputs.where((p) => !p.hasDefault && p.mode != 'variadic').length;
    final variadic = inputs.any((p) => p.mode == 'variadic');
    return args >= required && (variadic || args <= inputs.length);
  }
}
