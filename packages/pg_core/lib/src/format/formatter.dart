// SQL formatting that never changes meaning (ADR 0004, project 2.0 D2-D5):
// - plain statements (SELECT, DML, views, tables, indexes) through the libpg_query 18 deparser with comments, then AS
//   put back before table aliases; accepted only when the canonical deparse and the comments are the same;
// - routine headers (one parameter / clause per line) and PL/pgSQL bodies (indentation by blocks) by our own token
//   formatter; accepted only when the tokens without whitespace are the same;
// - other statements (SET, GRANT, CREATE SCHEMA, ...) stay as written;
// - Liquibase changesets already deployed (no runOnChange) are never touched (their checksum would change).
import 'dart:convert';
import 'dart:io';

import '../liquibase.dart';
import '../pg_query/pg_query.dart';
import 'layout.dart';

enum KeywordCase { preserve, upper }

final class FormatOptions {
  const FormatOptions({
    this.indent = 4,
    this.maxLineLength = 120,
    this.commasStartOfLine = false,
    this.keywordCase = KeywordCase.preserve,
    this.formatOnSave = false,
    this.clauseIndent = 0,
  });

  /// From the `format` object of `.pgstudio.json` in the project folder; unknown keys are ignored.
  factory FormatOptions.fromJson(Map<String, Object?>? json) {
    if (json == null) return const FormatOptions();
    return FormatOptions(
      indent: (json['indent'] as num?)?.toInt() ?? 4,
      maxLineLength: (json['maxLineLength'] as num?)?.toInt() ?? 120,
      commasStartOfLine: json['commasStartOfLine'] == true,
      keywordCase: json['keywordCase'] == 'upper' ? KeywordCase.upper : KeywordCase.preserve,
      formatOnSave: json['formatOnSave'] == true,
      clauseIndent: (json['clauseIndent'] as num?)?.toInt() ?? 0,
    );
  }

  /// The `format` section of the nearest `.pgstudio.json` in [folder] or a folder above it (defaults when none).
  static FormatOptions forFolder(String folder) {
    var dir = Directory(folder).absolute;
    while (true) {
      final file = File('${dir.path}/.pgstudio.json');
      if (file.existsSync()) {
        try {
          final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
          return FormatOptions.fromJson(json['format'] as Map<String, Object?>?);
        } on Object {
          return const FormatOptions();
        }
      }
      final parent = dir.parent;
      if (parent.path == dir.path) return const FormatOptions();
      dir = parent;
    }
  }

  final int indent;
  final int maxLineLength;
  final bool commasStartOfLine;
  final KeywordCase keywordCase;
  final bool formatOnSave;

  /// Indentation of the clauses after a routine's parameters (RETURNS, LANGUAGE, SECURITY, SET; not AS): 0 in
  /// ambit.wms.app, 4 in halycon.app.dev.
  final int clauseIndent;
}

/// A part of the text left as it was, and why.
final class FormatSkip {
  const FormatSkip(this.start, this.end, this.reason);

  final int start;
  final int end;
  final String reason;

  @override
  String toString() => '[$start,$end) $reason';
}

final class FormatResult {
  const FormatResult(this.text, this.skipped, this.formattedStatements);

  final String text;
  final List<FormatSkip> skipped;
  final int formattedStatements;
}

const _deparsed = {
  'SelectStmt',
  'InsertStmt',
  'UpdateStmt',
  'DeleteStmt',
  'MergeStmt',
  'ViewStmt',
  'CreateStmt',
  'CreateTableAsStmt',
  'IndexStmt',
};

/// Formats [text]; with [rangeStart]/[rangeEnd] only the statements that touch that range. [fileIsNew]: the file is
/// not deployed yet (not in the main branch), so changesets without runOnChange may be formatted too.
FormatResult formatSql(
  String text, {
  FormatOptions options = const FormatOptions(),
  int? rangeStart,
  int? rangeEnd,
  bool fileIsNew = false,
}) {
  final prepared = prepareSql(text);
  final skipped = <FormatSkip>[];
  if (prepared.isPsqlScript) {
    return FormatResult(text, [FormatSkip(0, text.length, 'psql script (meta-commands and variables)')], 0);
  }
  final chunks = prepared.changesets.isEmpty
      ? [(0, text.length, null as Map<String, String>?)]
      : [for (final c in prepared.changesets) (c.start, c.end, c.attributes)];
  final out = StringBuffer();
  var copied = 0;
  var count = 0;
  final from = rangeStart ?? 0;
  final to = rangeEnd ?? text.length;
  for (final (start, end, attributes) in chunks) {
    if (end <= from || start >= to) continue;
    if (prepared.isLiquibase && attributes != null && attributes['runOnChange'] != 'true' && !fileIsNew) {
      skipped.add(
        FormatSkip(start, end, 'changeset without runOnChange: already deployed, formatting would change its checksum'),
      );
      continue;
    }
    final chunk = prepared.sql.substring(start, end);
    final source = SourceText(chunk);
    final parsed = PgQuery.parseSource(source);
    if (!parsed.ok) {
      skipped.add(FormatSkip(start, end, 'syntax error: ${parsed.error!.message}'));
      continue;
    }
    final tokens = PgQuery.scan(chunk);
    for (final raw in parsed.statements) {
      final loc = (raw['stmt_location'] as int?) ?? 0;
      final len = raw['stmt_len'] as int?;
      final s = source.offsetOfByte(loc);
      final e = (len == null || len == 0) ? chunk.length : source.offsetOfByte(loc + len);
      // The statement location includes the whitespace and comments after the previous semicolon.
      final first = tokens.where((t) => t.start >= s && t.name != 'SQL_COMMENT' && t.name != 'C_COMMENT').firstOrNull;
      if (first == null || first.start >= e) continue;
      final coreStart = first.start;
      if (start + e <= from || start + coreStart >= to) continue;
      final core = chunk.substring(coreStart, e);
      final type = (raw['stmt'] as Map<String, Object?>).keys.first;
      final node = (raw['stmt'] as Map<String, Object?>).values.first as Map<String, Object?>;
      String? formatted;
      String? problem;
      try {
        if (type == 'CreateFunctionStmt') {
          (formatted, problem) = _routine(core, node, options);
        } else if (type == 'DoStmt') {
          (formatted, problem) = _doBlock(core, options);
        } else if (_deparsed.contains(type)) {
          (formatted, problem) = _deparse(core, options);
        }
      } on Object catch (x) {
        problem = 'formatter error: $x';
      }
      if (problem != null) skipped.add(FormatSkip(start + coreStart, start + e, problem));
      if (formatted == null || formatted == core) continue;
      out.write(text.substring(copied, start + coreStart));
      out.write(restoreProperties(formatted, prepared.properties));
      copied = start + e;
      count++;
    }
  }
  out.write(text.substring(copied));
  return FormatResult(out.toString(), skipped, count);
}

// --- plain statements: the deparser --------------------------------------------------------------------------------

(String?, String?) _deparse(String core, FormatOptions o) {
  final laid = layoutSql(core, o);
  if (laid == null) return (null, 'scanner error: left as written');
  if (!_sameTokens(core, laid, o)) return (null, 'guard: the formatted statement differs');
  return (laid, null);
}

// --- routines: our header formatter + PL/pgSQL body ----------------------------------------------------------------

const _clauseStarts = {
  'RETURNS',
  'LANGUAGE',
  'SECURITY',
  'SET',
  'IMMUTABLE',
  'STABLE',
  'VOLATILE',
  'STRICT_P',
  'CALLED',
  'PARALLEL',
  'COST',
  'ROWS',
  'LEAKPROOF',
  'NOT',
  'WINDOW',
  'TRANSFORM',
  'SUPPORT',
  'EXTERNAL',
  'AS',
};

(String?, String?) _routine(String core, Map<String, Object?> node, FormatOptions o) {
  final all = PgQuery.scan(core);
  if (all.isEmpty) return (null, 'scanner error');
  String text(PgToken t) => core.substring(t.start, t.end);
  final open = all.indexWhere((t) => text(t) == '(');
  if (open < 0) return (null, null);
  var depth = 0;
  var close = -1;
  for (var i = open; i < all.length; i++) {
    final s = text(all[i]);
    if (s == '(') depth++;
    if (s == ')' && --depth == 0) {
      close = i;
      break;
    }
  }
  if (close < 0) return (null, null);
  String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
  final pad = ' ' * o.indent;
  final clausePad = ' ' * o.clauseIndent;
  final b = StringBuffer(norm(core.substring(0, all[open].end)));

  /// `head(` + the items between tokens [open] and [close] + `)`: on one line when it fits and has no comments,
  /// else one item per line (comments on their own lines).
  String list(String head, int open, int close) {
    final items = <String>[];
    final comments = <int, List<String>>{};
    var segStart = -1;
    var d = 0;
    for (var i = open + 1; i < close; i++) {
      final t = all[i];
      final s = text(t);
      if (t.name == 'SQL_COMMENT' || t.name == 'C_COMMENT') {
        (comments[items.length] ??= []).add(s.trimRight());
        continue;
      }
      if (s == '(' || s == '[') d++;
      if (s == ')' || s == ']') d--;
      if (s == ',' && d == 0) {
        if (segStart >= 0) items.add(norm(core.substring(all[segStart].start, all[i - 1].end)));
        segStart = -1;
        continue;
      }
      if (segStart < 0) segStart = i;
    }
    if (segStart >= 0) items.add(norm(core.substring(all[segStart].start, all[close - 1].end)));
    final oneLine = '$head${items.join(', ')})';
    // The author's layout wins: a list written over several lines stays one item per line.
    final writtenMultiLine = core.substring(all[open].end, all[close].start).contains('\n');
    if (items.isEmpty || (!writtenMultiLine && comments.isEmpty && oneLine.length <= o.maxLineLength)) return oneLine;
    final out = StringBuffer(head);
    for (var i = 0; i < items.length; i++) {
      for (final c in comments[i] ?? const <String>[]) {
        out.write('\n$pad$c');
      }
      out.write('\n$pad${items[i]}${i < items.length - 1 ? ',' : ''}');
    }
    for (final c in comments[items.length] ?? const <String>[]) {
      out.write('\n$pad$c');
    }
    out.write('\n)');
    return out.toString();
  }

  int closing(int from) {
    var d = 0;
    for (var i = from; i < all.length; i++) {
      final s = text(all[i]);
      if (s == '(') d++;
      if (s == ')' && --d == 0) return i;
    }
    return -1;
  }

  final head = b.toString();
  b
    ..clear()
    ..write(list(head, open, close));

  // Clauses after the parameters, one per line; the body as written by the PL/pgSQL formatter.
  var i = close + 1;
  String? bodyProblem;
  (String, String)? originalBody;
  while (i < all.length) {
    final t = all[i];
    if (t.name == 'SQL_COMMENT' || t.name == 'C_COMMENT') {
      b.write('\n$clausePad${text(t).trimRight()}');
      i++;
      continue;
    }
    // A clause runs to the next clause keyword at depth 0 (or a comment).
    var j = i + 1;
    depth = 0;
    for (; j < all.length; j++) {
      final s = text(all[j]);
      if (all[j].name == 'SQL_COMMENT' || all[j].name == 'C_COMMENT') break;
      if (s == '(') depth++;
      if (s == ')') depth--;
      if (depth == 0 && _clauseStarts.contains(all[j].name) && !_continuesClause(all, j, core)) break;
    }
    final clause = all.sublist(i, j);
    final tableOpen = t.name == 'RETURNS' && clause.length >= 3 && clause[1].name == 'TABLE' && text(clause[2]) == '('
        ? i + 2
        : -1;
    if (tableOpen >= 0 && closing(tableOpen) == j - 1) {
      b.write('\n$clausePad${list('RETURNS TABLE (', tableOpen, j - 1).replaceAll('\n', '\n$clausePad')}');
    } else if (t.name == 'AS' && clause.length >= 2 && text(clause[1]).startsWith(r'$')) {
      final body = text(clause[1]);
      final tagEnd = body.indexOf(r'$', 1);
      final tag = body.substring(0, tagEnd + 1);
      final inner = body.substring(tag.length, body.length - tag.length);
      final language = _languageOf(node);
      String? newInner;
      if (language == 'plpgsql') {
        newInner = reindentPlpgsql(inner, o);
        if (newInner == null) bodyProblem = 'PL/pgSQL body left as written (scanner error or guard)';
      } else if (language == 'sql') {
        newInner = _sqlBody(inner, o);
        if (newInner == null) bodyProblem = 'SQL body left as written (guard)';
      }
      b.write('\nAS $tag${newInner ?? inner}$tag'); // AS $$ starts the body in column 0 in both styles
      originalBody = (inner, newInner ?? inner);
      if (clause.length > 2) b.write(' ${norm(core.substring(clause[2].start, clause.last.end))}');
    } else {
      b.write('\n$clausePad${norm(core.substring(clause.first.start, clause.last.end))}');
    }
    i = j;
  }
  final result = b.toString();
  // Guard on the header: the same tokens apart from whitespace. The body has its own guard (PL/pgSQL: tokens,
  // SQL: canonical deparse), so it is compared here as it was.
  final header = originalBody == null ? result : result.replaceFirst(originalBody.$2, originalBody.$1);
  if (!_sameTokens(core, header, o)) return (null, 'guard: the formatted routine header differs');
  return (result, bodyProblem);
}

/// `NOT` starts a clause only as NOT LEAKPROOF; `SET` inside `RETURNS SETOF` is part of RETURNS.
bool _continuesClause(List<PgToken> all, int j, String core) {
  final t = all[j];
  if (t.name == 'NOT') return j + 1 < all.length && all[j + 1].name != 'LEAKPROOF';
  return false;
}

String? _languageOf(Map<String, Object?> node) {
  for (final o in (node['options'] as List? ?? const [])) {
    final d = (o as Map<String, Object?>)['DefElem'] as Map<String, Object?>;
    if (d['defname'] == 'language') return ((d['arg'] as Map)['String'] as Map)['sval'] as String;
  }
  return null;
}

String? _sqlBody(String inner, FormatOptions o) {
  final trimmed = inner.trim();
  final laid = layoutSql(trimmed, o);
  if (laid == null || !_sameTokens(trimmed, laid, o)) return null;
  final pad = ' ' * o.indent;
  return '\n${laid.split('\n').map((l) => l.isEmpty ? l : '$pad$l').join('\n')}\n';
}

(String?, String?) _doBlock(String core, FormatOptions o) {
  final tokens = PgQuery.scan(core);
  final body = tokens.where((t) => t.name == 'SCONST' && core.substring(t.start, t.end).startsWith(r'$')).firstOrNull;
  if (body == null) return (null, null);
  final raw = core.substring(body.start, body.end);
  final tag = raw.substring(0, raw.indexOf(r'$', 1) + 1);
  final inner = raw.substring(tag.length, raw.length - tag.length);
  final newInner = reindentPlpgsql(inner, o);
  if (newInner == null) return (null, 'PL/pgSQL body left as written (scanner error or guard)');
  return ('${core.substring(0, body.start)}$tag$newInner$tag${core.substring(body.end)}', null);
}

bool _sameTokens(String a, String b, FormatOptions o) {
  List<String> tokens(String s) {
    final out = <String>[];
    for (final t in PgQuery.scan(s)) {
      var x = s.substring(t.start, t.end);
      if (t.name == 'SQL_COMMENT' || t.name == 'C_COMMENT') x = x.trimRight();
      if (t.name == 'SCONST' && x.startsWith(r'$')) {
        // Dollar-quoted bodies: compared by their own tokens (whitespace inside may change).
        final tag = x.substring(0, x.indexOf(r'$', 1) + 1);
        out.add(tag);
        out.addAll(tokens(x.substring(tag.length, x.length - tag.length)));
        continue;
      }
      out.add(t.isKeyword ? x.toUpperCase() : x);
    }
    return out;
  }

  final x = tokens(a);
  final y = tokens(b);
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

// --- PL/pgSQL indentation ------------------------------------------------------------------------------------------

/// Re-indents a PL/pgSQL body by its blocks (DECLARE/BEGIN/END, IF/ELSIF/ELSE, LOOP, CASE, EXCEPTION/WHEN) and keeps
/// the relative indentation of statements spanning several lines. Only whitespace changes (and keyword case with
/// [FormatOptions.keywordCase]); returns null when the body cannot be scanned or the guard fails.
String? reindentPlpgsql(String body, FormatOptions o) {
  String? scanError;
  final tokens = PgQuery.scan(body, onError: (e) => scanError = e.message);
  if (scanError != null) return null;
  final lines = body.split('\n');
  // Lines that start inside a multi-line token (a string or a /* comment */) stay exactly as they are.
  final lineStarts = <int>[];
  var pos = 0;
  for (final l in lines) {
    lineStarts.add(pos);
    pos += l.length + 1;
  }
  final insideToken = List<bool>.filled(lines.length, false);
  for (final t in tokens) {
    for (var k = 0; k < lines.length; k++) {
      if (lineStarts[k] > t.start && lineStarts[k] < t.end) insideToken[k] = true;
    }
  }

  final stack = <String>[];
  var inStatement = false;
  var statementFirst = '';
  var statementOriginal = 0;
  var statementNew = 0;
  final out = <String>[];
  var blank = 0;
  String indentOf(int level) => ' ' * (o.indent * (level < 0 ? 0 : level));
  final pendingComments = <String>[];
  void flushComments(int column) {
    for (final c in pendingComments) {
      out.add('${' ' * column}$c');
    }
    pendingComments.clear();
  }

  int leading(String l) => l.length - l.trimLeft().length;

  for (var k = 0; k < lines.length; k++) {
    final raw = lines[k].replaceAll('\t', ' ' * o.indent);
    if (insideToken[k]) {
      out.add(lines[k]);
      continue;
    }
    final line = raw.trimRight();
    final content = line.trimLeft();
    if (content.isEmpty) {
      // The first and last lines of the body (around $$) stay empty; at most one blank line elsewhere.
      if (k < lines.length - 1) flushComments(o.indent * stack.length);
      if (k == 0 || k == lines.length - 1 || blank == 0) out.add('');
      blank++;
      continue;
    }
    blank = 0;
    final words = _words(content);
    final first = words.isEmpty ? '' : words.first;
    final isComment = content.startsWith('--') || content.startsWith('/*');

    if (inStatement) {
      // Continuation lines keep their indentation relative to the first line of the statement.
      final extra = leading(raw) - statementOriginal;
      flushComments(statementNew + (extra > 0 ? extra : 0));
      out.add('${' ' * (statementNew + (extra > 0 ? extra : 0))}$content');
    } else if (isComment) {
      // A comment describes the code below it: it gets that line's indentation (see flushComments).
      pendingComments.add(content);
      continue;
    } else {
      var level = stack.length;
      switch (first) {
        case 'END':
          if (stack.isNotEmpty && stack.last == 'when') stack.removeLast();
          if (stack.isNotEmpty) stack.removeLast();
          level = stack.length;
        case 'ELSE' || 'ELSIF':
          level = stack.length - 1; // the level of its IF (or of the WHEN of a CASE statement)
        case 'EXCEPTION':
          if (stack.isNotEmpty && stack.last == 'when') stack.removeLast();
          level = stack.length - 1;
          if (stack.isNotEmpty) stack[stack.length - 1] = 'exception';
        case 'WHEN':
          if (stack.isNotEmpty && stack.last == 'when') stack.removeLast();
          level = stack.length;
        case 'BEGIN':
          if (stack.isNotEmpty && stack.last == 'declare') stack.removeLast();
          level = stack.length;
        case 'DECLARE':
          level = stack.length;
      }
      if (first == 'EXCEPTION' && stack.isNotEmpty) level = stack.length - 1;
      statementFirst = first;
      statementOriginal = leading(raw);
      statementNew = o.indent * (level < 0 ? 0 : level);
      flushComments(statementNew);
      out.add('${indentOf(level)}$content');
      // Block openers and the end of the statement.
      switch (first) {
        case 'DECLARE':
          stack.add('declare');
        case 'BEGIN':
          stack.add('block');
        case 'CASE':
          stack.add('case');
      }
      if (first == 'EXCEPTION') {
        inStatement = false;
        continue;
      }
    }
    final lastWord = _lastWord(content);
    // PL/pgSQL control statements end at THEN/LOOP/...; SQL statements and assignments only at ';' (a CASE ... THEN
    // at the end of a line inside an UPDATE is not the end of anything).
    final head = inStatement ? statementFirst : first;
    final structural = _structural.contains(head) || content.startsWith('<<');
    final ends =
        content.trimRight().endsWith(';') ||
        (structural && {'THEN', 'LOOP', 'BEGIN', 'DECLARE', 'ELSE', 'EXCEPTION'}.contains(lastWord)) ||
        (!inStatement && {'DECLARE', 'BEGIN', 'ELSE', 'EXCEPTION'}.contains(first) && words.length == 1) ||
        (!inStatement && first == 'CASE') ||
        (!inStatement && content.startsWith('<<'));
    if (!inStatement) {
      inStatement = !ends;
      _opens(first, lastWord, stack);
    } else if (ends) {
      inStatement = false;
      _opensAtEnd(statementFirst, lastWord, stack);
    }
  }
  flushComments(o.indent * stack.length);
  var result = out.join('\n');
  if (!result.endsWith('\n')) result = '$result\n';
  if (o.keywordCase == KeywordCase.upper) result = _upperKeywords(result);
  if (!_sameTokens(body, result, o)) return null;
  return result;
}

const _structural = {
  'IF',
  'ELSIF',
  'ELSE',
  'WHEN',
  'FOR',
  'FOREACH',
  'WHILE',
  'LOOP',
  'BEGIN',
  'DECLARE',
  'EXCEPTION',
  'CASE',
};

const _plpgsqlWords = {
  'begin',
  'end',
  'if',
  'then',
  'elsif',
  'else',
  'loop',
  'declare',
  'return',
  'perform',
  'raise',
  'exception',
  'when',
  'foreach',
  'while',
  'for',
  'in',
  'exit',
  'continue',
  'call',
  'into',
  'strict',
  'using',
  'notice',
  'found',
  'query',
};

/// Reserved SQL keywords and PL/pgSQL statement words in upper case; names after or before a dot stay.
String _upperKeywords(String body) {
  final tokens = PgQuery.scan(body);
  final b = StringBuffer();
  var last = 0;
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    final raw = body.substring(t.start, t.end);
    final dotted =
        (i > 0 && body.substring(tokens[i - 1].start, tokens[i - 1].end) == '.') ||
        (i + 1 < tokens.length && body.substring(tokens[i + 1].start, tokens[i + 1].end) == '.');
    final upper =
        !dotted && (t.keywordKind == 4 || ((t.name == 'IDENT' || t.isKeyword) && _plpgsqlWords.contains(raw)));
    if (!upper || raw == raw.toUpperCase()) continue;
    b.write(body.substring(last, t.start));
    b.write(raw.toUpperCase());
    last = t.end;
  }
  b.write(body.substring(last));
  return b.toString();
}

/// Effects of a one-line statement start: IF ... THEN, WHEN ... THEN, ... LOOP.
void _opens(String first, String last, List<String> stack) {
  if (first == 'IF' && last == 'THEN') stack.add('if');
  if (first == 'WHEN' && last == 'THEN' && stack.isNotEmpty && (stack.last == 'exception' || stack.last == 'case')) {
    stack.add('when');
  }
  if (last == 'LOOP' && first != 'END') stack.add('loop');
}

/// Effects of a statement that ends on a later line: a multi-line IF/WHEN condition ends with THEN (ELSIF opens
/// nothing - it stays in its IF), a multi-line FOR/WHILE/FOREACH ends with LOOP.
void _opensAtEnd(String first, String last, List<String> stack) {
  if (last == 'THEN' && first == 'IF') stack.add('if');
  if (last == 'THEN' && first == 'WHEN' && stack.isNotEmpty && (stack.last == 'exception' || stack.last == 'case')) {
    stack.add('when');
  }
  if (last == 'LOOP') stack.add('loop');
}

List<String> _words(String content) =>
    RegExp(r'[A-Za-z_][A-Za-z0-9_]*')
        .allMatches(content.split('--').first)
        .map((m) => m.group(0)!.toUpperCase())
        .toList();

String _lastWord(String content) {
  final code = content.split('--').first.trimRight();
  final m = RegExp(r'([A-Za-z_][A-Za-z0-9_]*)\s*$').firstMatch(code);
  return m == null ? '' : m.group(1)!.toUpperCase();
}
