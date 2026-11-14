// Unresolved references grouped by message: dart run tool/unresolved.dart <folder>
import 'package:pg_core/pg_core.dart';

Future<void> main(List<String> args) async {
  final (index, _) = await Indexer.open(args.first);
  final groups = <String, List<String>>{};
  for (final p in index.problems.where((p) => p.code == 'unresolved')) {
    final line = index.files[p.span.file]!.lineColumn(p.span.start).$1 + 1;
    (groups[p.message] ??= []).add('${p.span.file}:$line');
  }
  final sorted = groups.entries.toList()..sort((a, b) => b.value.length.compareTo(a.value.length));
  print('${index.problems.where((p) => p.code == 'unresolved').length} unresolved in ${groups.length} names');
  for (final e in sorted) {
    print('${e.value.length.toString().padLeft(4)} ${e.key}  e.g. ${e.value.first}');
  }
}
