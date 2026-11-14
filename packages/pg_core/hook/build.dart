// Builds libpg_query (vendored as the git submodule third_party/libpg_query, tag 18.1.0) with its own Makefile and
// bundles the shared library as the code asset of package:pg_core/src/pg_query/bindings.dart (ADR 0001).
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const _version = '18.1.0';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    if (input.config.code.targetOS != OS.linux) {
      throw UnsupportedError('pg_core builds libpg_query for Linux only (ADR 0001).');
    }
    final source = Directory.fromUri(input.packageRoot.resolve('../../third_party/libpg_query/'));
    if (!File.fromUri(source.uri.resolve('Makefile')).existsSync()) {
      throw StateError('Missing ${source.path} - run: git submodule update --init');
    }
    // A copy in the shared output directory: make writes objects next to the sources, the submodule stays clean,
    // and the build (about 10 s) runs once per version.
    final work = Directory.fromUri(input.outputDirectoryShared.resolve('libpg_query-$_version/'));
    final library = File.fromUri(work.uri.resolve('libpg_query.so'));
    if (!library.existsSync()) {
      if (work.existsSync()) work.deleteSync(recursive: true);
      work.createSync(recursive: true);
      final copy = await Process.run('cp', ['-a', '${source.path}.', work.path]);
      if (copy.exitCode != 0) throw StateError('cp failed: ${copy.stderr}');
      final gitFile = File.fromUri(work.uri.resolve('.git'));
      if (gitFile.existsSync()) gitFile.deleteSync();
      final make = await Process.run('make', [
        '-j${Platform.numberOfProcessors}',
        'build_shared',
      ], workingDirectory: work.path);
      if (make.exitCode != 0 || !library.existsSync()) {
        throw StateError('make build_shared failed (${make.exitCode}):\n${make.stderr}');
      }
    }
    output.dependencies.add(source.uri.resolve('Makefile'));
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/pg_query/bindings.dart',
        linkMode: DynamicLoadingBundled(),
        file: library.uri,
      ),
    );
  });
}
