import 'dart:io';

import 'package:pg_core/cli.dart';

Future<void> main(List<String> args) async {
  final code = await runCli(args);
  await stdout.flush();
  exit(code);
}
