// An entity-relationship model of a schema or a module (2.0 spec 009): tables with columns (PK/FK marked), foreign
// keys as edges, laid out in layers - a table to the right of every table it references.
import '../conventions/conventions.dart';
import '../index/project_index.dart';
import '../model.dart';

final class ErColumn {
  const ErColumn(this.name, this.type, {required this.primaryKey, required this.foreignKey, required this.notNull});

  final String name;
  final String type;
  final bool primaryKey;
  final bool foreignKey;
  final bool notNull;
}

final class ErTable {
  ErTable(this.object, this.columns, {this.external = false});

  final DbObject object;
  final List<ErColumn> columns;

  /// Referenced from the scope but outside it: drawn small, without columns.
  final bool external;
  int layer = 0;
  int row = 0;
}

final class ErEdge {
  const ErEdge(this.from, this.to, this.columns);

  final ObjectKey from;
  final ObjectKey to;
  final List<String> columns;
}

final class ErModel {
  const ErModel(this.title, this.tables, this.edges);

  final String title;
  final List<ErTable> tables;
  final List<ErEdge> edges;
}

/// The tables of [schema], or of [module] (its table schema `<module>`).
ErModel erModel(ProjectIndex index, {String? schema, ModuleInfo? module}) {
  final scope = schema ?? module?.name ?? '';
  bool inScope(ObjectKey k) => k.schema == scope;
  final tables = <ObjectKey, ErTable>{};
  for (final o in index.objects.values) {
    if (o.kind != ObjectKind.table || !o.isDefinedHere || !inScope(o.key)) continue;
    final pk = o.primaryKey.toSet();
    final fkCols = {for (final fk in o.foreignKeys) ...fk.columns};
    tables[o.key] = ErTable(o, [
      for (final c in o.columns)
        ErColumn(
          c.name,
          c.type,
          primaryKey: pk.contains(c.name),
          foreignKey: fkCols.contains(c.name),
          notNull: c.notNull,
        ),
    ]);
  }
  final edges = <ErEdge>[];
  for (final t in tables.values.toList()) {
    for (final fk in t.object.foreignKeys) {
      final target = index.objects.values
          .where((o) => o.kind == ObjectKind.table && o.key.schema == fk.target.schema && o.key.name == fk.target.name)
          .firstOrNull;
      if (target == null) continue;
      tables.putIfAbsent(target.key, () => ErTable(target, const [], external: true));
      edges.add(ErEdge(t.object.key, target.key, fk.columns));
    }
  }
  // Layers: referenced tables first (left); a cycle or a self reference does not push a table further.
  final depth = <ObjectKey, int>{};
  int layerOf(ObjectKey k, Set<ObjectKey> visiting) {
    final known = depth[k];
    if (known != null) return known;
    if (!visiting.add(k)) return 0;
    var d = 0;
    for (final e in edges.where((e) => e.from == k && e.to != k)) {
      final l = layerOf(e.to, visiting) + 1;
      if (l > d) d = l;
    }
    visiting.remove(k);
    return depth[k] = d;
  }

  for (final k in tables.keys) {
    tables[k]!.layer = layerOf(k, {});
  }
  final byLayer = <int, List<ErTable>>{};
  for (final t in tables.values) {
    (byLayer[t.layer] ??= []).add(t);
  }
  for (final list in byLayer.values) {
    list.sort((a, b) => a.object.key.compareTo(b.object.key));
    for (var i = 0; i < list.length; i++) {
      list[i].row = i;
    }
  }
  final sorted = tables.values.toList()..sort((a, b) => a.layer != b.layer ? a.layer - b.layer : a.row - b.row);
  return ErModel(module == null ? 'schema $scope' : 'module ${module.label}', sorted, edges);
}

/// Schemas that have tables (for the ER scope list).
List<String> schemasWithTables(ProjectIndex index) => {
  for (final o in index.objects.values)
    if (o.kind == ObjectKind.table && o.isDefinedHere) o.key.schema,
}.toList()..sort();
