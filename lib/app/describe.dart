import 'package:pg_core/pg_core.dart';

/// The hover text of an object: kind and signature, columns, the changeset comment, where it is defined.
String describe(DbObject o, ProjectIndex index, {int maxColumns = 25}) {
  final b = StringBuffer();
  b.writeln('${o.kind.label} ${o.signature}');
  final d = o.latest;
  if (o.kind == ObjectKind.function && d.returns == null) b.writeln('returns ?');
  final columns = o.columns;
  if (columns.isNotEmpty) {
    for (final c in columns.take(maxColumns)) {
      b.writeln('  ${c.name}${c.type.isEmpty ? '' : ' ${c.type}'}${c.notNull ? ' NOT NULL' : ''}');
    }
    if (columns.length > maxColumns) b.writeln('  … ${columns.length - maxColumns} more');
  }
  if (d.table != null) b.writeln('on ${d.table}');
  final comment = o.primary.comment.split('\n').first.trim();
  if (comment.isNotEmpty) b.writeln('-- $comment');
  final file = index.files[o.primary.nameSpan.file];
  final line = file == null ? 0 : file.lineColumn(o.primary.nameSpan.start).$1 + 1;
  final changes = o.definitions.where((x) => x.isAlter).length;
  b.write('${o.primary.nameSpan.file}:$line${changes == 0 ? '' : ' (+$changes changes)'}');
  return b.toString();
}
