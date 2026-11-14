// Formatting the real folders in memory (read only): what spec 2.0/001 promises.
@Tags(['corpus'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pg_core/pg_core.dart';
import 'package:test/test.dart';

final _repos = p.normalize(p.join(Directory.current.path, '..', '..', '..'));

List<String> tokens(String s) {
  final out = <String>[];
  for (final t in PgQuery.scan(s)) {
    final raw = s.substring(t.start, t.end);
    if (t.name == 'SCONST' && raw.startsWith(r'$')) {
      final tag = raw.substring(0, raw.indexOf(r'$', 1) + 1);
      out
        ..add(tag)
        ..addAll(tokens(raw.substring(tag.length, raw.length - tag.length)));
    } else {
      out.add(raw.trimRight());
    }
  }
  return out;
}

void main() {
  for (final name in ['ambit.jobtron.app/db', 'ambit.wms.app/db', 'halycon.app.dev/db/changelog']) {
    final root = p.join(_repos, name);
    test(
      '$name: meaning kept, deployed changesets untouched, idempotent, no guard rejections',
      () {
        var changed = 0;
        var statements = 0;
        var deployed = 0;
        final rejected = <String>[];
        final watch = Stopwatch()..start();
        for (final f in Indexer.listSqlFiles(root)) {
          final text = File(p.join(root, f)).readAsStringSync();
          final r = formatSql(text);
          statements += r.formattedStatements;
          for (final s in r.skipped) {
            if (s.reason.contains('without runOnChange')) {
              deployed++;
              expect(r.text.contains(text.substring(s.start, s.end)), isTrue, reason: '$f: deployed changeset changed');
            } else if (!s.reason.contains('psql script')) {
              rejected.add('$f: ${s.reason}');
            }
          }
          if (r.text == text) continue;
          changed++;
          expect(tokens(r.text), tokens(text), reason: '$f: only whitespace may change');
          expect(formatSql(r.text).text, r.text, reason: '$f: not idempotent');
        }
        print(
          '$name: $changed files changed, $statements statements formatted, $deployed deployed changesets left as '
          'they are, ${rejected.length} rejected, ${watch.elapsedMilliseconds} ms',
        );
        expect(rejected, isEmpty);
      },
      skip: Directory(root).existsSync() ? false : 'missing $root',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
