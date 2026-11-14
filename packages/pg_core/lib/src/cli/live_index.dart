import 'dart:io';

import 'package:path/path.dart' as p;

import '../index/indexer.dart';
import '../index/project_index.dart';

/// An index kept up to date with the folder: before each use the modification times are compared and only changed,
/// added or removed files are analysed again (the MCP server answers an agent that keeps writing files).
class LiveIndex {
  LiveIndex(this.root);

  final String root;
  ProjectIndex? _index;
  Map<String, DateTime> _stamps = {};

  Future<ProjectIndex> get() async {
    final now = _scan();
    final index = _index;
    if (index == null) {
      _index = (await Indexer.open(root)).$1;
    } else {
      final changed = {
        for (final e in now.entries)
          if (_stamps[e.key] != e.value) e.key,
        for (final old in _stamps.keys)
          if (!now.containsKey(old)) old,
      };
      if (changed.isNotEmpty) _index = await Indexer.update(index, changed);
    }
    _stamps = now;
    return _index!;
  }

  Map<String, DateTime> _scan() => {
    for (final f in Indexer.listSqlFiles(root)) f: File(p.join(root, f)).statSync().modified,
  };
}
