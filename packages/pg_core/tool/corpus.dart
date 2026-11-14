// Indexes folders and prints counts, timing and problems: dart run tool/corpus.dart <folder>...
import 'package:pg_core/pg_core.dart';

Future<void> main(List<String> args) async {
  for (final root in args) {
    final (index, timing) = await Indexer.open(root);
    final byCode = <String, int>{};
    for (final p in index.problems) {
      byCode[p.code ?? '?'] = (byCode[p.code ?? '?'] ?? 0) + 1;
    }
    final kinds = <String, int>{};
    for (final o in index.objects.values) {
      kinds[o.kind.label] = (kinds[o.kind.label] ?? 0) + 1;
    }
    print('$root: $timing');
    print('  objects ${index.objects.length} $kinds');
    print('  references ${index.references.length}, problems $byCode');
    for (final p in index.problems.where((p) => p.severity == Severity.error).take(15)) {
      print(
        '  ERR ${p.span.file}:${index.files[p.span.file]!.lineColumn(p.span.start).$1 + 1} ${p.message.split('\n').first}',
      );
    }
    for (final p in index.problems.where((p) => p.code == 'unresolved').take(15)) {
      print('  WARN ${p.span.file}:${index.files[p.span.file]!.lineColumn(p.span.start).$1 + 1} ${p.message}');
    }
  }
}
