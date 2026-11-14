// New objects and changesets from templates that pass check-module-changesets.sh as they are (2.0 spec 004).
import 'dart:io';

import 'package:path/path.dart' as p;

import '../conventions/conventions.dart';
import '../index/project_index.dart';

enum NewKind { procedure, function, view, ddlChangeset, dataChangeset }

final class NewFile {
  const NewFile(this.path, this.content, this.changelogLine, this.cursor);

  /// Relative to the opened folder.
  final String path;
  final String content;

  /// A line for CHANGELOG.md (the script wants every module file described there).
  final String changelogLine;

  /// Where the cursor goes in [content] (the first thing to write).
  final int cursor;
}

const _todo = 'Opisz, dlaczego ta zmiana powstaje.';

/// Builds the file; null with a reason in [error] when it cannot be made (no modules, bad name, taken path).
({NewFile? file, String? error}) newFromTemplate(
  ProjectIndex index, {
  required NewKind kind,
  required String module,
  required String name,
  bool internal = false,
  required String today,
}) {
  final c = index.conventions;
  final m = c.modules.where((x) => x.name == module).firstOrNull;
  if (m == null) return (file: null, error: 'No module $module (changelog/modules/<nn>-$module).');
  if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) {
    return (file: null, error: 'A name is lower case letters, digits and _: "$name".');
  }
  final owner = _mostFrequent(index, RegExp(r'^SET LOCAL ROLE (\S+);', multiLine: true)) ?? '${module}_owner';
  final author = _mostFrequentAuthor(index) ?? 'pg-studio';
  final noActor = index.files.values.any((f) => f.text.contains('\n--no-actor: '));
  // modules/<nn>-<m>/ relative to the opened folder (db/ or db/changelog/).
  final modulesPrefix = m.folder.substring(0, m.folder.length - '${m.number}-${m.name}'.length);
  final changelogPrefix = modulesPrefix.substring(0, modulesPrefix.length - 'modules/'.length);
  String short(String path) => path.startsWith('changelog/') ? path.substring('changelog/'.length) : path;

  if (kind == NewKind.ddlChangeset || kind == NewKind.dataChangeset) {
    final folder = kind == NewKind.ddlChangeset ? '1-ddl' : '2-data';
    final dir = '$changelogPrefix${today.substring(0, 4)}/$folder/';
    var next = 1;
    for (final path in index.order) {
      final x = RegExp('^${RegExp.escape(dir)}$today-(\\d{2})-').firstMatch(path);
      if (x != null && int.parse(x.group(1)!) >= next) next = int.parse(x.group(1)!) + 1;
    }
    final slug = '${module.replaceAll('_', '-')}-${name.replaceAll('_', '-')}';
    final id = '$today-${next.toString().padLeft(2, '0')}-$slug';
    final path = '$dir$id.sql';
    final head = '--liquibase formatted sql\n\n--changeset $author:$id\n--comment: $_todo\nSET LOCAL ROLE $owner;\n\n';
    final content = '$head\nRESET ROLE;\n';
    return (file: NewFile(path, content, '- `${short(path)}`: $_todo', head.length), error: null);
  }

  final schema = internal ? '${module}_internal' : '${module}_app';
  final folder = switch (kind) {
    NewKind.procedure => 'procedures',
    NewKind.function => 'functions',
    _ => 'views',
  };
  final path = '${m.folder}/$folder/$schema.$name.sql';
  if (index.files.containsKey(path)) return (file: null, error: '$path already exists.');
  final singular = folder.substring(0, folder.length - 1);
  final id = '$singular-${schema.replaceAll('_', '-')}-${name.replaceAll('_', '-')}';
  final actor = schema.endsWith('_app');
  final b = StringBuffer()
    ..writeln('--liquibase formatted sql')
    ..writeln()
    ..writeln('--changeset $author:$id runOnChange:true splitStatements:false')
    ..writeln('--comment: $_todo')
    ..writeln('SET LOCAL ROLE $owner;')
    ..writeln();
  int cursor;
  switch (kind) {
    case NewKind.procedure:
      b
        ..writeln('CREATE OR REPLACE PROCEDURE $schema.$name(')
        ..writeln('    p_id uuid')
        ..writeln(')')
        ..writeln('LANGUAGE plpgsql')
        ..writeln('SECURITY DEFINER')
        ..writeln('SET search_path = pg_catalog, pg_temp')
        ..writeln(r'AS $$')
        ..writeln('DECLARE');
      if (actor) b.writeln('    v_actor_id uuid := platform.require_actor_id();');
      b.writeln('BEGIN');
      cursor = b.length + 4;
      b
        ..writeln('    NULL;')
        ..writeln('END')
        ..writeln(r'$$;');
    case NewKind.function:
      b
        ..writeln('CREATE OR REPLACE FUNCTION $schema.$name(')
        ..writeln('    p_id uuid')
        ..writeln(')')
        ..writeln('RETURNS TABLE (')
        ..writeln('    id uuid')
        ..writeln(')')
        ..writeln('LANGUAGE plpgsql')
        ..writeln('STABLE')
        ..writeln('SECURITY DEFINER')
        ..writeln('SET search_path = pg_catalog, pg_temp')
        ..writeln(r'AS $$')
        ..writeln('BEGIN');
      // halycon's rules want every _app routine to require an actor; the skill's only procedures.
      if (actor && noActor) b.writeln('    PERFORM platform.require_actor_id();');
      b.writeln('    RETURN QUERY');
      cursor = b.length + 4;
      b
        ..writeln('    SELECT p_id;')
        ..writeln('END')
        ..writeln(r'$$;');
    default:
      b
        ..writeln('CREATE OR REPLACE VIEW $schema.$name AS')
        ..writeln('SELECT');
      cursor = b.length + 4;
      b.writeln('    NULL::uuid AS id;');
  }
  b.writeln('RESET ROLE;');
  return (file: NewFile(path, b.toString(), '- `${short(path)}`: $_todo', cursor), error: null);
}

String? _mostFrequent(ProjectIndex index, RegExp pattern) {
  final counts = <String, int>{};
  for (final f in index.files.values) {
    for (final m in pattern.allMatches(f.text)) {
      counts[m.group(1)!] = (counts[m.group(1)!] ?? 0) + 1;
    }
  }
  if (counts.isEmpty) return null;
  return (counts.entries.toList()..sort((a, b) => b.value - a.value)).first.key;
}

String? _mostFrequentAuthor(ProjectIndex index) {
  final counts = <String, int>{};
  for (final f in index.files.values) {
    for (final c in f.changesets) {
      counts[c.author] = (counts[c.author] ?? 0) + 1;
    }
  }
  if (counts.isEmpty) return null;
  return (counts.entries.toList()..sort((a, b) => b.value - a.value)).first.key;
}

/// The modules a new file can go to.
List<ModuleInfo> templateModules(ProjectIndex index) => index.conventions.modules;

/// Writes [file] under [root] and its line to CHANGELOG.md (in the opened folder or its parent, when there is one).
void createNewFile(String root, NewFile file) {
  final target = File(p.join(root, file.path));
  target.parent.createSync(recursive: true);
  target.writeAsStringSync(file.content);
  for (final dir in [root, p.dirname(root)]) {
    final md = File(p.join(dir, 'CHANGELOG.md'));
    if (!md.existsSync()) continue;
    md.writeAsStringSync('${md.readAsStringSync().trimRight()}\n${file.changelogLine}\n');
    break;
  }
}
