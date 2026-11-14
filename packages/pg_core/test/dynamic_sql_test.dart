import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

const _ddl = '''--liquibase formatted sql
--changeset dev:20260101-01
CREATE SCHEMA shop;
CREATE TABLE shop.orders (id bigint PRIMARY KEY, note text);
CREATE TABLE shop.order_log (id bigint, what text);
CREATE FUNCTION shop.order_total(p_id bigint) RETURNS numeric LANGUAGE sql AS \$\$ SELECT 1 \$\$;
''';

const _proc = r'''--liquibase formatted sql
--changeset dev:shop.order_purge runOnChange:true splitStatements:false
CREATE OR REPLACE PROCEDURE shop.order_purge(p_table text, p_id bigint)
LANGUAGE plpgsql AS $$
DECLARE
  v_n bigint;
BEGIN
  EXECUTE format('DELETE FROM shop.orders WHERE id = %L', p_id);
  EXECUTE 'INSERT INTO shop.order_log (id, what) VALUES ($1, ''purge'')' USING p_id;
  EXECUTE format('SELECT count(*) FROM %I.%I WHERE note = %1$L', 'shop', p_table) INTO v_n;
  EXECUTE format($q$SELECT shop.order_total(%s) FROM shop.orders$q$, p_id) INTO v_n;
  EXECUTE 'UPDATE shop.orders SET note = ''x'' WHERE id = ' || p_id;
  RAISE NOTICE '%', 'SELECT * FROM shop.not_scanned';
  EXECUTE format('SELECT 1 FROM shop.missing_table');
END;
$$;
''';

void main() {
  late ProjectIndex index;
  setUpAll(() async {
    final dir = Directory.systemTemp.createTempSync('pg_dynamic_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, 'ddl.sql')).writeAsStringSync(_ddl);
    File(p.join(dir.path, 'order_purge.sql')).writeAsStringSync(_proc);
    index = (await Indexer.open(dir.path)).$1;
  });

  String text(SourceSpan s) => index.files[s.file]!.text.substring(s.start, s.end);
  int line(SourceSpan s) => index.files[s.file]!.lineColumn(s.start).$1 + 1;

  test('constant texts of EXECUTE and format() are references with the kind from their SQL context', () {
    final dynamic = [
      for (final r in index.references)
        if (r.reference.dynamic)
          '${line(r.span)} ${r.kind.name} ${text(r.span)} -> ${r.targets.map((k) => k.qualified).join(',')}',
    ];
    expect(dynamic, [
      '8 write shop.orders -> shop.orders',
      '9 write shop.order_log -> shop.order_log',
      '11 call shop.order_total -> shop.order_total',
      '11 read shop.orders -> shop.orders',
      '12 write shop.orders -> shop.orders',
    ]);
  });

  test('find references of a table includes dynamic SQL; unresolved dynamic names are not problems', () {
    final orders = index.objects.keys.firstWhere((k) => k.qualified == 'shop.orders');
    expect(index.referencesTo(orders).where((r) => r.reference.dynamic).length, 3);
    expect(index.allProblems.where((pr) => pr.message.contains('missing_table')), isEmpty);
    // %I.%I and literals outside EXECUTE/format (RAISE) are not scanned.
    expect(index.references.where((r) => text(r.span).contains('not_scanned')), isEmpty);
  });
}
