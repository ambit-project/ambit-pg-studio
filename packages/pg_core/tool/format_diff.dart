// Which files a format changes, by kind of the changed statement; with --diff <n>, writes the first n pairs to a dir.
import 'dart:io';

import 'package:pg_core/pg_core.dart';

void main(List<String> args) {
  final root = args.first;
  final out = args.length > 1 ? args[1] : null;
  final byFolder = <String, int>{};
  var n = 0;
  for (final f in Indexer.listSqlFiles(root)) {
    final text = File('$root/$f').readAsStringSync();
    final r = formatSql(text, options: FormatOptions.forFolder(root));
    if (r.text == text) continue;
    final kind = f.split('/').reversed.skip(1).first;
    byFolder[kind] = (byFolder[kind] ?? 0) + 1;
    if (out != null && n < 6) {
      File('$out/${n}_a.sql').writeAsStringSync(text);
      File('$out/${n}_b.sql').writeAsStringSync(r.text);
      n++;
    }
  }
  print(byFolder);
}
