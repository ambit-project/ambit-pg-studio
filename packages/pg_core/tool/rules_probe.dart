import 'package:pg_core/pg_core.dart';

Future<void> main(List<String> args) async {
  for (final root in args) {
    final (index, _) = await Indexer.open(root);
    final rules = index.allProblems.where((p) => p.code == 'module-rule').toList();
    print('$root: ${rules.length} module-rule problems');
    for (final p in rules.take(10)) {
      print('  ${p.message}');
    }
  }
}
