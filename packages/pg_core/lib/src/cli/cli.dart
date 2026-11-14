// pg-studio-cli: the index of a database folder from the command line - for CI, pre-commit and agents (2.0 spec 011).
import 'dart:convert';
import 'dart:io';

import '../format/formatter.dart';
import '../git.dart';
import '../index/cache.dart';
import '../index/indexer.dart';
import '../index/project_index.dart';
import '../model.dart';
import 'mcp_server.dart';
import 'queries.dart';

const usage = '''pg-studio-cli - offline analysis of a PostgreSQL database folder (SQL files, Liquibase changesets)

Usage: pg-studio-cli <command> <folder> [arguments] [--json]

  check <folder> [--strict]        problems as file:line:column: severity: message [code];
                                   exit 1 on errors (--strict: also on warnings)
  def <folder> <name>              where an object is defined (schema.name or name)
  refs <folder> <name> [--kind K]  every use of an object (K: call, read, write, type, ...)
  graph <folder> <name>            what the object uses and what uses it
  modules <folder>                 module dependencies (changelog/modules/<nn>-<module>)
  contract <folder> [module]       <module>_app objects with signatures
  codes <folder> [code]            ERRCODE values with places and descriptions
  format <folder> [--check]        format files in place (whitespace only, deployed changesets untouched);
                                   --check: list the files that would change, exit 1 if any
  mcp <folder>                     Model Context Protocol server on stdio (claude mcp add pg-studio -- pg-studio-cli mcp <folder>)

Options: --no-cache (do not use the phase 1 cache in ~/.cache/pg_studio), --timing (index time on stderr)
''';

/// Runs one command; the exit code: 0 ok, 1 findings (check, format --check), 2 usage.
Future<int> runCli(List<String> args, {IOSink? out, IOSink? err, Stream<List<int>>? input}) async {
  final o = out ?? stdout;
  final e = err ?? stderr;
  final json = args.contains('--json');
  final strict = args.contains('--strict');
  final checkOnly = args.contains('--check');
  final kindAt = args.indexOf('--kind');
  final kind = kindAt >= 0 && kindAt + 1 < args.length ? args[kindAt + 1] : null;
  final words = [
    for (var i = 0; i < args.length; i++)
      if (!args[i].startsWith('--') && !(kindAt >= 0 && i == kindAt + 1)) args[i],
  ];
  if (words.isEmpty || words.first == 'help' || args.contains('--help')) {
    o.write(usage);
    return words.isEmpty ? 2 : 0;
  }
  if (words.length < 2) {
    e.writeln('Missing <folder>.\n\n$usage');
    return 2;
  }
  final command = words[0];
  final root = Directory(words[1]).absolute.path;
  if (!Directory(root).existsSync()) {
    e.writeln('No such folder: ${words[1]}');
    return 2;
  }
  final arg = words.length > 2 ? words[2] : null;

  if (command == 'mcp') {
    await McpServer(root).serve(input ?? stdin, o);
    return 0;
  }
  if (command == 'format') return _format(root, checkOnly, json, o);

  final (index, timing) = await Indexer.open(root, cache: args.contains('--no-cache') ? null : Phase1Cache.at());
  if (args.contains('--timing')) e.writeln('index: $timing');
  void emit(Object? value) => o.writeln(const JsonEncoder.withIndent('  ').convert(value));

  List<DbObject>? objects() {
    if (arg == null) {
      e.writeln('Missing <name>.');
      return null;
    }
    final found = findObjects(index, arg);
    if (found.isEmpty) e.writeln('No object named $arg.');
    return found;
  }

  switch (command) {
    case 'check':
      final list = problems(index);
      if (json) {
        emit([for (final p in list) problemJson(index, p)]);
      } else {
        for (final p in list) {
          o.writeln('${placeText(index, p.span)}: ${p.severity.name}: ${p.message.split('\n').first} [${p.code}]');
        }
        final errors = list.where((p) => p.severity == Severity.error).length;
        final warnings = list.where((p) => p.severity == Severity.warning).length;
        o.writeln('${index.files.length} files, ${index.objects.length} objects: $errors errors, $warnings warnings');
      }
      final failing = list.any((p) => p.severity == Severity.error || (strict && p.severity == Severity.warning));
      return failing ? 1 : 0;
    case 'def':
      final found = objects();
      if (found == null) return 2;
      if (json) {
        emit([for (final x in found) objectJson(index, x)]);
      } else {
        for (final x in found) {
          o.writeln('${placeText(index, x.primary.nameSpan)}: ${x.kind.label} ${x.signature}');
          for (final d in x.definitions.where((d) => d.isAlter)) {
            o.writeln('${placeText(index, d.nameSpan)}: ALTER ${x.key.qualified}');
          }
        }
      }
      return found.isEmpty ? 1 : 0;
    case 'refs':
      final found = objects();
      if (found == null) return 2;
      if (json) {
        emit([for (final x in found) referencesJson(index, x, kind: kind)]);
      } else {
        for (final x in found) {
          for (final r in index.referencesTo(x.key)) {
            if (kind != null && r.kind.label != kind && r.kind.name != kind) continue;
            o.writeln(
              '${placeText(index, r.span)}: ${r.kind.label} ${x.key.qualified}'
              '${r.reference.from == null ? '' : ' in ${r.reference.from!.qualified}'}',
            );
          }
        }
      }
      return found.isEmpty ? 1 : 0;
    case 'graph':
      final found = objects();
      if (found == null) return 2;
      if (json) {
        emit([for (final x in found) graphJson(index, x)]);
      } else {
        for (final x in found) {
          final g = graphJson(index, x);
          o.writeln('${x.kind.label} ${x.key.qualified}');
          for (final n in g['usedBy']! as List) {
            final m = n as Map;
            o.writeln('  <- ${m['name']} (${(m['how'] as List).join(', ')})');
          }
          for (final n in g['uses']! as List) {
            final m = n as Map;
            o.writeln('  -> ${m['name']} (${(m['how'] as List).join(', ')})');
          }
        }
      }
      return found.isEmpty ? 1 : 0;
    case 'modules':
      final g = modulesJson(index);
      if (json) {
        emit(g);
      } else {
        for (final d in g['dependencies']! as List) {
          final m = d as Map;
          final bad = m['againstTheRules'] as int;
          o.writeln('${m['from']} -> ${m['to']}: ${m['uses']} uses${bad > 0 ? ', $bad against the rules' : ''}');
        }
      }
      return 0;
    case 'contract':
      final c = contractJson(index, module: arg);
      if (json) {
        emit(c);
      } else {
        for (final entry in c.entries) {
          o.writeln(entry.key);
          for (final s in entry.value! as List) {
            o.writeln('  $s');
          }
        }
      }
      return 0;
    case 'codes':
      final c = errorCodesJson(index, code: arg);
      if (json) {
        emit(c);
      } else {
        for (final entry in c.entries) {
          for (final u in entry.value! as List) {
            final m = u as Map;
            o.writeln('${m['file']}:${m['line']}:${m['column']}: ${entry.key} in ${m['in']}: ${m['description']}');
          }
        }
      }
      return 0;
    default:
      e.writeln('Unknown command: $command\n\n$usage');
      return 2;
  }
}

int _format(String root, bool checkOnly, bool json, IOSink o) {
  final options = FormatOptions.forFolder(root);
  final inMain = Git.filesInMain(root);
  final changed = <Map<String, Object?>>[];
  for (final f in Indexer.listSqlFiles(root)) {
    final file = File('$root/$f');
    final text = file.readAsStringSync();
    final r = formatSql(text, options: options, fileIsNew: inMain != null && !inMain.contains(f));
    if (r.text == text) continue;
    changed.add({'file': f, 'statements': r.formattedStatements});
    if (!checkOnly) file.writeAsStringSync(r.text);
  }
  if (json) {
    o.writeln(const JsonEncoder.withIndent('  ').convert(changed));
  } else {
    for (final c in changed) {
      o.writeln('${checkOnly ? 'would format' : 'formatted'} ${c['file']} (${c['statements']} statements)');
    }
    o.writeln('${changed.length} files ${checkOnly ? 'would change' : 'changed'}');
  }
  return checkOnly && changed.isNotEmpty ? 1 : 0;
}
