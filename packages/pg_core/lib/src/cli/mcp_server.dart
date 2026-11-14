// A Model Context Protocol server over stdio (JSON-RPC 2.0, one message per line) that answers questions about a
// database folder from the index - for Claude Code: definitions and references instead of grep (2.0 spec 011).
//   claude mcp add pg-studio -- pg-studio-cli mcp /path/to/db
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../format/formatter.dart';
import '../git.dart';
import '../index/indexer.dart';
import '../index/project_index.dart';
import 'live_index.dart';
import 'queries.dart';

const serverVersion = '3.1.0';
const _protocolVersions = ['2025-06-18', '2025-03-26', '2024-11-05'];

final class McpTool {
  const McpTool(this.name, this.description, this.properties, [this.required = const []]);

  final String name;
  final String description;
  final Map<String, Object?> properties;
  final List<String> required;

  Map<String, Object?> get json => {
    'name': name,
    'description': description,
    'inputSchema': {'type': 'object', 'properties': properties, 'required': required},
  };
}

const _name = {'type': 'string', 'description': 'schema.name, or name to match in every schema (all overloads).'};

const tools = [
  McpTool(
    'problems',
    'Problems of the database folder: syntax errors, unresolved names in the project schemas, uses '
        'across module boundaries (check-module-changesets.sh rules), ERRCODE inconsistencies. Each with file:line.',
    {
      'severity': {
        'type': 'string',
        'enum': ['error', 'warning', 'all'],
        'description': 'Default all.',
      },
      'file': {'type': 'string', 'description': 'Only this file (path relative to the folder).'},
    },
  ),
  McpTool(
    'definition',
    'Where an object (table, view, function, procedure, type, ...) is defined, its signature, '
        'columns, the changeset comment and every ALTER of it.',
    {'name': _name},
    ['name'],
  ),
  McpTool(
    'references',
    'Every use of an object with file:line and how (call, read, write, type, foreign key, '
        'trigger, index, grant, ...) and in which object it is used.',
    {
      'name': _name,
      'kind': {'type': 'string', 'description': 'Only this kind of use, e.g. write.'},
    },
    ['name'],
  ),
  McpTool('graph', 'What an object uses and what uses it (one level), with how.', {'name': _name}, ['name']),
  McpTool(
    'modules',
    'Modules (changelog/modules/<nn>-<module>) and their dependencies, with uses against the rules.',
    {},
  ),
  McpTool('contract', 'The API contract: <module>_app objects with signatures, per module.', {
    'module': {'type': 'string', 'description': 'Module name or nn-name; default all.'},
  }),
  McpTool('error_codes', 'ERRCODE values raised in the project, each place with the comment describing it.', {
    'code': {'type': 'string', 'description': 'One code, e.g. U1445.'},
  }),
  McpTool(
    'format_check',
    'Files the formatter would change (whitespace only; deployed changesets are never touched).',
    {
      'file': {'type': 'string', 'description': 'One file (relative path); default the whole folder.'},
    },
  ),
];

class McpServer {
  McpServer(String root) : live = LiveIndex(root);

  final LiveIndex live;

  /// Handles one message; null for notifications (no response).
  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    final id = message['id'];
    final method = message['method'];
    final params = (message['params'] as Map?)?.cast<String, Object?>() ?? const {};
    if (method is! String) return _error(id, -32600, 'Invalid request'); // JSON-RPC: answered even without an id
    if (id == null) return null; // notifications/initialized and the like
    try {
      switch (method) {
        case 'initialize':
          final asked = params['protocolVersion'] as String?;
          return _result(id, {
            'protocolVersion': _protocolVersions.contains(asked) ? asked : _protocolVersions.first,
            'capabilities': {'tools': <String, Object?>{}},
            'serverInfo': {'name': 'pg-studio', 'version': serverVersion},
            'instructions':
                'PG Studio answers from an offline index of the PostgreSQL database folder ${live.root} '
                '(SQL files, Liquibase changesets). Prefer definition/references/graph over grep for database objects; '
                'problems after editing SQL; format_check before committing.',
          });
        case 'ping':
          return _result(id, {});
        case 'tools/list':
          return _result(id, {
            'tools': [for (final t in tools) t.json],
          });
        case 'tools/call':
          final name = params['name'] as String?;
          final args = (params['arguments'] as Map?)?.cast<String, Object?>() ?? const {};
          return _result(id, await _call(name, args));
        default:
          return _error(id, -32601, 'Method not found: $method');
      }
    } on Object catch (e) {
      return _error(id, -32603, 'Internal error: $e');
    }
  }

  Future<Map<String, Object?>> _call(String? name, Map<String, Object?> args) async {
    final index = await live.get();
    Object? answer;
    String? notFound;
    final objectName = args['name'] as String?;
    final objects = objectName == null ? const <DbObject>[] : findObjects(index, objectName);
    switch (name) {
      case 'problems':
        answer = [
          for (final p in problems(
            index,
            severity: (args['severity'] as String?) ?? 'all',
            file: args['file'] as String?,
          ))
            problemJson(index, p),
        ];
      case 'definition':
        answer = [for (final o in objects) objectJson(index, o)];
      case 'references':
        answer = [for (final o in objects) referencesJson(index, o, kind: args['kind'] as String?)];
      case 'graph':
        answer = [for (final o in objects) graphJson(index, o)];
      case 'modules':
        answer = modulesJson(index);
      case 'contract':
        answer = contractJson(index, module: args['module'] as String?);
      case 'error_codes':
        answer = errorCodesJson(index, code: args['code'] as String?);
      case 'format_check':
        answer = formatCheck(live.root, only: args['file'] as String?);
      default:
        return {
          'content': [
            {'type': 'text', 'text': 'Unknown tool: $name'},
          ],
          'isError': true,
        };
    }
    if (objectName != null && objects.isEmpty) notFound = 'No object named $objectName in ${live.root}.';
    return {
      'content': [
        {'type': 'text', 'text': notFound ?? const JsonEncoder.withIndent('  ').convert(answer)},
      ],
      'isError': notFound != null,
    };
  }

  /// Reads messages from [input] line by line and writes the responses to [output] until the input ends.
  Future<void> serve(Stream<List<int>> input, IOSink output) async {
    final lines = input.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      Map<String, Object?>? response;
      try {
        final message = jsonDecode(line);
        if (message is! Map) {
          response = _error(null, -32600, 'Invalid request');
        } else {
          response = await handle(message.cast<String, Object?>());
        }
      } on FormatException {
        response = _error(null, -32700, 'Parse error');
      }
      if (response != null) {
        output.writeln(jsonEncode(response));
        await output.flush();
      }
    }
  }

  static Map<String, Object?> _result(Object? id, Object? result) => {'jsonrpc': '2.0', 'id': id, 'result': result};

  static Map<String, Object?> _error(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };
}

/// Files [formatSql] would change, with the reasons for parts left as written. Files not in the main branch are new.
List<Map<String, Object?>> formatCheck(String root, {String? only}) {
  final options = FormatOptions.forFolder(root);
  final inMain = Git.filesInMain(root);
  final out = <Map<String, Object?>>[];
  for (final f in Indexer.listSqlFiles(root)) {
    if (only != null && f != only && !f.endsWith('/$only')) continue;
    final text = File('$root/$f').readAsStringSync();
    final r = formatSql(text, options: options, fileIsNew: inMain != null && !inMain.contains(f));
    if (r.text != text) out.add({'file': f, 'statements': r.formattedStatements});
  }
  return out;
}
