// Formats every file of the folders in memory and reports: formatted statements, skips by reason, idempotency.
//   dart run tool/format_corpus.dart <folder>... [--show <file>]
import 'dart:io';

import 'package:pg_core/pg_core.dart';

void main(List<String> args) {
  final show = args.contains('--show') ? args[args.indexOf('--show') + 1] : null;
  for (final root in args.where((a) => !a.startsWith('--') && a != show)) {
    final files = Indexer.listSqlFiles(root);
    var formatted = 0;
    var changedFiles = 0;
    final notIdempotent = <String>[];
    final reasons = <String, int>{};
    final examples = <String, String>{};
    final watch = Stopwatch()..start();
    for (final f in files) {
      final text = File('$root/$f').readAsStringSync();
      final r = formatSql(text, options: FormatOptions.forFolder(root));
      formatted += r.formattedStatements;
      if (r.text != text) changedFiles++;
      for (final s in r.skipped) {
        final key = s.reason.split(':').first;
        reasons[key] = (reasons[key] ?? 0) + 1;
        examples.putIfAbsent(key, () => '$f: ${s.reason}');
      }
      final again = formatSql(r.text, options: FormatOptions.forFolder(root));
      if (again.text != r.text) notIdempotent.add(f);
      if (show != null && f.endsWith(show)) print(r.text);
    }
    print(
      '$root: ${files.length} files, $changedFiles changed, $formatted statements formatted, '
      '${watch.elapsedMilliseconds} ms; not idempotent: ${notIdempotent.length} ${notIdempotent.take(3)}',
    );
    for (final e in reasons.entries) {
      print('  skip ${e.value}x ${e.key}   e.g. ${examples[e.key]!.split('\n').first}');
    }
  }
}
