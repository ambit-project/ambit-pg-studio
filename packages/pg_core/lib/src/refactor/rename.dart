// Renaming an object or a column across the project (2.0 spec 003), always as a plan to preview first.
// Deployed changesets (in the main branch, without runOnChange) are never edited: Liquibase checks their checksums.
// Where the object exists in the database already, a new dated changeset ALTER ... RENAME TO renames it there.
import 'dart:io';

import 'package:path/path.dart' as p;

import '../index/project_index.dart';
import '../model.dart';

final class TextEdit {
  const TextEdit(this.start, this.end, this.replacement);

  final int start;
  final int end;
  final String replacement;
}

final class RenamePlan {
  RenamePlan(this.title);

  final String title;

  /// Edits by file (paths relative to the project).
  final Map<String, List<TextEdit>> edits = {};

  /// Files to rename after editing (old path -> new path).
  final Map<String, String> renames = {};

  /// New files (path -> content), e.g. the ALTER ... RENAME changeset.
  final Map<String, String> newFiles = {};

  /// Lines to append to CHANGELOG.md (next to the changelog folder), when the project has one.
  final List<String> changelogLines = [];

  /// What the plan does not change, and why (deployed changesets, views whose output column changes, ...).
  final List<String> warnings = [];

  /// Set when the rename is not possible (invalid or taken name, unsupported kind).
  String? error;

  int get editCount => edits.values.fold(0, (n, e) => n + e.length);

  void edit(String path, TextEdit e) => (edits[path] ??= []).add(e);
}

final _identifier = RegExp(r'^[a-z_][a-z0-9_]*$');

/// [inMain]: paths (relative to the project) in the main branch, or null when unknown (then every dated changeset
/// counts as deployed). [today]: yyyymmdd for the new changeset's name.
RenamePlan planRename(
  ProjectIndex index, {
  required ObjectKey object,
  String? column,
  required String newName,
  Set<String>? inMain,
  required String today,
}) {
  final o = index.objects[object];
  final what = column == null ? object.qualified : '${object.qualified}.$column';
  final plan = RenamePlan('Rename $what to $newName');
  if (o == null) return plan..error = 'No object $what.';
  if (!_identifier.hasMatch(newName)) {
    return plan..error = 'A name is lower case letters, digits and _ and does not start with a digit: "$newName".';
  }
  final old = column ?? object.name;
  if (newName == old) return plan..error = 'The name is the same.';

  bool editable(String path) {
    final file = index.files[path];
    if (file == null) return false;
    if (inMain != null && !inMain.contains(path)) return true; // not deployed yet
    // A file whose changesets all run on change describes the current state; others ran once.
    return file.changesets.isNotEmpty && file.changesets.every((c) => c.attributes['runOnChange'] == 'true');
  }

  String place(SourceSpan s) => '${s.file}:${index.files[s.file]!.lineColumn(s.start).$1 + 1}';

  // Replaces the last part of a (possibly qualified) name in a span: schema.old -> schema.new.
  void renameIn(SourceSpan span) {
    final text = index.files[span.file]!.text;
    final raw = text.substring(span.start, span.end);
    final dot = raw.lastIndexOf('.');
    final nameStart = span.start + dot + 1;
    final namePart = text.substring(nameStart, span.end);
    if (namePart.replaceAll('"', '').toLowerCase() != old) return;
    plan.edit(span.file, TextEdit(nameStart, span.end, newName));
  }

  if (column != null) {
    if (o.key.space != ObjectSpace.relation || !o.columns.any((c) => c.name == column)) {
      return plan..error = 'No column $what.';
    }
    if (o.columns.any((c) => c.name == newName)) {
      return plan..error = '${object.qualified} already has a column $newName.';
    }
    final defined = index.columnDefinition(object, column);
    final definedHere = defined != null && editable(defined.file) && o.kind == ObjectKind.table;
    if (definedHere) {
      plan.edit(defined.file, TextEdit(defined.start, defined.end, newName));
    } else if (o.kind == ObjectKind.table) {
      _alterChangeset(
        index,
        plan,
        o,
        'ALTER TABLE ${object.qualified} RENAME COLUMN $column TO $newName;',
        'rename-column-${object.name}-$column',
        inMain,
        today,
      );
    } else {
      plan.warnings.add(
        '${o.kind.label} ${object.qualified}: its column $column comes from its query - rename it there.',
      );
    }
    final views = <String>{};
    for (final u in index.columnUsesOf(object, column)) {
      if (editable(u.span.file)) {
        plan.edit(u.span.file, TextEdit(u.span.start, u.span.end, newName));
        final from = u.from == null ? null : index.objects[u.from];
        if (from?.kind == ObjectKind.view && from!.columns.any((c) => c.name == column)) views.add(from.key.qualified);
      } else {
        plan.warnings.add('${place(u.span)}: left as it is (deployed changeset).');
      }
    }
    for (final v in views) {
      plan.warnings.add(
        'view $v: its output column $column becomes $newName unless the query keeps "AS $column" - '
        'an API contract change.',
      );
    }
    return plan;
  }

  final kind = o.kind;
  if (!const {
    ObjectKind.table,
    ObjectKind.view,
    ObjectKind.function,
    ObjectKind.procedure,
    ObjectKind.type,
  }.contains(kind)) {
    return plan..error = 'Renaming a ${kind.label} is not supported.';
  }
  final taken = index.objects.keys.any(
    (k) => k.space == object.space && k.schema == object.schema && k.name == newName,
  );
  if (taken) return plan..error = '${object.schema}.$newName already exists.';
  final overloads = index.objects.keys.where(
    (k) => k.space == object.space && k.schema == object.schema && k.name == object.name,
  );
  if (overloads.length > 1) {
    plan.warnings.add('${object.qualified} has ${overloads.length} overloads: only ${o.signature} is renamed.');
  }

  // The definition(s): edited where they describe the current state; a deployed CREATE gets an ALTER ... RENAME.
  var deployed = false;
  for (final d in o.definitions) {
    if (editable(d.nameSpan.file)) {
      renameIn(d.nameSpan);
    } else {
      deployed = true;
      if (!d.isAlter) plan.warnings.add('${place(d.nameSpan)}: the CREATE stays (deployed changeset).');
    }
  }
  final primary = o.primary.nameSpan.file;
  final inDatabase = deployed || (inMain == null || inMain.contains(primary));
  if (inDatabase) {
    final args = object.space == ObjectSpace.routine ? '(${object.signature ?? ''})' : '';
    final statement = switch (kind) {
      ObjectKind.table => 'ALTER TABLE ${object.qualified} RENAME TO $newName;',
      ObjectKind.view => 'ALTER VIEW ${object.qualified} RENAME TO $newName;',
      ObjectKind.function => 'ALTER FUNCTION ${object.qualified}$args RENAME TO $newName;',
      ObjectKind.procedure => 'ALTER PROCEDURE ${object.qualified}$args RENAME TO $newName;',
      _ => 'ALTER TYPE ${object.qualified} RENAME TO $newName;',
    };
    _alterChangeset(index, plan, o, statement, 'rename-${object.name}', inMain, today);
  }

  // The module object file follows the name: modules/<nn>-<m>/<kind>/<schema>.<name>.sql and its changeset id.
  final fileName = '${object.schema}.${object.name}.sql';
  if (primary.endsWith('/$fileName') && editable(primary)) {
    final newPath = '${primary.substring(0, primary.length - fileName.length)}${object.schema}.$newName.sql';
    plan.renames[primary] = newPath;
    final text = index.files[primary]!.text;
    final oldId = '-${object.schema.replaceAll('_', '-')}-${object.name.replaceAll('_', '-')}';
    final header = RegExp(r'^--changeset [^:\s]+:(\S+)', multiLine: true).firstMatch(text);
    if (header != null && header.group(1)!.endsWith(oldId)) {
      final idEnd = header.start + header.group(0)!.length;
      plan.edit(
        primary,
        TextEdit(idEnd - oldId.length, idEnd, '-${object.schema.replaceAll('_', '-')}-${newName.replaceAll('_', '-')}'),
      );
    }
    final short = newPath.startsWith('changelog/') ? newPath.substring('changelog/'.length) : newPath;
    plan.changelogLines.add('- `$short`: renamed from ${object.qualified} (PG Studio)');
  }

  // Every use.
  for (final r in index.referencesTo(object)) {
    if (editable(r.span.file)) {
      renameIn(r.span);
    } else {
      plan.warnings.add('${place(r.span)}: ${r.kind.label} left as it is (deployed changeset).');
    }
  }
  return plan;
}

/// Adds a dated changeset with [statement] next to the others: `changelog/<yyyy>/1-ddl/<date>-<nn>-<module>-<what>.sql`.
void _alterChangeset(
  ProjectIndex index,
  RenamePlan plan,
  DbObject o,
  String statement,
  String what,
  Set<String>? inMain,
  String today,
) {
  final dated = RegExp(r'^(.*?)(\d{4})/1-ddl/(\d{8})-(\d{2})-');
  String? prefix;
  var next = 1;
  final author = <String, int>{};
  String? owner;
  for (final path in index.order) {
    final m = dated.firstMatch(path);
    if (m != null) {
      prefix ??= m.group(1);
      if (m.group(3) == today) {
        final n = int.parse(m.group(4)!);
        if (n >= next) next = n + 1;
      }
    }
    for (final c in index.files[path]!.changesets) {
      author[c.author] = (author[c.author] ?? 0) + 1;
    }
    owner ??= RegExp(r'^SET LOCAL ROLE (\S+);', multiLine: true).firstMatch(index.files[path]!.text)?.group(1);
  }
  if (prefix == null) {
    plan.warnings.add('No dated changesets (changelog/<yyyy>/1-ddl/) in the project: add "$statement" yourself.');
    return;
  }
  final module = index.conventions.moduleOfSchema(o.key.schema)?.name;
  final slug = [?module, what.replaceAll('_', '-')].join('-');
  final nn = next.toString().padLeft(2, '0');
  final path = '$prefix${today.substring(0, 4)}/1-ddl/$today-$nn-$slug.sql';
  final by = author.isEmpty ? 'pg-studio' : (author.entries.toList()..sort((a, b) => b.value - a.value)).first.key;
  final body = StringBuffer()
    ..writeln('--liquibase formatted sql')
    ..writeln()
    ..writeln('--changeset $by:$today-$nn-$slug')
    ..writeln('--comment: ${statement.replaceAll(';', '')} (PG Studio: zmiana nazwy).');
  if (owner != null) body.writeln('SET LOCAL ROLE $owner;');
  body.writeln(statement);
  if (owner != null) body.writeln('RESET ROLE;');
  plan.newFiles[path] = body.toString();
  final short = path.startsWith('changelog/') ? path.substring('changelog/'.length) : path;
  plan.changelogLines.add('- `$short`: ${statement.replaceAll(';', '')}');
}

/// Writes [plan] under [root]: edits (from the end of each file), file renames, new files, CHANGELOG.md lines.
/// Returns the paths (relative) that changed, old and new names included.
List<String> applyRenamePlan(String root, RenamePlan plan) {
  final changed = <String>{};
  for (final e in plan.edits.entries) {
    final file = File(p.join(root, e.key));
    var text = file.readAsStringSync();
    final edits = [...e.value]..sort((a, b) => b.start.compareTo(a.start));
    for (final x in edits) {
      text = text.replaceRange(x.start, x.end, x.replacement);
    }
    file.writeAsStringSync(text);
    changed.add(e.key);
  }
  for (final r in plan.renames.entries) {
    File(p.join(root, r.key)).renameSync(p.join(root, r.value));
    changed
      ..add(r.key)
      ..add(r.value);
  }
  for (final n in plan.newFiles.entries) {
    final file = File(p.join(root, n.key));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(n.value);
    changed.add(n.key);
  }
  if (plan.changelogLines.isNotEmpty) {
    // CHANGELOG.md sits in db/: the opened folder, or its parent when db/changelog was opened.
    for (final dir in [root, p.dirname(root)]) {
      final md = File(p.join(dir, 'CHANGELOG.md'));
      if (!md.existsSync()) continue;
      final text = md.readAsStringSync();
      md.writeAsStringSync('${text.trimRight()}\n${plan.changelogLines.join('\n')}\n');
      break;
    }
  }
  return changed.toList();
}
