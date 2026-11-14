import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/cli.dart';
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

final _shop = p.join(Directory.current.path, 'test', 'fixtures', 'shop');
final _modules = p.join(Directory.current.path, 'test', 'fixtures', 'modules');

/// Runs the CLI in process; returns (exit code, stdout, stderr).
Future<(int, String, String)> cli(List<String> args) async {
  final out = _Capture();
  final err = _Capture();
  final code = await runCli(args, out: out.sink, err: err.sink);
  await out.sink.flush();
  await err.sink.flush();
  return (code, out.text, err.text);
}

class _Capture {
  _Capture() {
    sink = IOSink(_controller.sink);
    _controller.stream.listen(_buffer.addAll);
  }

  final _controller = StreamController<List<int>>();
  final _buffer = <int>[];
  late final IOSink sink;

  String get text => utf8.decode(_buffer);
}

Directory copy(String fixture) {
  final dir = Directory.systemTemp.createTempSync('pg_cli_');
  Process.runSync('cp', ['-r', '$fixture/.', dir.path]);
  return dir;
}

void main() {
  group('commands', () {
    test('check: file:line:column lines, exit 1 on an error; --json = the Problems panel', () async {
      final (code, out, _) = await cli(['check', _shop]);
      expect(code, 1);
      expect(out, contains('changelog/2026/1-ddl/20260101-02-sales-orders-add-note.sql:9:36: error: syntax error'));
      expect(out, contains('sales_app.order_save.sql:34:10: warning: routine sales_app.missing_proc is not defined'));
      final (_, json, _) = await cli(['check', _shop, '--json']);
      final index = (await Indexer.open(_shop)).$1;
      expect((jsonDecode(json) as List).length, index.allProblems.length);
    });

    test('check --strict fails on warnings; a clean folder exits 0', () async {
      final dir = copy(_shop);
      addTearDown(() => dir.deleteSync(recursive: true));
      final broken = File(p.join(dir.path, 'changelog/2026/1-ddl/20260101-02-sales-orders-add-note.sql'));
      broken.writeAsStringSync(broken.readAsStringSync().replaceFirst('(id uuid,, name text)', '(id uuid, name text)'));
      expect((await cli(['check', dir.path])).$1, 0);
      expect((await cli(['check', dir.path, '--strict'])).$1, 1);
    });

    test('def, refs --kind, graph', () async {
      final (_, def, _) = await cli(['def', _shop, 'sales.orders']);
      expect(def, contains('20260101-01-sales-create-schemas-and-tables.sql:13:14: table sales.orders'));
      expect(def, contains('20260101-02-sales-orders-add-note.sql:5:13: ALTER sales.orders'));
      final (_, refs, _) = await cli(['refs', _shop, 'sales.orders', '--kind', 'write']);
      expect(refs.trim().split('\n'), hasLength(2));
      expect(refs, contains('write sales.orders in sales_app.order_save'));
      final (_, graph, _) = await cli(['graph', _shop, 'order_total']);
      expect(graph, contains('<- sales_app.order_save (call)'));
      final (missing, _, err) = await cli(['def', _shop, 'nope.nothing']);
      expect(missing, 1);
      expect(err, contains('No object named nope.nothing'));
    });

    test('modules, contract, codes', () async {
      final (_, modules, _) = await cli(['modules', _modules]);
      expect(modules, contains('20-orders -> 30-billing: 2 uses, 2 against the rules'));
      final (_, contract, _) = await cli(['contract', _modules, 'orders']);
      expect(
        contract,
        'orders_app\n  orders_app.order_cancel(p_id uuid)\n  orders_app.order_save(p_id uuid, p_customer_id uuid)\n',
      );
      final (_, codes, _) = await cli(['codes', _modules, 'U1101']);
      expect(codes.trim().split('\n'), hasLength(2));
    });

    test('format --check lists and exits 1, format writes, then --check exits 0', () async {
      final dir = copy(_shop);
      addTearDown(() => dir.deleteSync(recursive: true));
      const view = 'changelog/modules/10-sales/views/sales_app.order_list.sql';
      final file = File(p.join(dir.path, view));
      file.writeAsStringSync(
        file.readAsStringSync().replaceFirst('FROM sales.orders AS o', '      FROM sales.orders AS o'),
      );
      final (code, out, _) = await cli(['format', dir.path, '--check']);
      expect(code, 1);
      expect(out, contains('would format $view'));
      expect((await cli(['format', dir.path])).$1, 0);
      expect(file.readAsStringSync(), contains('\nFROM sales.orders AS o'));
      expect((await cli(['format', dir.path, '--check'])).$1, 0);
    });

    test('usage errors exit 2', () async {
      expect((await cli([])).$1, 2);
      expect((await cli(['check'])).$1, 2);
      expect((await cli(['check', '/no/such/folder'])).$1, 2);
      expect((await cli(['frobnicate', _shop])).$1, 2);
    });
  });

  group('MCP', () {
    Future<Map<String, Object?>> call(McpServer s, int id, String method, [Map<String, Object?>? params]) async =>
        (await s.handle({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params}))!;

    Object? toolJson(Map<String, Object?> response) {
      final content = ((response['result'] as Map)['content'] as List).first as Map;
      return jsonDecode(content['text'] as String);
    }

    test('initialize, tools/list and the tools', () async {
      final s = McpServer(_shop);
      final init = await call(s, 1, 'initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}});
      expect((init['result'] as Map)['serverInfo'], {'name': 'pg-studio', 'version': serverVersion});
      expect(await s.handle({'jsonrpc': '2.0', 'method': 'notifications/initialized'}), isNull);
      final list = await call(s, 2, 'tools/list');
      expect(
        [for (final t in (list['result'] as Map)['tools'] as List) (t as Map)['name']],
        ['problems', 'definition', 'references', 'graph', 'modules', 'contract', 'error_codes', 'format_check'],
      );
      final refs = toolJson(
        await call(s, 3, 'tools/call', {
          'name': 'references',
          'arguments': {'name': 'sales.customers'},
        }),
      );
      final first = (refs as List).first as Map;
      expect(first['count'], greaterThanOrEqualTo(2));
      expect((first['references'] as List).map((r) => (r as Map)['kind']), contains('foreign key'));
      final problems = toolJson(
        await call(s, 4, 'tools/call', {
          'name': 'problems',
          'arguments': {'severity': 'error'},
        }),
      );
      expect((problems as List).single, containsPair('line', 9));
      final def = toolJson(
        await call(s, 5, 'tools/call', {
          'name': 'definition',
          'arguments': {'name': 'order_save'},
        }),
      );
      expect(((def as List).single as Map)['signature'], startsWith('sales_app.order_save(p_id uuid'));
    });

    test('errors: unknown object, unknown tool, unknown method', () async {
      final s = McpServer(_shop);
      final missing = await call(s, 1, 'tools/call', {
        'name': 'definition',
        'arguments': {'name': 'x.y'},
      });
      expect((missing['result'] as Map)['isError'], isTrue);
      final unknown = await call(s, 2, 'tools/call', {'name': 'nope', 'arguments': {}});
      expect((unknown['result'] as Map)['isError'], isTrue);
      expect(((await call(s, 3, 'resources/list'))['error'] as Map)['code'], -32601);
    });

    test('over stdio as a process; the index follows files written during the session', () async {
      final dir = copy(_shop);
      addTearDown(() => dir.deleteSync(recursive: true));
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        'bin/pg_studio_cli.dart',
        'mcp',
        dir.path,
      ]);
      addTearDown(process.kill);
      final responses = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()).where((l) => l.startsWith('{')),
      );
      Future<Map<String, Object?>> send(Map<String, Object?> m) async {
        process.stdin.writeln(jsonEncode(m));
        await process.stdin.flush();
        expect(await responses.moveNext().timeout(const Duration(seconds: 60)), isTrue);
        return (jsonDecode(responses.current) as Map).cast<String, Object?>();
      }

      final init = await send({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': '2025-06-18'},
      });
      expect((init['result'] as Map)['protocolVersion'], '2025-06-18');
      process.stdin.writeln(jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
      final before = toolJson(
        await send({
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'tools/call',
          'params': {
            'name': 'references',
            'arguments': {'name': 'sales.customers'},
          },
        }),
      );
      final count = ((before as List).first as Map)['count'] as int;
      // An agent writes a new view that reads the table.
      File(p.join(dir.path, 'changelog/modules/10-sales/views/sales_app.customer_list.sql'))
          .writeAsStringSync('CREATE VIEW sales_app.customer_list AS SELECT c.id FROM sales.customers AS c;\n');
      final after = toolJson(
        await send({
          'jsonrpc': '2.0',
          'id': 3,
          'method': 'tools/call',
          'params': {
            'name': 'references',
            'arguments': {'name': 'sales.customers'},
          },
        }),
      );
      expect(((after as List).first as Map)['count'], count + 1);
      final parse = await send({'garbage': true});
      expect((parse['error'] as Map)['code'], -32600);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('real folders', () {
    final repos = p.normalize(p.join(Directory.current.path, '..', '..', '..'));
    for (final name in ['ambit.jobtron.app/db', 'ambit.wms.app/db', 'halycon.app.dev/db/changelog']) {
      final root = p.join(repos, name);
      test(
        '$name: check = the Problems panel',
        () async {
          final (code, json, _) = await cli(['check', root, '--json']);
          final index = (await Indexer.open(root)).$1;
          final list = jsonDecode(json) as List;
          print('$name: check exit $code, ${list.length} problems, panel ${index.allProblems.length}');
          expect(list.length, index.allProblems.length);
          expect(code, index.allProblems.any((x) => x.severity == Severity.error) ? 1 : 0);
        },
        tags: ['corpus'],
        skip: Directory(root).existsSync() ? false : 'missing $root',
      );
    }
  });
}
