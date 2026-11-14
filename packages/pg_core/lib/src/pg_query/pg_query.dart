// Dart API over libpg_query: parse SQL to the JSON tree, parse PL/pgSQL bodies, scan tokens and split statements.
// libpg_query reports positions in UTF-8 bytes (tree locations, tokens) or in characters (error cursor);
// everything here is converted to UTF-16 offsets of the Dart string, which is what editors and String use.
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart' as b;

/// A Dart string with its UTF-8 encoding and position conversions.
final class SourceText {
  SourceText(this.text) : bytes = utf8.encode(text);

  final String text;
  final Uint8List bytes;
  Int32List? _byteToUtf16;
  Int32List? _codePointToUtf16;

  /// UTF-16 offset of a UTF-8 byte offset (clamped to the text).
  int offsetOfByte(int byteOffset) {
    final map = _byteToUtf16 ??= _buildByteMap();
    if (byteOffset <= 0) return 0;
    if (byteOffset >= map.length) return text.length;
    return map[byteOffset];
  }

  /// UTF-16 offset of a code point index (clamped to the text).
  int offsetOfCodePoint(int index) {
    final map = _codePointToUtf16 ??= _buildCodePointMap();
    if (index <= 0) return 0;
    if (index >= map.length) return text.length;
    return map[index];
  }

  Int32List _buildByteMap() {
    final map = Int32List(bytes.length + 1);
    var byte = 0;
    var unit = 0;
    for (final rune in text.runes) {
      final width = rune < 0x80 ? 1 : (rune < 0x800 ? 2 : (rune < 0x10000 ? 3 : 4));
      for (var i = 0; i < width; i++) {
        map[byte + i] = unit;
      }
      byte += width;
      unit += rune >= 0x10000 ? 2 : 1;
    }
    map[byte] = unit;
    return map;
  }

  Int32List _buildCodePointMap() {
    final runes = text.runes.toList(growable: false);
    final map = Int32List(runes.length + 1);
    var unit = 0;
    for (var i = 0; i < runes.length; i++) {
      map[i] = unit;
      unit += runes[i] >= 0x10000 ? 2 : 1;
    }
    map[runes.length] = unit;
    return map;
  }
}

/// A syntax error from the PostgreSQL parser; [offset] is a UTF-16 offset into the parsed text, or null.
final class PgSyntaxError {
  const PgSyntaxError(this.message, this.offset, [this.context]);

  final String message;
  final int? offset;

  /// Additional context from PostgreSQL, e.g. `PL/pgSQL function a.f line 3 at SQL statement` (may be null).
  final String? context;

  @override
  String toString() => offset == null ? message : '$message (at $offset)';
}

/// The result of [PgQuery.parse]: the JSON parse tree (`{"version":..., "stmts":[...]}`) or an error.
final class PgParseResult {
  const PgParseResult._(this.tree, this.error);

  final Map<String, Object?>? tree;
  final PgSyntaxError? error;

  bool get ok => error == null;

  List<Map<String, Object?>> get statements => ((tree?['stmts'] as List?) ?? const []).cast<Map<String, Object?>>();
}

/// The result of [PgQuery.parsePlpgsql]: the JSON of the functions in the text, or an error.
///
/// The JSON is kept as text: libpg_query 18.1.0 emits invalid JSON for some functions (e.g. trigger functions),
/// and pg_core uses this parse only as a syntax check (ADR 0002).
final class PgPlpgsqlResult {
  const PgPlpgsqlResult._(this.functionsJson, this.error);

  final String? functionsJson;
  final PgSyntaxError? error;

  bool get ok => error == null;
}

/// A scanner token; [start] and [end] are UTF-16 offsets, [name] is the grammar token name (IDENT, SCONST,
/// SQL_COMMENT, SELECT, ...), [keywordKind] 0 = not a keyword, 1 unreserved, 2 col name, 3 type/func name,
/// 4 reserved.
final class PgToken {
  const PgToken(this.start, this.end, this.name, this.keywordKind);

  final int start;
  final int end;
  final String name;
  final int keywordKind;

  bool get isKeyword => keywordKind != 0;

  @override
  String toString() => '$name[$start,$end)';
}

/// A statement range from [PgQuery.split] in UTF-16 offsets.
final class PgStatementRange {
  const PgStatementRange(this.start, this.end);

  final int start;
  final int end;
}

abstract final class PgQuery {
  static final Map<int, String> _tokenNames = {};

  static PgParseResult parse(String sql) => parseSource(SourceText(sql));

  static PgParseResult parseSource(SourceText source) {
    return _withInput(source, (input) {
      final result = b.pg_query_parse(input);
      try {
        if (result.error != nullptr) return PgParseResult._(null, _error(result.error, source));
        final tree = jsonDecode(result.parse_tree.toDartString()) as Map<String, Object?>;
        return PgParseResult._(tree, null);
      } finally {
        b.pg_query_free_parse_result(result);
      }
    });
  }

  static PgPlpgsqlResult parsePlpgsql(String sql) {
    final source = SourceText(sql);
    return _withInput(source, (input) {
      final result = b.pg_query_parse_plpgsql(input);
      try {
        if (result.error != nullptr) return PgPlpgsqlResult._(null, _error(result.error, source));
        return PgPlpgsqlResult._(result.plpgsql_funcs.toDartString(), null);
      } finally {
        b.pg_query_free_plpgsql_parse_result(result);
      }
    });
  }

  /// Tokens of the text, comments included. On a scanner error (e.g. an unterminated string) the tokens up to
  /// the error are not available and [onError] gets the error.
  static List<PgToken> scan(String sql, {void Function(PgSyntaxError error)? onError}) =>
      scanSource(SourceText(sql), onError: onError);

  static List<PgToken> scanSource(SourceText source, {void Function(PgSyntaxError error)? onError}) {
    return _withInput(source, (input) {
      final result = b.pg_query_scan_tokens(input);
      try {
        if (result.error != nullptr) {
          onError?.call(_error(result.error, source));
          return const <PgToken>[];
        }
        final tokens = List<PgToken>.generate(result.n_tokens, (i) {
          final t = result.tokens[i];
          return PgToken(
            source.offsetOfByte(t.start),
            source.offsetOfByte(t.end),
            _tokenNames[t.token] ??= _tokenName(t.token),
            t.keyword_kind,
          );
        }, growable: false);
        return tokens;
      } finally {
        b.pg_query_free_scan_tokens_result(result);
      }
    });
  }

  /// Statement ranges by the parser (null on a syntax error).
  static List<PgStatementRange>? split(SourceText source) {
    return _withInput(source, (input) {
      final result = b.pg_query_split_with_parser(input);
      try {
        if (result.error != nullptr) return null;
        return List.generate(result.n_stmts, (i) {
          final s = result.stmts[i].ref;
          return PgStatementRange(
            source.offsetOfByte(s.stmt_location),
            source.offsetOfByte(s.stmt_location + s.stmt_len),
          );
        }, growable: false);
      } finally {
        b.pg_query_free_split_result(result);
      }
    });
  }

  /// Pretty-printed SQL of [sql] (all its statements) with its comments, or an error. The deparser of
  /// libpg_query 18: [indent] spaces, lists broken at [maxLineLength], commas at the end of lines unless
  /// [commasStartOfLine].
  static ({String? sql, PgSyntaxError? error}) deparsePretty(
    String sql, {
    int indent = 4,
    int maxLineLength = 100,
    bool commasStartOfLine = false,
  }) {
    final source = SourceText(sql);
    return _withInput(source, (input) {
      final parsed = b.pg_query_parse_protobuf(input);
      final comments = b.pg_query_deparse_comments_for_query(input);
      final opts = calloc<b.PostgresDeparseOpts>();
      try {
        if (parsed.error != nullptr) return (sql: null, error: _error(parsed.error, source));
        if (comments.error != nullptr) return (sql: null, error: _error(comments.error, source));
        opts.ref
          ..comments = comments.comments
          ..comment_count = comments.comment_count
          ..pretty_print = true
          ..indent_size = indent
          ..max_line_length = maxLineLength
          ..trailing_newline = false
          ..commas_start_of_line = commasStartOfLine;
        final out = b.pg_query_deparse_protobuf_opts(parsed.parse_tree, opts.ref);
        try {
          if (out.error != nullptr) {
            return (sql: null, error: PgSyntaxError(out.error.ref.message.toDartString(), null));
          }
          return (sql: out.query.toDartString(), error: null);
        } finally {
          b.pg_query_free_deparse_result(out);
        }
      } finally {
        calloc.free(opts);
        b.pg_query_free_deparse_comments_result(comments);
        b.pg_query_free_protobuf_parse_result(parsed);
      }
    });
  }

  /// The canonical (one-line) deparse of [sql]: two texts with the same canonical form mean the same.
  static String? canonical(String sql) {
    final source = SourceText(sql);
    return _withInput(source, (input) {
      final parsed = b.pg_query_parse_protobuf(input);
      try {
        if (parsed.error != nullptr) return null;
        final out = b.pg_query_deparse_protobuf(parsed.parse_tree);
        try {
          return out.error != nullptr ? null : out.query.toDartString();
        } finally {
          b.pg_query_free_deparse_result(out);
        }
      } finally {
        b.pg_query_free_protobuf_parse_result(parsed);
      }
    });
  }

  /// The libpg_query fingerprint (same query shape = same fingerprint), or null on a syntax error.
  static String? fingerprint(String sql) {
    final source = SourceText(sql);
    return _withInput(source, (input) {
      final r = b.pg_query_fingerprint(input);
      try {
        return r.error != nullptr ? null : r.fingerprint_str.toDartString();
      } finally {
        b.pg_query_free_fingerprint_result(r);
      }
    });
  }

  /// The grammar name of a token; libpg_query has no name for some single-character tokens (e.g. `$`).
  static String _tokenName(int token) {
    final name = b.pg_query_token_name(token);
    if (name == nullptr) return token < 128 ? 'ASCII_$token' : 'TOKEN_$token';
    return name.toDartString().replaceFirst('PG_QUERY_TOKEN_', '');
  }

  static PgSyntaxError _error(Pointer<b.PgQueryError> error, SourceText source) {
    final e = error.ref;
    final message = e.message.toDartString();
    // cursorpos is 1-based in characters; 0 = no position.
    final offset = e.cursorpos > 0 ? source.offsetOfCodePoint(e.cursorpos - 1) : null;
    final context = e.context == nullptr ? null : e.context.toDartString();
    return PgSyntaxError(message, offset, context);
  }

  static T _withInput<T>(SourceText source, T Function(Pointer<Utf8> input) body) {
    final input = malloc<Uint8>(source.bytes.length + 1);
    try {
      input.asTypedList(source.bytes.length).setAll(0, source.bytes);
      input[source.bytes.length] = 0;
      return body(input.cast<Utf8>());
    } finally {
      malloc.free(input);
    }
  }
}
