import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

final _fixture = p.join(Directory.current.path, 'test', 'fixtures', 'shop');
const _ddl = 'changelog/2026/1-ddl/20260101-01-sales-create-schemas-and-tables.sql';
const _alter = 'changelog/2026/1-ddl/20260101-02-sales-orders-add-note.sql';
const _grants = 'changelog/2026/1-ddl/20260101-03-grants.sql';
const _save = 'changelog/modules/10-sales/procedures/sales_app.order_save.sql';
const _total = 'changelog/modules/10-sales/functions/sales_app.order_total.sql';
const _view = 'changelog/modules/10-sales/views/sales_app.order_list.sql';

late ProjectIndex index;

String textOf(SourceSpan s) => File(p.join(_fixture, s.file)).readAsStringSync().substring(s.start, s.end);

/// 1-based line of a span.
int lineOf(SourceSpan s) => index.files[s.file]!.lineColumn(s.start).$1 + 1;

DbObject object(String qualified, [ObjectKind? kind]) =>
    index.objects.values.firstWhere((o) => o.key.qualified == qualified && (kind == null || o.kind == kind));

void main() {
  setUpAll(() async {
    index = (await Indexer.open(_fixture, workers: 2)).$1;
  });

  group('objects', () {
    test('every kind is recognized with its name span', () {
      final expected = {
        'sales': ObjectKind.schema,
        'sales.customers': ObjectKind.table,
        'sales.orders': ObjectKind.table,
        'sales_app.order_line_input': ObjectKind.type,
        'sales.orders_customer_ix': ObjectKind.tableIndex,
        'sales.order_numbers': ObjectKind.sequence,
        'pg_trgm': ObjectKind.extension,
        'sales.touch': ObjectKind.function,
        'sales.orders_touch': ObjectKind.trigger,
        'sales_app.order_save': ObjectKind.procedure,
        'sales_app.order_list': ObjectKind.view,
      };
      for (final e in expected.entries) {
        final o = object(e.key, e.value);
        expect(textOf(o.primary.nameSpan).toLowerCase(), endsWith(e.key.split('.').last), reason: e.key);
      }
    });

    test('a procedure has its parameters as written, modes and the changeset comment', () {
      final save = object('sales_app.order_save');
      expect(save.key.signature, 'uuid,uuid,sales_app.order_line_input[],int8');
      expect(
        save.signature,
        'sales_app.order_save(p_id uuid, p_customer_id uuid, p_lines sales_app.order_line_input[], INOUT p_row_version bigint)',
      );
      expect(save.primary.language, 'plpgsql');
      expect(save.primary.comment, 'Zapis zamówienia klienta z liniami.\nDruga linia komentarza.');
      expect(lineOf(save.primary.nameSpan), 8);
    });

    test('overloads are separate objects', () {
      final totals = index.objects.values.where((o) => o.key.qualified == 'sales_app.order_total').toList();
      expect(totals.map((o) => o.key.signature), unorderedEquals(['uuid', 'uuid,bool']));
      expect(totals.first.latest.returns, 'numeric');
    });

    test('ALTER TABLE in a later file is another place of the table and changes its columns', () {
      final orders = object('sales.orders');
      expect(orders.definitions.map((d) => (d.nameSpan.file, d.isAlter)), [(_ddl, false), (_alter, true)]);
      expect(orders.columns.map((c) => '${c.name} ${c.type}'), ['id uuid', 'customer_id uuid', 'note text']);
    });

    test('view columns come from the select list', () {
      expect(object('sales_app.order_list').columns.map((c) => c.name), ['id', 'customer_name', 'note']);
    });

    test('Liquibase properties keep their name in objects and references', () {
      final grants = index.files[_grants]!;
      expect(grants.problems, isEmpty);
      expect(index.referencesInFile(_grants).map((r) => (r.kind, textOf(r.span))), [
        (RefKind.grant, 'sales_app.order_save'),
        (RefKind.type, 'sales_app.order_line_input'),
        (RefKind.grant, 'sales_app.order_list'),
      ]);
    });
  });

  group('references', () {
    List<(RefKind, String, int)> uses(String qualified) => [
      for (final r in index.referencesTo(object(qualified).key)) (r.kind, r.span.file, lineOf(r.span)),
    ];

    test('reads, writes, foreign keys, indexes and triggers of a table', () {
      expect(
        uses('sales.orders'),
        unorderedEquals([
          (RefKind.indexOn, _ddl, 21),
          (RefKind.trigger, _alter, 18),
          (RefKind.type, _save, 20),
          (RefKind.read, _save, 26),
          (RefKind.write, _save, 28),
          (RefKind.write, _save, 30),
          (RefKind.read, _total, 8),
          (RefKind.read, _view, 7),
        ]),
      );
      expect(uses('sales.customers'), containsAll([(RefKind.foreignKey, _ddl, 15), (RefKind.read, _save, 23)]));
    });

    test('a call span covers the qualified name and resolves the overload by argument count', () {
      final calls = index.referencesInFile(_save).where((r) => r.kind == RefKind.call).toList();
      final total = calls.where((r) => textOf(r.span) == 'sales_app.order_total').toList();
      expect(total.map((r) => r.targets.single.signature), ['uuid', 'uuid,bool']);
      final inner = index.referencesInFile(_total).firstWhere((r) => r.kind == RefKind.call);
      expect(inner.targets.single.signature, 'uuid');
      expect(inner.reference.from!.signature, 'uuid,bool');
    });

    test('types of parameters and variables, the trigger function', () {
      expect(
        uses('sales_app.order_line_input'),
        unorderedEquals([(RefKind.type, _save, 11), (RefKind.type, _save, 19), (RefKind.type, _grants, 4)]),
      );
      expect(uses('sales.touch'), [(RefKind.trigger, _alter, 18)]);
    });

    test('what a procedure uses', () {
      final used = index
          .referencesFrom(object('sales_app.order_save').key)
          .expand((r) => r.targets)
          .map((k) => k.qualified)
          .toSet();
      expect(used, {'sales_app.order_line_input', 'sales.orders', 'sales.customers', 'sales_app.order_total'});
    });

    test('referenceAt and definitionAt find what is under the cursor', () {
      final call = index.referencesInFile(_save).firstWhere((r) => textOf(r.span) == 'sales_app.order_total');
      expect(index.referenceAt(_save, call.span.start + 3), same(call));
      final def = object('sales_app.order_save').primary.nameSpan;
      expect(index.definitionAt(_save, def.start + 1)!.key.qualified, 'sales_app.order_save');
      expect(index.enclosingDefinition(_save, call.span.start)!.key.qualified, 'sales_app.order_save');
    });
  });

  group('problems', () {
    test('a syntax error stays in its changeset, the rest of the file is indexed', () {
      final errors = index.problems.where((p) => p.severity == Severity.error).toList();
      expect(errors, hasLength(1));
      expect(errors.single.span.file, _alter);
      expect(lineOf(errors.single.span), 9);
      expect(object('sales.touch').primary.nameSpan.file, _alter);
    });

    test('an unknown qualified call in a project schema is a warning; built-ins and variables are not', () {
      final warnings = index.problems.where((p) => p.code == 'unresolved').toList();
      expect(warnings.map((w) => (textOf(w.span), lineOf(w.span))), [('sales_app.missing_proc', 34)]);
    });

    test('a psql script parses with its meta-commands and variables', () {
      final script = index.files['scripts/volume.sql']!;
      expect(script.isPsqlScript, isTrue);
      expect(script.problems, isEmpty);
      expect(index.referencesInFile('scripts/volume.sql').map((r) => (r.kind, textOf(r.span))), [
        (RefKind.write, 'sales.customers'),
      ]);
    });

    test('a PL/pgSQL error is located in the body', () {
      final a = analyzeFile('x.sql', r'''CREATE FUNCTION s.f() RETURNS int LANGUAGE plpgsql AS $$
DECLARE v s.t;
BEGIN
  v := 1;
  IF v > 1 THEN
    RETURN 1
  END IF;
END $$;''');
      final error = a.problems.single;
      expect(error.code, 'plpgsql');
      expect(a.lineColumn(error.span.start).$1 + 1, 7);
    });
  });

  group('error codes', () {
    test('ERRCODE with the comment that describes it', () {
      final codes = index.files[_save]!.errorCodes;
      expect(codes.map((c) => (c.code, c.description, c.from!.qualified)), [
        ('U1101', 'U1101 (404): klient nie istnieje.', 'sales_app.order_save'),
      ]);
    });
  });

  group('folder', () {
    test('files are in changelog order', () {
      expect(index.order.take(3), [_ddl, _alter, _grants]);
      expect(index.order.last, 'scripts/volume.sql');
    });

    test('update re-analyses a changed text and re-links', () async {
      final text = File(p.join(_fixture, _view))
          .readAsStringSync()
          .replaceFirst('JOIN sales.customers', 'JOIN sales.nope');
      final updated = await Indexer.update(index, [_view], texts: {_view: text});
      final unresolved = updated.problems.where((p) => p.code == 'unresolved' && p.span.file == _view);
      expect(unresolved.map((p) => text.substring(p.span.start, p.span.end)), ['sales.nope']);
      expect(updated.referencesTo(object('sales.customers').key).where((r) => r.span.file == _view), isEmpty);
    });
  });
}
