// Liquibase formatted SQL and other non-SQL text in .sql files, turned into text the PostgreSQL parser accepts.
// Every replacement keeps the length of the original, so offsets in the prepared text are offsets in the file.
import 'model.dart';

final class PreparedText {
  const PreparedText(this.sql, this.changesets, this.isLiquibase, this.isPsqlScript, this.properties);

  /// The text to parse: same length as the file.
  final String sql;
  final List<ChangesetInfo> changesets;
  final bool isLiquibase;

  /// The file has psql meta-command lines (`\set`, `\i`, ...), blanked in [sql].
  final bool isPsqlScript;

  /// Liquibase properties used in the file (`role_prefix` for `${role_prefix}`).
  final Set<String> properties;
}

final _property = RegExp(r'\$\{([A-Za-z0-9_.\-]+)\}');
final _changeset = RegExp(r'^--\s*changeset\s+([^\s:]+):(\S+)(.*)$');
final _attribute = RegExp(r'([A-Za-z]+):(\S+)');
final _commentLine = RegExp(r'^--\s*comment:\s?(.*)$');
final _psqlVariable = RegExp(r"""(?<![:\w]):(?=['"A-Za-z_])""");

/// The identifier a property becomes in the prepared text: `${role_prefix}` -> `__role_prefix_` (same length).
String propertyPlaceholder(String property) => '__${property.replaceAll(RegExp('[.-]'), '_')}_';

/// Puts `${property}` back into a name taken from the prepared text.
String restoreProperties(String name, Set<String> properties) {
  if (properties.isEmpty || !name.contains('__')) return name;
  var result = name;
  for (final p in properties) {
    result = result.replaceAll(propertyPlaceholder(p), '\${$p}');
  }
  return result;
}

PreparedText prepareSql(String text) {
  final properties = <String>{};
  var sql = text.replaceAllMapped(_property, (m) {
    properties.add(m.group(1)!);
    return propertyPlaceholder(m.group(1)!);
  });

  final isLiquibase = text.trimLeft().toLowerCase().startsWith('--liquibase formatted sql');
  final changesets = <ChangesetInfo>[];
  var psql = false;
  final buffer = StringBuffer();
  var offset = 0;
  var line = 0;
  _OpenChangeset? open;
  for (final raw in sql.split('\n')) {
    final trimmed = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    var written = raw;
    if (isLiquibase) {
      final m = _changeset.firstMatch(trimmed);
      if (m != null) {
        if (open != null) changesets.add(open.close(offset));
        final attributes = {for (final a in _attribute.allMatches(m.group(3)!)) a.group(1)!: a.group(2)!};
        open = _OpenChangeset(m.group(1)!, m.group(2)!, line, offset, attributes);
      } else {
        final c = _commentLine.firstMatch(trimmed);
        if (c != null) open?.comments.add(c.group(1)!.trimRight());
      }
    } else if (trimmed.startsWith(r'\')) {
      psql = true;
      written = ' ' * trimmed.length + (raw.length > trimmed.length ? '\r' : '');
    }
    buffer.write(written);
    offset += raw.length + 1;
    line++;
    if (offset <= sql.length) buffer.write('\n');
  }
  if (open != null) changesets.add(open.close(sql.length));
  sql = buffer.toString();
  // psql variables (:name, :'name', :"name"): the colon becomes a space, the rest stays a name or a literal.
  if (psql) sql = sql.replaceAllMapped(_psqlVariable, (m) => ' ');
  assert(sql.length == text.length, 'prepared text must keep the offsets of the file');
  return PreparedText(sql, changesets, isLiquibase, psql, properties);
}

final class _OpenChangeset {
  _OpenChangeset(this.author, this.id, this.line, this.start, this.attributes);

  final String author;
  final String id;
  final int line;
  final int start;
  final Map<String, String> attributes;
  final List<String> comments = [];

  ChangesetInfo close(int end) => ChangesetInfo(author, id, line, comments.join('\n'), start, end, attributes);
}
