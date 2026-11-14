// Phase 1 cache (2.0 spec 013): one JSON file per analysed file in `$XDG_CACHE_HOME/pg_studio/phase1-v<N>/`
// (default `~/.cache/...`), named by a hash of the path, the text and [analysisVersion]. A changed file has another
// hash, so it is analysed again; entries not used for [maxAge] are removed.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../model.dart';

/// Bump when phase 1 (extract, body scan, the model) changes what it produces: old entries are then ignored.
const analysisVersion = 1;
const maxAge = Duration(days: 14);

final class Phase1Cache {
  Phase1Cache(this.dir);

  /// The folder of this [analysisVersion].
  final String dir;

  static String defaultRoot() {
    final env = Platform.environment;
    final base = env['XDG_CACHE_HOME']?.isNotEmpty == true
        ? env['XDG_CACHE_HOME']!
        : p.join(env['HOME'] ?? Directory.systemTemp.path, '.cache');
    return p.join(base, 'pg_studio');
  }

  /// The cache under [root] (default [defaultRoot]).
  factory Phase1Cache.at([String? root]) => Phase1Cache(p.join(root ?? defaultRoot(), 'phase1-v$analysisVersion'));

  String _file(String path, String text) => p.join(dir, '${_fnv('$analysisVersion\u0000$path\u0000$text')}.json');

  /// The cached analysis of [path] with [text], or null.
  FileAnalysis? read(String path, String text) {
    final file = File(_file(path, text));
    try {
      if (!file.existsSync()) return null;
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      if (json['path'] != path) return null;
      // Touch it, so pruning keeps entries that are still used.
      file.setLastModifiedSync(DateTime.now());
      return decodeAnalysis(json, text);
    } on Object {
      return null;
    }
  }

  void write(FileAnalysis analysis, String text) {
    try {
      Directory(dir).createSync(recursive: true);
      final file = File(_file(analysis.path, text));
      final tmp = File('${file.path}.$pid.tmp');
      tmp.writeAsStringSync(jsonEncode(encodeAnalysis(analysis)));
      tmp.renameSync(file.path);
    } on Object {
      // The cache only saves time.
    }
  }

  /// Removes entries older than [maxAge] and the folders of other analysis versions; at most once a day.
  void prune() {
    try {
      final stamp = File(p.join(dir, '.pruned'));
      if (stamp.existsSync() && DateTime.now().difference(stamp.lastModifiedSync()) < const Duration(days: 1)) return;
      final root = Directory(p.dirname(dir));
      if (!root.existsSync()) return;
      for (final e in root.listSync()) {
        if (e is Directory && p.basename(e.path).startsWith('phase1-v') && e.path != dir) {
          e.deleteSync(recursive: true);
        }
      }
      final own = Directory(dir);
      if (!own.existsSync()) return;
      final limit = DateTime.now().subtract(maxAge);
      for (final e in own.listSync()) {
        if (e is File && e.path != stamp.path && e.statSync().modified.isBefore(limit)) e.deleteSync();
      }
      stamp.writeAsStringSync('');
    } on Object {
      // Ignored, see write.
    }
  }
}

/// 64-bit FNV-1a of the UTF-16 code units, as 16 hex digits (stable across runs, unlike String.hashCode).
String _fnv(String s) {
  var h = 0xcbf29ce484222325;
  for (var i = 0; i < s.length; i++) {
    h ^= s.codeUnitAt(i);
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

// The codec: short keys, spans as [start, end] (the file is the analysis path).

Map<String, Object?> encodeAnalysis(FileAnalysis a) => {
  'path': a.path,
  'psql': a.isPsqlScript,
  'changesets': [
    for (final c in a.changesets) [c.author, c.id, c.line, c.comment, c.start, c.end, c.attributes],
  ],
  'definitions': [for (final d in a.definitions) _definition(a.path, d)],
  'references': [for (final r in a.references) _reference(a.path, r)],
  'problems': [
    for (final x in a.problems) [x.severity.index, x.message, _span(a.path, x.span), x.code, x.fix],
  ],
  'errorCodes': [
    for (final e in a.errorCodes) [e.code, _span(a.path, e.span), e.description, _key(e.from)],
  ],
};

FileAnalysis decodeAnalysis(Map<String, Object?> j, String text) {
  final path = j['path']! as String;
  SourceSpan span(Object? s) {
    final l = s! as List<Object?>;
    return SourceSpan(l.length > 2 ? l[2] as String : path, l[0] as int, l[1] as int);
  }

  final starts = <int>[0];
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) starts.add(i + 1);
  }
  return FileAnalysis(
    path: path,
    text: text,
    contentHash: text.hashCode,
    lineStarts: starts,
    isPsqlScript: j['psql']! as bool,
    changesets: [
      for (final c in (j['changesets']! as List<Object?>).cast<List<Object?>>())
        ChangesetInfo(
          c[0] as String,
          c[1] as String,
          c[2] as int,
          c[3] as String,
          c[4] as int,
          c[5] as int,
          (c[6] as Map<String, Object?>).cast<String, String>(),
        ),
    ],
    definitions: [
      for (final d in (j['definitions']! as List<Object?>).cast<Map<String, Object?>>())
        Definition(
          key: _decodeKey(d['k'])!,
          kind: ObjectKind.values[d['kind'] as int],
          nameSpan: span(d['n']),
          statementSpan: span(d['s']),
          isAlter: d['alter'] == true,
          columns: [
            for (final c in (d['cols'] as List<Object?>? ?? const []).cast<List<Object?>>())
              ColumnInfo(c[0] as String, c[1] as String, notNull: c[2] as bool, span: c[3] == null ? null : span(c[3])),
          ],
          droppedColumns: List<String>.of((d['dropped'] as List<Object?>? ?? const []).cast<String>()),
          parameters: [
            for (final x in (d['params'] as List<Object?>? ?? const []).cast<List<Object?>>())
              ParameterInfo(x[0] as String?, x[1] as String, x[2] as String, hasDefault: x[3] as bool),
          ],
          returns: d['ret'] as String?,
          language: d['lang'] as String?,
          changesetId: d['cs'] as String?,
          comment: d['comment'] as String? ?? '',
          table: _decodeName(d['table']),
          primaryKey: List<String>.of((d['pk'] as List<Object?>? ?? const []).cast<String>()),
          foreignKeys: [
            for (final f in (d['fks'] as List<Object?>? ?? const []).cast<List<Object?>>())
              ForeignKeyInfo(
                List<String>.of((f[0] as List<Object?>).cast<String>()),
                _decodeName(f[1])!,
                List<String>.of((f[2] as List<Object?>).cast<String>()),
              ),
          ],
        ),
    ],
    references: [
      for (final r in (j['references']! as List<Object?>).cast<List<Object?>>())
        Reference(
          name: _decodeName(r[0])!,
          space: ObjectSpace.values[r[1] as int],
          kind: RefKind.values[r[2] as int],
          span: span(r[3]),
          from: _decodeKey(r[4]),
          argCount: r[5] as int?,
          searchPath: List<String>.of((r[6] as List<Object?>).cast<String>()),
          reportUnresolved: r[7] as bool,
          dynamic: r[8] as bool,
        ),
    ],
    problems: [
      for (final x in (j['problems']! as List<Object?>).cast<List<Object?>>())
        Problem(Severity.values[x[0] as int], x[1] as String, span(x[2]), code: x[3] as String?, fix: x[4] as String?),
    ],
    errorCodes: [
      for (final e in (j['errorCodes']! as List<Object?>).cast<List<Object?>>())
        ErrorCodeUse(e[0] as String, span(e[1]), e[2] as String, _decodeKey(e[3])),
    ],
  );
}

Map<String, Object?> _definition(String path, Definition d) => {
  'k': _key(d.key),
  'kind': d.kind.index,
  'n': _span(path, d.nameSpan),
  's': _span(path, d.statementSpan),
  if (d.isAlter) 'alter': true,
  if (d.columns.isNotEmpty)
    'cols': [
      for (final c in d.columns) [c.name, c.type, c.notNull, c.span == null ? null : _span(path, c.span!)],
    ],
  if (d.droppedColumns.isNotEmpty) 'dropped': d.droppedColumns,
  if (d.parameters.isNotEmpty)
    'params': [
      for (final x in d.parameters) [x.name, x.mode, x.type, x.hasDefault],
    ],
  'ret': ?d.returns,
  'lang': ?d.language,
  'cs': ?d.changesetId,
  if (d.comment.isNotEmpty) 'comment': d.comment,
  if (d.table != null) 'table': _name(d.table!),
  if (d.primaryKey.isNotEmpty) 'pk': d.primaryKey,
  if (d.foreignKeys.isNotEmpty)
    'fks': [
      for (final f in d.foreignKeys) [f.columns, _name(f.target), f.targetColumns],
    ],
};

List<Object?> _reference(String path, Reference r) => [
  _name(r.name),
  r.space.index,
  r.kind.index,
  _span(path, r.span),
  _key(r.from),
  r.argCount,
  r.searchPath,
  r.reportUnresolved,
  r.dynamic,
];

/// A span keeps its file only when it is not the analysed one.
List<Object?> _span(String path, SourceSpan s) => [s.start, s.end, if (s.file != path) s.file];

List<Object?> _name(QualifiedName n) => [n.schema, n.name];
QualifiedName? _decodeName(Object? o) {
  if (o == null) return null;
  final l = o as List<Object?>;
  return QualifiedName(l[0] as String?, l[1] as String);
}

List<Object?>? _key(ObjectKey? k) => k == null ? null : [k.space.index, k.schema, k.name, k.signature];
ObjectKey? _decodeKey(Object? o) {
  if (o == null) return null;
  final l = o as List<Object?>;
  return ObjectKey(ObjectSpace.values[l[0] as int], l[1] as String, l[2] as String, l[3] as String?);
}
