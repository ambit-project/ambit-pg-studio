// Answers shared by the CLI and the MCP server: the index as plain JSON-ready maps (2.0 spec 011).
import '../conventions/conventions.dart';
import '../graph/graph.dart';
import '../index/project_index.dart';
import '../model.dart';

/// `file`, 1-based `line` and `column` of a span.
Map<String, Object?> place(ProjectIndex index, SourceSpan span) {
  final file = index.files[span.file];
  final (line, column) = file?.lineColumn(span.start) ?? (0, 0);
  return {'file': span.file, 'line': line + 1, 'column': column + 1};
}

String placeText(ProjectIndex index, SourceSpan span) {
  final p = place(index, span);
  return '${p['file']}:${p['line']}:${p['column']}';
}

Map<String, Object?> problemJson(ProjectIndex index, Problem p) => {
  ...place(index, p.span),
  'severity': p.severity.name,
  'code': p.code,
  'message': p.message,
};

/// Problems of the project, the same list as the Problems panel (`allProblems`).
List<Problem> problems(ProjectIndex index, {String severity = 'all', String? file}) => [
  for (final p in index.allProblems)
    if ((severity == 'all' ||
            (severity == 'error' && p.severity == Severity.error) ||
            (severity == 'warning' && p.severity != Severity.info)) &&
        (file == null || p.span.file == file || p.span.file.endsWith('/$file')))
      p,
];

/// Objects named [name]: `schema.name`, or `name` in any schema (all overloads), optionally of one [kind].
List<DbObject> findObjects(ProjectIndex index, String name, {String? kind}) {
  final wanted = name.trim().toLowerCase();
  final qualified = wanted.contains('.');
  return [
    for (final o in index.objects.values)
      if ((qualified ? o.key.qualified.toLowerCase() == wanted : o.key.name.toLowerCase() == wanted) &&
          (kind == null || o.kind.label == kind || o.kind.name == kind))
        o,
  ]..sort((a, b) => a.key.compareTo(b.key));
}

Map<String, Object?> objectJson(ProjectIndex index, DbObject o) => {
  'name': o.key.qualified,
  'kind': o.kind.label,
  'signature': o.signature,
  'definition': place(index, o.primary.nameSpan),
  if (o.definitions.length > 1)
    'changes': [
      for (final d in o.definitions.where((d) => d.isAlter)) {...place(index, d.nameSpan), 'changeset': d.changesetId},
    ],
  if (o.columns.isNotEmpty)
    'columns': [
      for (final c in o.columns) {'name': c.name, 'type': c.type, if (c.notNull) 'notNull': true},
    ],
  if (o.primary.comment.isNotEmpty) 'comment': o.primary.comment,
};

Map<String, Object?> referencesJson(ProjectIndex index, DbObject o, {String? kind}) {
  final refs = [
    for (final r in index.referencesTo(o.key))
      if (kind == null || r.kind.label == kind || r.kind.name == kind) r,
  ];
  return {
    'name': o.key.qualified,
    'kind': o.kind.label,
    'count': refs.length,
    'references': [
      for (final r in refs) {...place(index, r.span), 'kind': r.kind.label, 'in': r.reference.from?.toString()},
    ],
  };
}

Map<String, Object?> graphJson(ProjectIndex index, DbObject o) {
  final g = objectGraph(index, o);
  Map<String, Object?> node(GraphNode n) => {
    'name': n.object?.key.qualified ?? n.file,
    if (n.object != null) 'kind': n.object!.kind.label,
    'how': [for (final k in n.kinds) k.label],
  };
  return {
    'name': o.key.qualified,
    'usedBy': [for (final n in g.users) node(n)],
    'uses': [for (final n in g.uses) node(n)],
  };
}

Map<String, Object?> modulesJson(ProjectIndex index) {
  final g = moduleGraph(index);
  return {
    'modules': [for (final m in g.modules) m.label],
    'dependencies': [
      for (final e in g.edges)
        {'from': e.from.label, 'to': e.to.label, 'uses': e.count, 'againstTheRules': e.violations},
    ],
  };
}

Map<String, Object?> contractJson(ProjectIndex index, {String? module}) {
  final c = index.conventions;
  return {
    for (final m in c.modules)
      if (module == null || m.name == module || m.label == module)
        '${m.name}_app': [for (final o in c.contractOf(m, index)) o.signature],
  };
}

Map<String, Object?> errorCodesJson(ProjectIndex index, {String? code}) => {
  for (final e in index.conventions.errorCodes.entries)
    if (code == null || e.key == code)
      e.key: [
        for (final u in e.value) {...place(index, u.span), 'in': u.from?.qualified, 'description': u.description},
      ],
};

/// Modules known by name for argument checks.
List<ModuleInfo> modules(ProjectIndex index) => index.conventions.modules;
