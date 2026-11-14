// The model of an analysed database project: objects, their definitions, references and problems.
// Offsets are UTF-16 offsets into the file text; every class is plain data so it crosses isolates.

/// Kinds of database objects the index knows.
enum ObjectKind {
  schema,
  table,
  view,
  materializedView,
  function,
  procedure,
  type,
  domain,
  sequence,
  tableIndex,
  trigger,
  extension;

  /// PostgreSQL name spaces: relations (tables, views, sequences, indexes, composite types share pg_class),
  /// routines, types, schemas, triggers (per table), extensions.
  ObjectSpace get space => switch (this) {
    table || view || materializedView || sequence || tableIndex => ObjectSpace.relation,
    function || procedure => ObjectSpace.routine,
    type || domain => ObjectSpace.type,
    schema => ObjectSpace.schema,
    trigger => ObjectSpace.trigger,
    extension => ObjectSpace.extension,
  };

  String get label => switch (this) {
    materializedView => 'materialized view',
    tableIndex => 'index',
    _ => name,
  };
}

enum ObjectSpace { relation, routine, type, schema, trigger, extension }

/// What a reference does with its target.
enum RefKind {
  call,
  read,
  write,
  type,
  foreignKey,
  trigger,
  indexOn,
  alter,
  drop,
  grant,
  comment;

  String get label => switch (this) {
    foreignKey => 'foreign key',
    indexOn => 'index',
    _ => name,
  };
}

/// A qualified name as written: [schema] is null when the source did not qualify it.
final class QualifiedName {
  const QualifiedName(this.schema, this.name);

  final String? schema;
  final String name;

  @override
  String toString() => schema == null ? name : '$schema.$name';

  @override
  bool operator ==(Object other) => other is QualifiedName && other.schema == schema && other.name == name;

  @override
  int get hashCode => Object.hash(schema, name);
}

/// A range in a file.
final class SourceSpan {
  const SourceSpan(this.file, this.start, this.end);

  final String file;
  final int start;
  final int end;

  @override
  String toString() => '$file[$start,$end)';

  @override
  bool operator ==(Object other) =>
      other is SourceSpan && other.file == file && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(file, start, end);
}

/// The identity of an object: space + schema.name, and for routines the input argument types.
final class ObjectKey implements Comparable<ObjectKey> {
  const ObjectKey(this.space, this.schema, this.name, [this.signature]);

  final ObjectSpace space;
  final String schema;
  final String name;

  /// Routines: normalized input argument types, e.g. `uuid,orders_app.asn_line_input[]`. Triggers: the table.
  final String? signature;

  String get qualified => schema.isEmpty ? name : '$schema.$name';

  @override
  String toString() => signature == null ? qualified : '$qualified($signature)';

  @override
  bool operator ==(Object other) =>
      other is ObjectKey &&
      other.space == space &&
      other.schema == schema &&
      other.name == name &&
      other.signature == signature;

  @override
  int get hashCode => Object.hash(space, schema, name, signature);

  @override
  int compareTo(ObjectKey other) => toString().compareTo(other.toString());
}

/// A column of a table, view or composite type.
final class ColumnInfo {
  const ColumnInfo(this.name, this.type, {this.notNull = false, this.span});

  final String name;

  /// The type as written in the source (empty for view columns).
  final String type;
  final bool notNull;
  final SourceSpan? span;
}

/// A foreign key: [columns] of the table point at [target] ([targetColumns], empty = its primary key).
final class ForeignKeyInfo {
  const ForeignKeyInfo(this.columns, this.target, this.targetColumns);

  final List<String> columns;
  final QualifiedName target;
  final List<String> targetColumns;
}

/// A routine parameter as written.
final class ParameterInfo {
  const ParameterInfo(this.name, this.mode, this.type, {this.hasDefault = false});

  final String? name;

  /// in, out, inout, variadic, table.
  final String mode;
  final String type;
  final bool hasDefault;

  bool get isInput => mode == 'in' || mode == 'inout' || mode == 'variadic';

  @override
  String toString() => [if (mode != 'in') mode.toUpperCase(), ?name, type].join(' ');
}

/// The Liquibase changeset a statement belongs to.
final class ChangesetInfo {
  const ChangesetInfo(this.author, this.id, this.line, this.comment, this.start, this.end, this.attributes);

  final String author;
  final String id;

  /// 0-based line of the `--changeset` header.
  final int line;

  /// The `--comment:` lines joined with newlines (empty when none).
  final String comment;
  final int start;
  final int end;
  final Map<String, String> attributes;
}

/// One definition or change of an object in a file (CREATE, CREATE OR REPLACE, ALTER).
final class Definition {
  const Definition({
    required this.key,
    required this.kind,
    required this.nameSpan,
    required this.statementSpan,
    this.isAlter = false,
    this.columns = const [],
    this.droppedColumns = const [],
    this.parameters = const [],
    this.returns,
    this.language,
    this.changesetId,
    this.comment = '',
    this.table,
    this.primaryKey = const [],
    this.foreignKeys = const [],
  });

  final ObjectKey key;
  final ObjectKind kind;
  final SourceSpan nameSpan;
  final SourceSpan statementSpan;

  /// ALTER TABLE and the like: a change of an object defined elsewhere.
  final bool isAlter;
  final List<ColumnInfo> columns;
  final List<String> droppedColumns;
  final List<ParameterInfo> parameters;
  final String? returns;
  final String? language;
  final String? changesetId;

  /// The changeset's `--comment:` text.
  final String comment;

  /// Indexes and triggers: the table they belong to.
  final QualifiedName? table;

  /// Tables: the primary key columns declared by this statement (CREATE TABLE or ALTER TABLE ADD ...).
  final List<String> primaryKey;

  /// Tables: the foreign keys declared by this statement.
  final List<ForeignKeyInfo> foreignKeys;
}

/// A use of an object, before (target null) or after resolution.
final class Reference {
  const Reference({
    required this.name,
    required this.space,
    required this.kind,
    required this.span,
    this.from,
    this.argCount,
    this.searchPath = const ['public'],
    this.reportUnresolved = false,
    this.dynamic = false,
  });

  final QualifiedName name;
  final ObjectSpace space;
  final RefKind kind;

  /// The span of the name in the file (qualified: from the schema to the end of the name).
  final SourceSpan span;

  /// The object whose definition contains the reference (null at the top level of a changeset).
  final ObjectKey? from;

  /// Calls: the number of arguments when known.
  final int? argCount;

  /// The schemas an unqualified [name] is looked up in.
  final List<String> searchPath;

  /// An unresolved target is a warning (a qualified call or relation in a clear context); otherwise it is dropped
  /// silently (built-ins, aliases, CTEs, variables).
  final bool reportUnresolved;

  /// Found in the constant text of dynamic SQL (`EXECUTE '...'`, `format('...')`), 2.0 spec 012.
  final bool dynamic;
}

enum Severity { error, warning, info }

final class Problem {
  const Problem(this.severity, this.message, this.span, {this.code, this.fix});

  final Severity severity;
  final String message;
  final SourceSpan span;

  /// A stable code for filtering, e.g. `syntax`, `plpgsql`, `unresolved`, `module-order`.
  final String? code;

  /// A quick fix [applyQuickFix] knows (e.g. `json-to-jsonb`), or null.
  final String? fix;

  @override
  String toString() => '${severity.name} ${span.file}:${span.start} $message';
}

/// `RAISE ... USING ERRCODE = 'X'` with the comment line above it, e.g. `-- U1445 (404): ...`.
final class ErrorCodeUse {
  const ErrorCodeUse(this.code, this.span, this.description, this.from);

  final String code;
  final SourceSpan span;
  final String description;
  final ObjectKey? from;
}

/// The analysis of one file (phase 1, independent of other files).
final class FileAnalysis {
  const FileAnalysis({
    required this.path,
    required this.lineStarts,
    required this.changesets,
    required this.definitions,
    required this.references,
    required this.problems,
    required this.errorCodes,
    required this.isPsqlScript,
    required this.contentHash,
    this.text = '',
  });

  /// Path relative to the project root, with `/`.
  final String path;
  final List<int> lineStarts;
  final List<ChangesetInfo> changesets;
  final List<Definition> definitions;
  final List<Reference> references;
  final List<Problem> problems;
  final List<ErrorCodeUse> errorCodes;
  final bool isPsqlScript;
  final int contentHash;

  /// The analysed text (for rules that read the file as text, e.g. the module rules of spec 2.0/006).
  final String text;

  /// 0-based line and column of an offset.
  (int line, int column) lineColumn(int offset) {
    var low = 0;
    var high = lineStarts.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (lineStarts[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return (low, offset - lineStarts[low]);
  }
}
