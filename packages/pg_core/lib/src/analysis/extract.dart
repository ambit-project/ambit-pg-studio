// Phase 1 of the analysis: one file -> definitions, unresolved references, error codes and problems.
// Independent of other files, so files are analysed in parallel and cached by content (ADR 0002).
import '../liquibase.dart';
import '../model.dart';
import '../pg_query/pg_query.dart';
import 'body_scan.dart';
import 'tokens.dart';

typedef Json = Map<String, Object?>;

const _builtinSchemas = {'pg_catalog', 'information_schema', 'pg_toast'};
const _typeStops = {
  'NOT',
  'NULL_P',
  'DEFAULT',
  'PRIMARY',
  'REFERENCES',
  'UNIQUE',
  'CHECK',
  'CONSTRAINT',
  'GENERATED',
  'COLLATE',
};
const _returnsStops = {
  'LANGUAGE',
  'AS',
  'IMMUTABLE',
  'STABLE',
  'VOLATILE',
  'SECURITY',
  'SET',
  'STRICT_P',
  'CALLED',
  'PARALLEL',
  'COST',
  'ROWS',
  'LEAKPROOF',
  'WINDOW',
  'BEGIN_P',
  'RETURN',
  'TRANSFORM',
  'SUPPORT',
  'EXTERNAL',
  'NOT',
};

FileAnalysis analyzeFile(String path, String text) => _FileExtractor(path, text).run();

final class _FileExtractor {
  _FileExtractor(this.path, this.text);

  final String path;
  final String text;
  late final PreparedText prepared;
  final definitions = <Definition>[];
  final references = <Reference>[];
  final problems = <Problem>[];
  final errorCodes = <ErrorCodeUse>[];

  FileAnalysis run() {
    prepared = prepareSql(text);
    final chunks = prepared.changesets.isEmpty
        ? [(0, prepared.sql.length, null as ChangesetInfo?)]
        : [for (final c in prepared.changesets) (c.start, c.end, c)];
    for (final (start, end, changeset) in chunks) {
      _Chunk(this, start, end, changeset).run();
    }
    return FileAnalysis(
      path: path,
      lineStarts: _lineStarts(text),
      changesets: prepared.changesets,
      definitions: definitions,
      references: references,
      problems: problems,
      errorCodes: errorCodes,
      isPsqlScript: prepared.isPsqlScript,
      contentHash: text.hashCode,
      text: text,
    );
  }

  String restore(String name) => restoreProperties(name, prepared.properties);
}

List<int> _lineStarts(String text) {
  final starts = <int>[0];
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) starts.add(i + 1);
  }
  return starts;
}

/// One changeset (or the whole file): parsed separately, so a syntax error stays inside it.
final class _Chunk {
  _Chunk(this.file, this.start, this.end, this.changeset)
    : sql = file.prepared.sql.substring(start, end),
      source = SourceText(file.prepared.sql.substring(start, end));

  final _FileExtractor file;
  final int start;
  final int end;
  final ChangesetInfo? changeset;
  final String sql;
  final SourceText source;
  late final TokenText tokens;
  List<String> searchPath = const ['public'];

  String get path => file.path;

  SourceSpan span(int localStart, int localEnd) => SourceSpan(path, start + localStart, start + localEnd);

  int offset(Object? byteLocation) => source.offsetOfByte((byteLocation as int?) ?? 0);

  void run() {
    if (sql.trim().isEmpty) return;
    final result = PgQuery.parseSource(source);
    if (!result.ok) {
      final at = result.error!.offset ?? 0;
      file.problems.add(Problem(Severity.error, result.error!.message, span(at, _errorEnd(sql, at)), code: 'syntax'));
      return;
    }
    tokens = TokenText.scan(sql);
    for (final raw in result.statements) {
      final stmtStart = offset(raw['stmt_location']);
      final len = raw['stmt_len'] as int?;
      final stmtEnd = (len == null || len == 0) ? sql.length : offset(((raw['stmt_location'] as int?) ?? 0) + len);
      final stmt = raw['stmt'] as Json;
      _Statement(this, stmt.keys.first, stmt.values.first as Json, stmtStart, stmtEnd).run();
    }
  }
}

final class _Statement {
  _Statement(this.chunk, this.type, this.node, this.start, this.end);

  final _Chunk chunk;
  final String type;
  final Json node;
  final int start;
  final int end;

  TokenText get tt => chunk.tokens;
  String get path => chunk.path;

  void run() {
    switch (type) {
      case 'CreateSchemaStmt':
        final name = node['schemaname'] as String?;
        if (name != null) {
          _define(ObjectKind.schema, ObjectKey(ObjectSpace.schema, '', _r(name)), tt.nameAfter({'SCHEMA'}, start, end));
        }
      case 'CreateStmt':
        _createTable();
      case 'ViewStmt':
        _createView();
      case 'CreateTableAsStmt':
        _createTableAs();
      case 'CreateFunctionStmt':
        _createRoutine();
      case 'IndexStmt':
        _createIndex();
      case 'CreateTrigStmt':
        _createTrigger();
      case 'CompositeTypeStmt':
        final rv = node['typevar'] as Json;
        final key = ObjectKey(ObjectSpace.type, _schema(rv['schemaname']), _r(rv['relname'] as String));
        _define(
          ObjectKind.type,
          key,
          tt.qualifiedStartingAt(chunk.offset(rv['location'])),
          columns: _columns(node['coldeflist'] as List?),
        );
        _walkChildren(node, from: key, skip: {'typevar'});
      case 'CreateEnumStmt':
        final names = _names(node['typeName']);
        final key = ObjectKey(ObjectSpace.type, names.length > 1 ? names.first : 'public', names.last);
        _define(ObjectKind.type, key, tt.nameAfter({'TYPE_P'}, start, end));
      case 'CreateDomainStmt':
        final names = _names(node['domainname']);
        final key = ObjectKey(ObjectSpace.type, names.length > 1 ? names.first : 'public', names.last);
        _define(ObjectKind.domain, key, tt.nameAfter({'DOMAIN_P'}, start, end));
        _walkChildren(node, from: key, skip: {'domainname'});
      case 'CreateSeqStmt':
        final rv = node['sequence'] as Json;
        final key = ObjectKey(ObjectSpace.relation, _schema(rv['schemaname']), _r(rv['relname'] as String));
        _define(ObjectKind.sequence, key, tt.qualifiedStartingAt(chunk.offset(rv['location'])));
      case 'CreateExtensionStmt':
        final name = node['extname'] as String;
        _define(
          ObjectKind.extension,
          ObjectKey(ObjectSpace.extension, '', name),
          tt.nameAfter({'EXTENSION'}, start, end),
        );
      case 'AlterTableStmt':
        _alterTable();
      case 'DoStmt':
        for (final opt in (node['args'] as List? ?? const [])) {
          final d = (opt as Json)['DefElem'] as Json;
          if (d['defname'] == 'as') _plpgsqlBody(d, from: null, header: null);
        }
      case 'VariableSetStmt':
        if (node['name'] == 'search_path') {
          final path = _searchPathOf(node);
          if (path.isNotEmpty) chunk.searchPath = path;
        }
        _walk(node, RefKind.read, null);
      case 'DropStmt':
        _namedObjects(node['objects'] as List?, _spaceOfObjectType(node['removeType'] as String?), RefKind.drop);
      case 'GrantStmt':
        final space = _spaceOfObjectType(node['objtype'] as String?);
        if (space == ObjectSpace.relation) {
          _walk(node['objects'], RefKind.grant, null);
        } else {
          _namedObjects(node['objects'] as List?, space, RefKind.grant);
        }
      case 'CommentStmt':
        _namedObjects([node['object']], _spaceOfObjectType(node['objtype'] as String?), RefKind.comment);
      case 'AlterFunctionStmt':
        _namedObjects([node['func']], ObjectSpace.routine, RefKind.alter);
      case 'AlterOwnerStmt' || 'AlterObjectSchemaStmt' || 'RenameStmt':
        if (node['relation'] != null) _walk(node['relation'], RefKind.alter, null);
        if (node['object'] != null) {
          _namedObjects(
            [node['object']],
            _spaceOfObjectType((node['objectType'] ?? node['renameType']) as String?),
            RefKind.alter,
          );
        }
      default:
        _walk({type: node}, RefKind.read, null);
    }
  }

  // --- definitions -------------------------------------------------------------------------------------------------

  void _define(
    ObjectKind kind,
    ObjectKey key,
    QualifiedRun? name, {
    bool isAlter = false,
    List<ColumnInfo> columns = const [],
    List<String> droppedColumns = const [],
    List<ParameterInfo> parameters = const [],
    String? returns,
    String? language,
    QualifiedName? table,
    List<String> primaryKey = const [],
    List<ForeignKeyInfo> foreignKeys = const [],
  }) {
    final nameSpan = name == null ? chunk.span(start, start) : chunk.span(name.start, name.end);
    chunk.file.definitions.add(
      Definition(
        key: key,
        kind: kind,
        nameSpan: nameSpan,
        statementSpan: chunk.span(start, end),
        isAlter: isAlter,
        columns: columns,
        droppedColumns: droppedColumns,
        parameters: parameters,
        returns: returns,
        language: language,
        changesetId: chunk.changeset == null ? null : '${chunk.changeset!.author}:${chunk.changeset!.id}',
        comment: chunk.changeset?.comment ?? '',
        table: table,
        primaryKey: primaryKey,
        foreignKeys: foreignKeys,
      ),
    );
  }

  void _createTable() {
    final rv = node['relation'] as Json;
    final key = ObjectKey(ObjectSpace.relation, _schema(rv['schemaname']), _r(rv['relname'] as String));
    _define(
      ObjectKind.table,
      key,
      tt.qualifiedStartingAt(chunk.offset(rv['location'])),
      columns: _columns(node['tableElts'] as List?),
      primaryKey: _keys(node['tableElts'] as List?).$1,
      foreignKeys: _keys(node['tableElts'] as List?).$2,
    );
    _walkChildren(node, from: key, skip: {'relation'});
  }

  /// Primary key and foreign keys of table elements (column constraints and table constraints).
  (List<String>, List<ForeignKeyInfo>) _keys(List<Object?>? elements) {
    final pk = <String>[];
    final fks = <ForeignKeyInfo>[];
    List<String> names(Object? list) => [
      for (final n in (list as List? ?? const []))
        if ((n as Json)['String'] != null) (n['String'] as Json)['sval'] as String,
    ];
    void constraint(Json c, String? column) {
      switch (c['contype']) {
        case 'CONSTR_PRIMARY':
          pk.addAll(column != null ? [column] : names(c['keys']));
        case 'CONSTR_FOREIGN':
          final t = c['pktable'] as Json?;
          if (t == null) return;
          fks.add(
            ForeignKeyInfo(
              column != null ? [column] : names(c['fk_attrs']),
              QualifiedName(_schemaOrNull(t['schemaname']) ?? 'public', _r(t['relname'] as String)),
              names(c['pk_attrs']),
            ),
          );
      }
    }

    for (final e in elements ?? const []) {
      final el = e as Json?;
      final def = el?['ColumnDef'] as Json?;
      if (def != null) {
        for (final c in (def['constraints'] as List? ?? const [])) {
          final con = (c as Json)['Constraint'] as Json?;
          if (con != null) constraint(con, def['colname'] as String);
        }
      }
      final con = el?['Constraint'] as Json?;
      if (con != null) constraint(con, null);
    }
    return (pk, fks);
  }

  void _createView() {
    final rv = node['view'] as Json;
    final key = ObjectKey(ObjectSpace.relation, _schema(rv['schemaname']), _r(rv['relname'] as String));
    final aliases = [
      for (final a in (node['aliases'] as List? ?? const [])) ((a as Json)['String'] as Json)['sval'] as String,
    ];
    final query = node['query'] as Json?;
    final columns = aliases.isNotEmpty ? [for (final a in aliases) ColumnInfo(a, '')] : _selectColumns(query);
    _define(ObjectKind.view, key, tt.qualifiedStartingAt(chunk.offset(rv['location'])), columns: columns);
    _walk(query, RefKind.read, key);
  }

  void _createTableAs() {
    final into = node['into'] as Json;
    final rv = into['rel'] as Json;
    final key = ObjectKey(ObjectSpace.relation, _schema(rv['schemaname']), _r(rv['relname'] as String));
    final kind = node['objtype'] == 'OBJECT_MATVIEW' ? ObjectKind.materializedView : ObjectKind.table;
    _define(
      kind,
      key,
      tt.qualifiedStartingAt(chunk.offset(rv['location'])),
      columns: _selectColumns(node['query'] as Json?),
    );
    _walk(node['query'], RefKind.read, key);
  }

  void _createIndex() {
    final rv = node['relation'] as Json;
    final table = QualifiedName(_schemaOrNull(rv['schemaname']), _r(rv['relname'] as String));
    final idx = node['idxname'] as String?;
    ObjectKey? key;
    if (idx != null) {
      key = ObjectKey(ObjectSpace.relation, table.schema ?? 'public', _r(idx));
      _define(ObjectKind.tableIndex, key, tt.nameAfter({'INDEX'}, start, end), table: table);
    }
    _walk(rv, RefKind.indexOn, key);
    _walkChildren(node, from: key ?? _tableKey(table), skip: {'relation'});
  }

  void _createTrigger() {
    final rv = node['relation'] as Json;
    final table = QualifiedName(_schemaOrNull(rv['schemaname']), _r(rv['relname'] as String));
    final key = ObjectKey(ObjectSpace.trigger, table.schema ?? 'public', _r(node['trigname'] as String), table.name);
    _define(ObjectKind.trigger, key, tt.nameAfter({'TRIGGER'}, start, end), table: table);
    _walk(rv, RefKind.trigger, key);
    final fn = _names(node['funcname']);
    final run = tt.find(fn, _afterKeyword({'EXECUTE'}) ?? start, end);
    if (run != null) _addRef(_qn(fn), ObjectSpace.routine, RefKind.trigger, run.start, run.end, key, args: 0);
    _walkChildren(node, from: key, skip: {'relation', 'funcname'});
  }

  void _alterTable() {
    final rv = node['relation'] as Json;
    final objtype = node['objtype'] as String?;
    final key = ObjectKey(ObjectSpace.relation, _schema(rv['schemaname']), _r(rv['relname'] as String));
    if (objtype != null && objtype != 'OBJECT_TABLE') {
      _walk(rv, RefKind.alter, null);
      _walkChildren(node, from: key, skip: {'relation'});
      return;
    }
    final pk = <String>[];
    final fks = <ForeignKeyInfo>[];
    final added = <ColumnInfo>[];
    final dropped = <String>[];
    for (final c in (node['cmds'] as List? ?? const [])) {
      final cmd = (c as Json)['AlterTableCmd'] as Json;
      final subtype = cmd['subtype'];
      if (subtype == 'AT_AddColumn') {
        added.addAll(_columns([cmd['def']]));
        final k = _keys([cmd['def']]);
        pk.addAll(k.$1);
        fks.addAll(k.$2);
      }
      if (subtype == 'AT_AddConstraint') {
        final k = _keys([cmd['def']]);
        pk.addAll(k.$1);
        fks.addAll(k.$2);
      }
      if (subtype == 'AT_DropColumn' && cmd['name'] != null) dropped.add(cmd['name'] as String);
    }
    _define(
      ObjectKind.table,
      key,
      tt.qualifiedStartingAt(chunk.offset(rv['location'])),
      isAlter: true,
      columns: added,
      droppedColumns: dropped,
      primaryKey: pk,
      foreignKeys: fks,
    );
    _walkChildren(node, from: key, skip: {'relation'});
  }

  void _createRoutine() {
    final names = _names(node['funcname']);
    final isProcedure = node['is_procedure'] == true;
    final schema = names.length > 1 ? names.first : 'public';
    final params = <ParameterInfo>[];
    final inputTypes = <String>[];
    final nameRun = tt.nameAfter({'FUNCTION', 'PROCEDURE'}, start, end);
    // The parameter list as written, for the signature shown to the user.
    final open = nameRun == null ? -1 : nameRun.last + 1;
    var cursor = open + 1;
    for (final p in (node['parameters'] as List? ?? const [])) {
      final fp = (p as Json)['FunctionParameter'] as Json;
      final mode = switch (fp['mode']) {
        'FUNC_PARAM_OUT' => 'out',
        'FUNC_PARAM_INOUT' => 'inout',
        'FUNC_PARAM_VARIADIC' => 'variadic',
        'FUNC_PARAM_TABLE' => 'table',
        _ => 'in',
      };
      final typeNode = fp['argType'] as Json;
      final typeStart = tt.indexAt(chunk.offset(typeNode['location']));
      final (typeText, after) = tt.textUntil(typeStart, const {'DEFAULT'});
      cursor = after;
      final hasDefault = fp['defexpr'] != null;
      params.add(ParameterInfo(fp['name'] as String?, mode, chunk.file.restore(typeText), hasDefault: hasDefault));
      if (mode != 'out' && mode != 'table') inputTypes.add(_typeKey(typeNode));
    }
    final key = ObjectKey(ObjectSpace.routine, _r(schema), _r(names.last), inputTypes.join(','));
    String? language;
    Json? body;
    var routinePath = chunk.searchPath;
    for (final o in (node['options'] as List? ?? const [])) {
      final d = (o as Json)['DefElem'] as Json;
      switch (d['defname']) {
        case 'language':
          language = ((d['arg'] as Json)['String'] as Json)['sval'] as String;
        case 'as':
          body = d;
        case 'set':
          final set = (d['arg'] as Json)['VariableSetStmt'] as Json?;
          if (set != null && set['name'] == 'search_path') routinePath = _searchPathOf(set);
      }
    }
    String? returns;
    if (!isProcedure) {
      final r = _afterKeywordIndex({'RETURNS'}, from: cursor);
      if (r != null) returns = chunk.file.restore(tt.textUntil(r, _returnsStops).$1);
    }
    _define(
      isProcedure ? ObjectKind.procedure : ObjectKind.function,
      key,
      nameRun,
      parameters: params,
      returns: returns,
      language: language,
    );
    _walk(node['parameters'], RefKind.type, key);
    _walk(node['returnType'], RefKind.type, key);
    if (node['sql_body'] != null) _walk(node['sql_body'], RefKind.read, key);
    if (body != null) {
      final path = routinePath.where((s) => s != 'pg_temp').toList();
      if (language == 'plpgsql') {
        _plpgsqlBody(body, from: key, header: nameRun, searchPath: path);
      } else if (language == 'sql') {
        _sqlBody(body, key, path);
      }
    }
  }

  // --- bodies ------------------------------------------------------------------------------------------------------

  /// The body string token (`$$...$$` or `'...'`) of a DefElem `as`: (local start of the text, the text).
  (int, String)? _bodyText(Json defElem) {
    final at = defElem['arg_location'] as int?;
    if (at == null || at < 0) return null;
    final i = tt.indexAt(chunk.offset(at));
    if (i >= tt.tokens.length) return null;
    final token = tt.tokens[i];
    final raw = tt.textOf(token);
    if (!raw.startsWith(r'$')) return null; // quoted bodies: escapes break offsets, not used in our folders
    final delimiter = raw.substring(0, raw.indexOf(r'$', 1) + 1);
    if (raw.length < delimiter.length * 2) return null;
    return (token.start + delimiter.length, raw.substring(delimiter.length, raw.length - delimiter.length));
  }

  void _plpgsqlBody(Json defElem, {required ObjectKey? from, required QualifiedRun? header, List<String>? searchPath}) {
    final body = _bodyText(defElem);
    if (body == null) return;
    final (bodyStart, bodyText) = body;
    final scan = scanPlpgsqlBody(
      body: bodyText,
      bodyOffset: chunk.start + bodyStart,
      file: path,
      from: from,
      searchPath: searchPath ?? chunk.searchPath,
    );
    chunk.file.references.addAll(scan.references);
    chunk.file.errorCodes.addAll(scan.errorCodes);
    _checkPlpgsql(bodyStart, bodyText, isDo: from == null);
  }

  /// Syntax check of a PL/pgSQL body. libpg_query refuses types from schemas other than pg_catalog/public in
  /// parameters and DECLARE ("LookupExplicitNamespace"), so those are replaced at the same offsets first.
  void _checkPlpgsql(int bodyStart, String bodyText, {required bool isDo}) {
    final String check;
    final int bodyAt;
    if (isDo) {
      const head = r'CREATE FUNCTION pg_temp.__do() RETURNS void LANGUAGE plpgsql AS $__body$';
      check = '$head$bodyText\$__body\$;';
      bodyAt = head.length;
    } else {
      final statement = chunk.sql.substring(start, end);
      check = _neutralizeTypes(statement, bodyStart - start, bodyText.length);
      bodyAt = bodyStart - start;
    }
    final result = PgQuery.parsePlpgsql(check);
    if (result.ok) return;
    final local = _locatePlpgsqlError(result.error!, check, bodyAt, bodyText.length);
    final at = bodyStart + local;
    chunk.file.problems.add(
      Problem(Severity.error, result.error!.message, chunk.span(at, _errorEnd(chunk.sql, at)), code: 'plpgsql'),
    );
  }

  void _sqlBody(Json defElem, ObjectKey from, List<String> searchPath) {
    final body = _bodyText(defElem);
    if (body == null) return;
    final (bodyStart, bodyText) = body;
    final inner = SourceText(bodyText);
    final result = PgQuery.parseSource(inner);
    if (!result.ok) {
      final at = bodyStart + (result.error!.offset ?? 0);
      chunk.file.problems.add(
        Problem(Severity.error, result.error!.message, chunk.span(at, _errorEnd(chunk.sql, at)), code: 'syntax'),
      );
      return;
    }
    final innerTokens = TokenText.scan(bodyText);
    final walker = _Walker(
      path: path,
      base: chunk.start + bodyStart,
      source: inner,
      tokens: innerTokens,
      searchPath: searchPath,
      sink: chunk.file.references,
    );
    for (final s in result.statements) {
      walker.walk(s['stmt'], RefKind.read, from);
    }
  }

  // --- references --------------------------------------------------------------------------------------------------

  void _walk(Object? node, RefKind kind, ObjectKey? from) => _Walker(
    path: path,
    base: chunk.start,
    source: chunk.source,
    tokens: tt,
    searchPath: chunk.searchPath,
    sink: chunk.file.references,
  ).walk(node, kind, from);

  void _walkChildren(Json node, {required ObjectKey? from, Set<String> skip = const {}}) {
    for (final e in node.entries) {
      if (!skip.contains(e.key)) _walk(e.value, RefKind.read, from);
    }
  }

  void _namedObjects(List<Object?>? objects, ObjectSpace? space, RefKind kind) {
    if (objects == null || space == null) return;
    var cursor = start;
    for (final o in objects) {
      if (o == null) continue;
      final List<String> parts;
      int? args;
      if (o is Json && o['ObjectWithArgs'] != null) {
        final owa = o['ObjectWithArgs'] as Json;
        parts = _names(owa['objname']);
        if (owa['args_unspecified'] != true) args = (owa['objargs'] as List? ?? const []).length;
        _walk(owa['objargs'], RefKind.type, null);
      } else if (o is Json && o['List'] != null) {
        parts = _names((o['List'] as Json)['items']);
      } else if (o is Json && o['String'] != null) {
        parts = [(o['String'] as Json)['sval'] as String];
      } else if (o is Json && o['TypeName'] != null) {
        parts = _names((o['TypeName'] as Json)['names']);
      } else {
        continue;
      }
      if (parts.isEmpty) continue;
      final run = tt.find(parts, cursor, end);
      if (run == null) continue;
      cursor = run.end;
      _addRef(_qn(parts), space, kind, run.start, run.end, null, args: args);
    }
  }

  void _addRef(QualifiedName name, ObjectSpace space, RefKind kind, int s, int e, ObjectKey? from, {int? args}) {
    if (name.schema != null && _builtinSchemas.contains(name.schema)) return;
    chunk.file.references.add(
      Reference(
        name: name,
        space: space,
        kind: kind,
        span: chunk.span(s, e),
        from: from,
        argCount: args,
        searchPath: chunk.searchPath,
        // DROP of an object that is gone (or never was here) is not a problem.
        reportUnresolved: name.schema != null && kind != RefKind.drop,
      ),
    );
  }

  // --- helpers -----------------------------------------------------------------------------------------------------

  String _r(String name) => chunk.file.restore(name);
  String _schema(Object? s) => s == null ? 'public' : _r(s as String);
  String? _schemaOrNull(Object? s) => s == null ? null : _r(s as String);
  ObjectKey _tableKey(QualifiedName t) => ObjectKey(ObjectSpace.relation, t.schema ?? 'public', t.name);
  QualifiedName _qn(List<String> parts) => parts.length >= 2
      ? QualifiedName(_r(parts[parts.length - 2]), _r(parts.last))
      : QualifiedName(null, _r(parts.last));

  List<String> _names(Object? list) => [
    for (final n in (list as List? ?? const []))
      if ((n as Json)['String'] != null) _r((n['String'] as Json)['sval'] as String),
  ];

  /// Normalized type of a TypeName for routine identity: `uuid`, `int8`, `orders_app.asn_line_input[]`.
  String _typeKey(Json typeName) {
    final names = _names(typeName['names']);
    final base = (names.length == 2 && names.first == 'pg_catalog') ? names.last : names.join('.');
    final arrays = (typeName['arrayBounds'] as List? ?? const []).length;
    return base + '[]' * arrays;
  }

  List<ColumnInfo> _columns(List<Object?>? elements) {
    final columns = <ColumnInfo>[];
    for (final e in elements ?? const []) {
      final def = (e as Json?)?['ColumnDef'] as Json?;
      if (def == null) continue;
      final name = def['colname'] as String;
      final typeNode = def['typeName'] as Json?;
      var type = '';
      if (typeNode != null) type = tt.textUntil(tt.indexAt(chunk.offset(typeNode['location'])), _typeStops).$1;
      final notNull = (def['constraints'] as List? ?? const []).any((c) {
        final t = ((c as Json)['Constraint'] as Json?)?['contype'];
        return t == 'CONSTR_NOTNULL' || t == 'CONSTR_PRIMARY';
      });
      final at = chunk.offset(def['location']);
      columns.add(ColumnInfo(name, _r(type), notNull: notNull, span: chunk.span(at, at + name.length)));
    }
    return columns;
  }

  List<ColumnInfo> _selectColumns(Json? query) {
    final select = query?['SelectStmt'] as Json?;
    if (select == null) return const [];
    if (select['targetList'] == null && select['larg'] != null) return _selectColumns(select['larg'] as Json?);
    final columns = <ColumnInfo>[];
    for (final t in (select['targetList'] as List? ?? const [])) {
      final rt = (t as Json)['ResTarget'] as Json;
      var name = rt['name'] as String?;
      final val = rt['val'] as Json?;
      if (name == null && val?['ColumnRef'] != null) {
        final fields = ((val!['ColumnRef'] as Json)['fields'] as List).cast<Json>();
        final last = fields.last['String'] as Json?;
        name = last?['sval'] as String? ?? '*';
      }
      if (name == null && val?['FuncCall'] != null) {
        name = _names((val!['FuncCall'] as Json)['funcname']).last;
      }
      columns.add(ColumnInfo(name ?? '?column?', ''));
    }
    return columns;
  }

  List<String> _searchPathOf(Json set) => [
    for (final a in (set['args'] as List? ?? const []))
      if (((a as Json)['A_Const'] as Json?)?['sval'] != null)
        (((a['A_Const'] as Json)['sval'] as Json)['sval'] as String),
  ];

  ObjectSpace? _spaceOfObjectType(String? t) => switch (t) {
    'OBJECT_TABLE' || 'OBJECT_VIEW' || 'OBJECT_MATVIEW' || 'OBJECT_SEQUENCE' || 'OBJECT_INDEX' => ObjectSpace.relation,
    'OBJECT_FUNCTION' || 'OBJECT_PROCEDURE' || 'OBJECT_ROUTINE' => ObjectSpace.routine,
    'OBJECT_TYPE' || 'OBJECT_DOMAIN' => ObjectSpace.type,
    'OBJECT_SCHEMA' => ObjectSpace.schema,
    'OBJECT_EXTENSION' => ObjectSpace.extension,
    _ => null,
  };

  int? _afterKeyword(Set<String> keywords) {
    final i = _afterKeywordIndex(keywords);
    return i == null || i >= tt.tokens.length ? null : tt.tokens[i].start;
  }

  int? _afterKeywordIndex(Set<String> keywords, {int? from}) {
    for (var i = from ?? tt.indexAt(start); i < tt.tokens.length && tt.tokens[i].start < end; i++) {
      if (keywords.contains(tt.tokens[i].name)) return i + 1;
    }
    return null;
  }
}

/// Walks a JSON parse tree and records references with their context (INSERT target = write, FK target, ...).
final class _Walker {
  _Walker({
    required this.path,
    required this.base,
    required this.source,
    required this.tokens,
    required this.searchPath,
    required this.sink,
  });

  final String path;

  /// File offset of the parsed text's first character.
  final int base;
  final SourceText source;
  final TokenText tokens;
  final List<String> searchPath;
  final List<Reference> sink;

  void walk(Object? node, RefKind kind, ObjectKey? from) {
    if (node is List) {
      for (final n in node) {
        walk(n, kind, from);
      }
      return;
    }
    if (node is! Json) return;
    // Node fields hold nodes without the type wrapper ("relation": {"relname": ...}); recognize them by shape.
    if (node.containsKey('relname') && node.containsKey('relpersistence')) return _rangeVar(node, kind, from);
    if (node.containsKey('names') && node.containsKey('typemod')) {
      return _named(node['names'], ObjectSpace.type, RefKind.type, node['location'], from);
    }
    if (node.containsKey('funcname') && node.containsKey('funcformat')) return walk({'FuncCall': node}, kind, from);
    for (final e in node.entries) {
      final value = e.value;
      switch (e.key) {
        case 'RangeVar':
          _rangeVar(value as Json, kind, from);
        case 'FuncCall':
          final fc = value as Json;
          _named(
            fc['funcname'],
            ObjectSpace.routine,
            RefKind.call,
            fc['location'],
            from,
            args: (fc['args'] as List?)?.length ?? 0,
          );
          walk(fc['args'], RefKind.read, from);
          walk(fc['agg_filter'], RefKind.read, from);
          walk(fc['over'], RefKind.read, from);
        case 'TypeName':
          final tn = value as Json;
          _named(tn['names'], ObjectSpace.type, RefKind.type, tn['location'], from);
        case 'InsertStmt' || 'UpdateStmt' || 'DeleteStmt' || 'MergeStmt':
          final stmt = value as Json;
          for (final c in stmt.entries) {
            walk(c.value, c.key == 'relation' ? RefKind.write : RefKind.read, from);
          }
        case 'TruncateStmt':
          walk((value as Json)['relations'], RefKind.write, from);
        case 'Constraint':
          final c = value as Json;
          for (final x in c.entries) {
            walk(x.value, x.key == 'pktable' ? RefKind.foreignKey : RefKind.read, from);
          }
        case 'ColumnDef' || 'FunctionParameter':
          // Types of columns and parameters are type references; defaults and constraints are reads.
          for (final x in (value as Json).entries) {
            walk(x.value, x.key == 'typeName' || x.key == 'argType' ? RefKind.type : RefKind.read, from);
          }
        case 'TypeCast':
          walk((value as Json)['arg'], RefKind.read, from);
          walk(value['typeName'], RefKind.type, from);
        default:
          if (value is Json || value is List) walk(value, kind, from);
      }
    }
  }

  void _rangeVar(Json rv, RefKind kind, ObjectKey? from) {
    final at = source.offsetOfByte((rv['location'] as int?) ?? 0);
    final run = tokens.qualifiedStartingAt(at);
    final schema = rv['schemaname'] as String?;
    final name = rv['relname'] as String;
    final end = run == null ? at + name.length : run.end;
    final effective = kind == RefKind.type || kind == RefKind.call ? RefKind.read : kind;
    _add(QualifiedName(schema, name), ObjectSpace.relation, effective, at, end, from);
  }

  void _named(Object? names, ObjectSpace space, RefKind kind, Object? location, ObjectKey? from, {int? args}) {
    final parts = [
      for (final n in (names as List? ?? const []))
        if ((n as Json)['String'] != null) (n['String'] as Json)['sval'] as String,
    ];
    if (parts.isEmpty) return;
    final loc = location as int?;
    if (loc == null || loc < 0) return;
    final at = source.offsetOfByte(loc);
    final run = tokens.qualifiedStartingAt(at);
    // Types like int, bigint come back as pg_catalog.int8 with the location of the keyword: built-ins.
    if (parts.length >= 2 && (parts.first == 'pg_catalog' || parts.first == 'information_schema')) return;
    if (run == null) return;
    final name = parts.length >= 2
        ? QualifiedName(parts[parts.length - 2], parts.last)
        : QualifiedName(null, parts.last);
    _add(name, space, kind, at, run.end, from, args: args);
  }

  void _add(QualifiedName name, ObjectSpace space, RefKind kind, int s, int e, ObjectKey? from, {int? args}) {
    sink.add(
      Reference(
        name: name,
        space: space,
        kind: kind,
        span: SourceSpan(path, base + s, base + e),
        from: from,
        argCount: args,
        searchPath: searchPath,
        reportUnresolved: name.schema != null,
      ),
    );
  }
}

/// Replaces schema-qualified types in the parameter list and DECLARE sections of [statement] with built-in types
/// padded to the same length, so pg_query_parse_plpgsql accepts it and offsets stay.
String _neutralizeTypes(String statement, int bodyStart, int bodyLength) {
  final chars = statement.split('');
  // A qualified type becomes `record` (or `int` for arrays and short names), padded to the same width.
  void replace(int at, int width, bool isArray) {
    final replacement = (!isArray && width >= 6) ? 'record' : 'int';
    if (width < replacement.length) return;
    final padded = replacement.padRight(width);
    for (var k = 0; k < width; k++) {
      chars[at + k] = padded[k];
    }
  }

  bool qualifiedType(QualifiedRun run) => run.parts.length >= 2 && !_builtinSchemas.contains(run.parts.first);
  String after(TokenText t, QualifiedRun run) => run.last + 1 < t.tokens.length ? t.textOf(t.tokens[run.last + 1]) : '';

  // Parameter list: qualified names in the (...) after the FUNCTION/PROCEDURE name.
  final tt = TokenText.scan(statement);
  final name = tt.nameAfter({'FUNCTION', 'PROCEDURE'}, 0, statement.length);
  if (name != null && after(tt, name) == '(') {
    final close = tt.matchingParen(name.last + 1);
    for (var i = name.last + 2; i < close; i++) {
      final run = tt.qualifiedAt(i);
      if (run == null) continue;
      if (qualifiedType(run)) replace(run.start, run.end - run.start, after(tt, run) == '[');
      i = run.last;
    }
  }
  // DECLARE sections inside the body.
  final body = TokenText.scan(statement.substring(bodyStart, bodyStart + bodyLength));
  var inDeclare = false;
  for (var i = 0; i < body.tokens.length; i++) {
    final word = body.textOf(body.tokens[i]).toLowerCase();
    if (word == 'declare') inDeclare = true;
    if (word == 'begin') inDeclare = false;
    if (!inDeclare) continue;
    final run = body.qualifiedAt(i);
    if (run == null) continue;
    final next = after(body, run);
    if (qualifiedType(run) && next == '%' && run.last + 2 < body.tokens.length) {
      // s.t%ROWTYPE -> record, s.t.c%TYPE -> text: libpg_query cannot look the relation up.
      final what = body.textOf(body.tokens[run.last + 2]).toLowerCase();
      final width = body.tokens[run.last + 2].end - run.start;
      final replacement = what == 'rowtype' ? 'record' : 'text';
      if (width >= replacement.length) {
        final padded = replacement.padRight(width);
        for (var k = 0; k < width; k++) {
          chars[bodyStart + run.start + k] = padded[k];
        }
      }
      i = run.last + 2;
      continue;
    }
    if (qualifiedType(run) && next != '%' && next != '(') {
      replace(bodyStart + run.start, run.end - run.start, next == '[');
    }
    i = run.last;
  }
  return chars.join();
}

/// libpg_query gives no cursor position for PL/pgSQL errors: use "near line N" from the context and the token
/// from 'at or near "X"' to find the place in the body (best effort, ADR 0002).
int _locatePlpgsqlError(PgSyntaxError error, String check, int bodyAt, int bodyLength) {
  final body = check.substring(bodyAt, (bodyAt + bodyLength).clamp(0, check.length));
  var from = 0;
  final line = RegExp(r'line (\d+)').firstMatch(error.context ?? '');
  if (line != null) {
    final n = int.parse(line.group(1)!);
    for (var k = 1; k < n && from >= 0; k++) {
      from = body.indexOf('\n', from) + 1;
      if (from == 0) break;
    }
  }
  final near = RegExp(r'at or near "([^"]*)"').firstMatch(error.message);
  if (near != null) {
    final at = body.indexOf(near.group(1)!, from);
    if (at >= 0) return at;
    final anywhere = body.indexOf(near.group(1)!);
    if (anywhere >= 0) return anywhere;
  }
  return from.clamp(0, body.length);
}

/// The end of the token an error points at (the whole word is underlined), or one character after [at].
int _errorEnd(String text, int at) {
  if (at >= text.length) return text.length;
  final m = RegExp(r'[A-Za-z0-9_\$"]+').matchAsPrefix(text, at);
  if (m != null && m.end > at) return m.end;
  return at + 1;
}
