import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pg_studio/app/terminals.dart';

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('pg_term_');
    File(p.join(root.path, 'changelog', 'modules', 'a.sql'))
      ..createSync(recursive: true)
      ..writeAsStringSync('select 1;\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('paths with line and column in terminal output, relative to the shell directory', () {
    const line = 'changelog/modules/a.sql:12:5: error: syntax error at or near "," [syntax]';
    expect(Terminals.pathAt(line, 3, root.path, root.path), (path: 'changelog/modules/a.sql', line: 12, column: 5));
    // From a subfolder, and absolute.
    expect(Terminals.pathAt('M  a.sql', 4, p.join(root.path, 'changelog', 'modules'), root.path), (
      path: 'changelog/modules/a.sql',
      line: 1,
      column: 1,
    ));
    final abs = '${root.path}/changelog/modules/a.sql:7';
    expect(Terminals.pathAt(abs, 2, '/', root.path), (path: 'changelog/modules/a.sql', line: 7, column: 1));
    // Outside the path, a file that does not exist, a file outside the project.
    expect(Terminals.pathAt(line, 40, root.path, root.path), isNull);
    expect(Terminals.pathAt('changelog/nope.sql:3', 2, root.path, root.path), isNull);
    final outside = Directory.systemTemp.createTempSync('pg_term_out_');
    addTearDown(() => outside.deleteSync(recursive: true));
    File(p.join(outside.path, 'b.sql')).writeAsStringSync('');
    expect(Terminals.pathAt('${outside.path}/b.sql:2', 3, root.path, root.path), isNull);
  });
}
