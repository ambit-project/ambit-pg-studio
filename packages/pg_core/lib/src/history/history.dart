// The history of an object and the effective DDL of a table (2.0 spec 008): every statement of the changelog that
// touches it, in changelog order, replayed on a model of the table.
import '../analysis/tokens.dart';
import '../index/project_index.dart';
import '../liquibase.dart';
import '../model.dart';
import '../pg_query/pg_query.dart';

typedef Json = Map<String, Object?>;

final class HistoryEntry {
  const HistoryEntry(this.span, this.date, this.changeset, this.comment, this.summary);

  final SourceSpan span;

  /// yyyy-mm-dd from the file name (yyyymmdd-...) or the changeset id, or empty.
  final String date;
  final String changeset;
  final String comment;

  /// What the statement does to the object, e.g. `ADD COLUMN note`, `CREATE INDEX orders_customer_ix`.
  final String summary;
}

final class ObjectHistory {
  const ObjectHistory(this.entries, this.effectiveDdl);

  final List<HistoryEntry> entries;

  /// Tables: CREATE TABLE after every change, with indexes, triggers, RLS, policies; views and routines: the
  /// latest definition. Null when the object has no CREATE in the project.
  final String? effectiveDdl;
}

final class _Column {
  _Column(this.name, this.type, this.constraints);

  /// The name (unquoted, as PostgreSQL stores it) and as the source wrote it.
  String name;
  String? written;
  String type;
  final List<String> constraints;

  String render() => [written ?? _quote(name), type, ...constraints].where((x) => x.isNotEmpty).join(' ');
}

final _date = RegExp(r'(?:^|/)(\d{4})(\d{2})(\d{2})-');

ObjectHistory objectHistory(ProjectIndex index, DbObject object) {
  final key = object.key;
  final isTable = object.kind == ObjectKind.table;
  final entries = <HistoryEntry>[];
  final columns = <_Column>[];
  final constraints = <String>[];
  final extras = <String>[];
  var created = false;
  var name = key.qualified;
  final properties = <String>{};

  bool isTarget(Json? rv) {
    if (rv == null) return false;
    final schema = (rv['schemaname'] as String?) ?? 'public';
    final rel = rv['relname'] as String?;
    return rel != null && '$schema.$rel' == name;
  }

  for (final path in index.order) {
    final file = index.files[path];
    if (file == null || file.text.isEmpty) continue;
    final prepared = prepareSql(file.text);
    properties.addAll(prepared.properties);
    final chunks = prepared.changesets.isEmpty
        ? [(0, file.text.length, null as ChangesetInfo?)]
        : [for (final c in prepared.changesets) (c.start, c.end, c)];
    for (final (start, end, changeset) in chunks) {
      final chunk = prepared.sql.substring(start, end);
      if (!chunk.contains(key.name)) continue; // cheap filter before parsing
      final source = SourceText(chunk);
      final parsed = PgQuery.parseSource(source);
      if (!parsed.ok) continue;
      for (final raw in parsed.statements) {
        final loc = (raw['stmt_location'] as int?) ?? 0;
        final len = raw['stmt_len'] as int?;
        final s = source.offsetOfByte(loc);
        final e = (len == null || len == 0) ? chunk.length : source.offsetOfByte(loc + len);
        final type = (raw['stmt'] as Json).keys.first;
        final node = (raw['stmt'] as Json).values.first as Json;
        final text = restoreProperties(chunk.substring(s, e).trim(), prepared.properties);
        final tt = TokenText.scan(chunk.substring(s, e));
        String? summary;
        switch (type) {
          case 'CreateStmt' when isTarget(node['relation'] as Json?):
            summary = 'CREATE TABLE';
            created = true;
            columns.clear();
            constraints.clear();
            final elements = _elements(tt, afterFirstParen: true);
            final elts = (node['tableElts'] as List? ?? const []).cast<Json>();
            for (var i = 0; i < elts.length && i < elements.length; i++) {
              final def = elts[i]['ColumnDef'] as Json?;
              if (def != null) {
                columns.add(_column(def['colname'] as String, elements[i]));
              } else {
                constraints.add(elements[i]);
              }
            }
          case 'AlterTableStmt' when isTarget(node['relation'] as Json?):
            final cmds = (node['cmds'] as List? ?? const []).cast<Json>();
            final texts = _elements(tt, afterFirstParen: false, skipHead: true);
            final parts = <String>[];
            for (var i = 0; i < cmds.length; i++) {
              final cmd = cmds[i]['AlterTableCmd'] as Json;
              final t = i < texts.length ? texts[i] : '';
              parts.add(_applyAlter(cmd, t, columns, constraints, extras, name));
            }
            summary = parts.join(', ');
          case 'RenameStmt' when isTarget(node['relation'] as Json?):
            if (node['renameType'] == 'OBJECT_COLUMN') {
              final from = node['subname'] as String;
              final to = node['newname'] as String;
              for (final c in columns) {
                if (c.name == from) {
                  c.name = to;
                  c.written = null;
                }
              }
              summary = 'RENAME COLUMN $from TO $to';
            } else if (node['renameType'] == 'OBJECT_TABLE') {
              final to = node['newname'] as String;
              summary = 'RENAME TO $to';
              name = '${name.split('.').first}.$to';
            }
          case 'IndexStmt' when isTarget(node['relation'] as Json?):
            summary = 'CREATE INDEX ${node['idxname'] ?? ''}'.trim();
            extras.add('${_oneLine(text)};');
          case 'CreateTrigStmt' when isTarget(node['relation'] as Json?):
            summary = 'CREATE TRIGGER ${node['trigname']}';
            extras.add('${_oneLine(text)};');
          case 'CreatePolicyStmt' when isTarget(node['table'] as Json?):
            summary = 'CREATE POLICY ${node['policy_name']}';
            extras.add('${_oneLine(text)};');
          case 'CommentStmt' when _commentTarget(node, name):
            summary = 'COMMENT';
            extras.add('${_oneLine(text)};');
          case 'GrantStmt'
              when ((node['objects'] as List?) ?? const []).any((o) => isTarget((o as Json)['RangeVar'] as Json?)):
            summary = node['is_grant'] == true ? 'GRANT' : 'REVOKE';
          case 'DropStmt' when _dropsTarget(node, name):
            summary = 'DROP';
            created = false;
          default:
            // Views and routines: their CREATE (OR REPLACE) statements are their history.
            if (!isTable) {
              final defined = file.definitions.any(
                (d) => d.key == key && d.statementSpan.start >= start + s && d.statementSpan.start <= start + e,
              );
              if (defined) summary = type == 'CreateFunctionStmt' || type == 'ViewStmt' ? 'CREATE OR REPLACE' : type;
            }
        }
        if (summary == null) continue;
        final span = SourceSpan(path, start + s, start + e);
        final d = _date.firstMatch(path) ?? (changeset == null ? null : _date.firstMatch('/${changeset.id}'));
        entries.add(
          HistoryEntry(
            span,
            d == null ? '' : '${d.group(1)}-${d.group(2)}-${d.group(3)}',
            changeset == null ? '' : '${changeset.author}:${changeset.id}',
            changeset?.comment.split('\n').first ?? '',
            summary,
          ),
        );
      }
    }
  }

  String? ddl;
  if (isTable && created) {
    final lines = [...columns.map((c) => c.render()), ...constraints];
    ddl =
        '-- ${object.key.qualified} after ${entries.length} statements of the changelog (PG Studio; not a migration)\n'
        'CREATE TABLE ${name.split('.').map(_quote).join('.')} (\n${lines.map((l) => '    $l').join(',\n')}\n);\n'
        '${extras.map((x) => '$x\n').join()}';
    ddl = restoreProperties(ddl, properties);
  } else if (!isTable && object.isDefinedHere) {
    final d = object.latest;
    final text = index.files[d.statementSpan.file]!.text.substring(d.statementSpan.start, d.statementSpan.end).trim();
    ddl = '${text.endsWith(';') ? text : '$text;'}\n';
  }
  return ObjectHistory(entries, ddl);
}

/// The comma-separated parts of a statement: inside its first parenthesis (CREATE TABLE elements), or after the
/// table name (ALTER TABLE commands), without comments.
List<String> _elements(TokenText tt, {required bool afterFirstParen, bool skipHead = false}) {
  final tokens = tt.tokens;
  var i = 0;
  var stop = tokens.length;
  if (afterFirstParen) {
    i = tokens.indexWhere((t) => tt.textOf(t) == '(');
    if (i < 0) return const [];
    stop = tt.matchingParen(i);
    i++;
  } else if (skipHead) {
    // ALTER TABLE [IF EXISTS] [ONLY] name
    final name = tt.nameAfter({'TABLE'}, 0, tt.text.length);
    if (name == null) return const [];
    i = name.last + 1;
  }
  final parts = <String>[];
  var depth = 0;
  var from = i;
  for (var k = i; k <= stop; k++) {
    final s = k < stop ? tt.textOf(tokens[k]) : ',';
    if (s == '(' || s == '[') depth++;
    if (s == ')' || s == ']') depth--;
    if ((s == ',' && depth == 0) || k == stop) {
      if (k > from) parts.add(_oneLine(tt.text.substring(tokens[from].start, tokens[k - 1].end)));
      from = k + 1;
    }
  }
  return parts;
}

_Column _column(String name, String text) {
  // "name type [constraints]": the name as written (maybe "quoted"), the type up to the first constraint keyword.
  final head = RegExp(r'^("(?:[^"]|"")*"|\S+)\s*').firstMatch(text);
  final written = head?.group(1) ?? name;
  final rest = head == null ? text : text.substring(head.end).trim();
  final m = RegExp(
    r'\s+(?=(NOT\s+NULL|NULL|DEFAULT|PRIMARY\s+KEY|REFERENCES|UNIQUE|CHECK|CONSTRAINT|GENERATED|COLLATE)\b)',
    caseSensitive: false,
  ).firstMatch(rest);
  final column = m == null
      ? _Column(name, rest, [])
      : _Column(name, rest.substring(0, m.start), [rest.substring(m.end)]);
  column.written = written;
  return column;
}

/// An identifier as PostgreSQL needs it written: quoted unless lower case letters, digits and _.
String _quote(String id) => RegExp(r'^[a-z_][a-z0-9_$]*$').hasMatch(id) ? id : '"${id.replaceAll('"', '""')}"';

String _applyAlter(
  Json cmd,
  String text,
  List<_Column> columns,
  List<String> constraints,
  List<String> extras,
  String table,
) {
  final subtype = cmd['subtype'] as String;
  final colName = cmd['name'] as String?;
  _Column? col() => columns.where((c) => c.name == colName).firstOrNull;
  String after(RegExp head) => text.replaceFirst(head, '').trim();
  switch (subtype) {
    case 'AT_AddColumn':
      final def = (cmd['def'] as Json)['ColumnDef'] as Json;
      final n = def['colname'] as String;
      columns.removeWhere((c) => c.name == n);
      columns.add(_column(n, after(RegExp(r'^ADD\s+(COLUMN\s+)?(IF\s+NOT\s+EXISTS\s+)?', caseSensitive: false))));
      return 'ADD COLUMN $n';
    case 'AT_DropColumn':
      columns.removeWhere((c) => c.name == colName);
      return 'DROP COLUMN $colName';
    case 'AT_SetNotNull':
      final c = col();
      if (c != null && !c.constraints.any((x) => x.toUpperCase().contains('NOT NULL'))) c.constraints.add('NOT NULL');
      return 'ALTER COLUMN $colName SET NOT NULL';
    case 'AT_DropNotNull':
      final c = col();
      if (c != null) {
        for (var i = 0; i < c.constraints.length; i++) {
          c.constraints[i] = c.constraints[i].replaceAll(RegExp(r'\s*NOT\s+NULL\s*', caseSensitive: false), ' ').trim();
        }
      }
      return 'ALTER COLUMN $colName DROP NOT NULL';
    case 'AT_ColumnDefault':
      final c = col();
      final value = RegExp(r'\bSET\s+DEFAULT\s+(.*)$', caseSensitive: false).firstMatch(text)?.group(1);
      if (c != null) {
        for (var i = 0; i < c.constraints.length; i++) {
          c.constraints[i] = c.constraints[i]
              .replaceAll(RegExp(r"\s*DEFAULT\s+('[^']*'|\S+(\([^)]*\))?)", caseSensitive: false), '')
              .trim();
        }
        if (value != null) c.constraints.add('DEFAULT $value');
      }
      return value == null ? 'ALTER COLUMN $colName DROP DEFAULT' : 'ALTER COLUMN $colName SET DEFAULT';
    case 'AT_AlterColumnType':
      final c = col();
      final type = RegExp(r'\bTYPE\s+(.*?)(\s+USING\b.*)?$', caseSensitive: false).firstMatch(text)?.group(1);
      if (c != null && type != null) c.type = type;
      return 'ALTER COLUMN $colName TYPE ${type ?? ''}'.trim();
    case 'AT_AddConstraint':
      constraints.add(after(RegExp(r'^ADD\s+', caseSensitive: false)));
      return 'ADD ${constraints.last.split(' ').take(3).join(' ')}';
    case 'AT_DropConstraint':
      constraints.removeWhere((c) => c.contains('CONSTRAINT $colName ') || c.startsWith('CONSTRAINT $colName'));
      for (final c in columns) {
        c.constraints.removeWhere((x) => x.contains('CONSTRAINT $colName '));
      }
      return 'DROP CONSTRAINT $colName';
    case 'AT_EnableRowSecurity':
      extras.add('ALTER TABLE $table ENABLE ROW LEVEL SECURITY;');
      return 'ENABLE ROW LEVEL SECURITY';
    case 'AT_ForceRowSecurity':
      extras.add('ALTER TABLE $table FORCE ROW LEVEL SECURITY;');
      return 'FORCE ROW LEVEL SECURITY';
    case 'AT_NoForceRowSecurity':
      extras.remove('ALTER TABLE $table FORCE ROW LEVEL SECURITY;');
      return 'NO FORCE ROW LEVEL SECURITY';
    default:
      return _oneLine(text);
  }
}

bool _commentTarget(Json node, String table) {
  final o = node['object'];
  if (o is! Json) return false;
  final names = [
    for (final n in ((o['List'] as Json?)?['items'] as List? ?? const []))
      if ((n as Json)['String'] != null) (n['String'] as Json)['sval'] as String,
  ];
  return names.length >= 2 && '${names[0]}.${names[1]}' == table;
}

bool _dropsTarget(Json node, String table) {
  if (node['removeType'] != 'OBJECT_TABLE') return false;
  for (final o in (node['objects'] as List? ?? const [])) {
    final names = [
      for (final n in (((o as Json)['List'] as Json?)?['items'] as List? ?? const []))
        if ((n as Json)['String'] != null) (n['String'] as Json)['sval'] as String,
    ];
    if (names.join('.') == table) return true;
  }
  return false;
}

String _oneLine(String s) => s.replaceAll(RegExp(r'--[^\n]*'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
