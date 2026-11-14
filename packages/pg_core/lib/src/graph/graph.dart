// Dependency graphs for the UI: one object with what it uses and what uses it; modules with what they use.
import '../conventions/conventions.dart';
import '../index/project_index.dart';
import '../model.dart';

/// A neighbour of the object in the middle: an object, or a file for uses outside any definition (GRANT, DML).
final class GraphNode {
  const GraphNode({this.object, this.file, required this.kinds, required this.places});

  final DbObject? object;
  final String? file;

  /// How it is connected: call, read, write, type, ...
  final Set<RefKind> kinds;

  /// The references behind the edge (to jump to one).
  final List<ResolvedReference> places;

  String get label => object?.key.qualified ?? file!.split('/').last;

  bool get writes => kinds.contains(RefKind.write);
}

final class ObjectGraph {
  const ObjectGraph(this.center, this.users, this.uses);

  final DbObject center;

  /// What uses the object (left).
  final List<GraphNode> users;

  /// What the object uses (right).
  final List<GraphNode> uses;
}

ObjectGraph objectGraph(ProjectIndex index, DbObject center) {
  final users = <String, (DbObject?, String?, Set<RefKind>, List<ResolvedReference>)>{};
  for (final r in index.referencesTo(center.key)) {
    final from = r.reference.from;
    if (from == center.key) continue; // recursion inside the object itself
    final object = from == null ? null : index.objects[from];
    final id = object != null ? 'o:${object.key}' : 'f:${r.span.file}';
    final entry = users.putIfAbsent(id, () => (object, object == null ? r.span.file : null, <RefKind>{}, []));
    entry.$3.add(r.kind);
    entry.$4.add(r);
  }
  final uses = <ObjectKey, (Set<RefKind>, List<ResolvedReference>)>{};
  for (final r in index.referencesFrom(center.key)) {
    for (final t in r.targets) {
      if (t == center.key) continue;
      final entry = uses.putIfAbsent(t, () => (<RefKind>{}, []));
      entry.$1.add(r.kind);
      entry.$2.add(r);
    }
  }
  int byLabel(GraphNode a, GraphNode b) => a.label.compareTo(b.label);
  return ObjectGraph(
    center,
    [for (final e in users.values) GraphNode(object: e.$1, file: e.$2, kinds: e.$3, places: e.$4)]..sort(byLabel),
    [
      for (final e in uses.entries)
        if (index.objects[e.key] != null)
          GraphNode(object: index.objects[e.key], kinds: e.value.$1, places: e.value.$2),
    ]..sort(byLabel),
  );
}

/// Module [from] uses module [to] in [count] places; [violations] of them break the rules (spec 003).
final class ModuleEdge {
  const ModuleEdge(this.from, this.to, this.count, this.violations, this.example);

  final ModuleInfo from;
  final ModuleInfo to;
  final int count;
  final int violations;

  /// One place, to jump to.
  final SourceSpan example;
}

final class ModuleGraph {
  const ModuleGraph(this.modules, this.edges);

  final List<ModuleInfo> modules;
  final List<ModuleEdge> edges;
}

ModuleGraph moduleGraph(ProjectIndex index) {
  final c = index.conventions;
  final counts = <(String, String), (int, int, SourceSpan)>{};
  final violating = {for (final v in c.violations) v.problem.span};
  for (final path in index.order) {
    final own = c.moduleOfFile(path);
    if (own == null) continue;
    for (final r in index.files[path]!.references) {
      final schema = r.name.schema;
      if (schema == null) continue;
      final other = c.moduleOfSchema(schema);
      if (other == null || other.name == own.name) continue;
      // Only references that point at something (resolved), or the ones the rules report.
      final bad = violating.contains(r.span);
      final resolved = index.referenceAt(path, r.span.start)?.targets.isNotEmpty ?? false;
      if (!resolved && !bad) continue;
      final key = (own.name, other.name);
      final now = counts[key];
      counts[key] = (now == null ? 1 : now.$1 + 1, (now?.$2 ?? 0) + (bad ? 1 : 0), now?.$3 ?? r.span);
    }
  }
  final byName = {for (final m in c.modules) m.name: m};
  final edges =
      [
        for (final e in counts.entries)
          ModuleEdge(byName[e.key.$1]!, byName[e.key.$2]!, e.value.$1, e.value.$2, e.value.$3),
      ]..sort(
        (a, b) => a.from.number != b.from.number
            ? a.from.number.compareTo(b.from.number)
            : a.to.number.compareTo(b.to.number),
      );
  return ModuleGraph(c.modules, edges);
}
