// Hand-written bindings to the part of pg_query.h (libpg_query 18.1.0) that pg_core uses. The code asset of this
// library is bundled by hook/build.dart; @Native resolves the symbols in it.
// ignore_for_file: non_constant_identifier_names
import 'dart:ffi';

import 'package:ffi/ffi.dart';

final class PgQueryError extends Struct {
  external Pointer<Utf8> message;
  external Pointer<Utf8> funcname;
  external Pointer<Utf8> filename;
  @Int()
  external int lineno;
  @Int()
  external int cursorpos;
  external Pointer<Utf8> context;
}

final class PgQueryParseResult extends Struct {
  external Pointer<Utf8> parse_tree;
  external Pointer<Utf8> stderr_buffer;
  external Pointer<PgQueryError> error;
}

final class PgQueryPlpgsqlParseResult extends Struct {
  external Pointer<Utf8> plpgsql_funcs;
  external Pointer<PgQueryError> error;
}

final class PgQueryScanToken extends Struct {
  @Int()
  external int start;
  @Int()
  external int end;
  @Int()
  external int token;
  @Int()
  external int keyword_kind;
}

final class PgQueryScanTokensResult extends Struct {
  external Pointer<PgQueryScanToken> tokens;
  @Int()
  external int n_tokens;
  external Pointer<PgQueryError> error;
}

final class PgQuerySplitStmt extends Struct {
  @Int()
  external int stmt_location;
  @Int()
  external int stmt_len;
}

final class PgQuerySplitResult extends Struct {
  external Pointer<Pointer<PgQuerySplitStmt>> stmts;
  @Int()
  external int n_stmts;
  external Pointer<Utf8> stderr_buffer;
  external Pointer<PgQueryError> error;
}

@Native<PgQueryParseResult Function(Pointer<Utf8>)>()
external PgQueryParseResult pg_query_parse(Pointer<Utf8> input);

@Native<Void Function(PgQueryParseResult)>()
external void pg_query_free_parse_result(PgQueryParseResult result);

@Native<PgQueryPlpgsqlParseResult Function(Pointer<Utf8>)>()
external PgQueryPlpgsqlParseResult pg_query_parse_plpgsql(Pointer<Utf8> input);

@Native<Void Function(PgQueryPlpgsqlParseResult)>()
external void pg_query_free_plpgsql_parse_result(PgQueryPlpgsqlParseResult result);

@Native<PgQueryScanTokensResult Function(Pointer<Utf8>)>()
external PgQueryScanTokensResult pg_query_scan_tokens(Pointer<Utf8> input);

@Native<Void Function(PgQueryScanTokensResult)>()
external void pg_query_free_scan_tokens_result(PgQueryScanTokensResult result);

@Native<Pointer<Utf8> Function(Int)>()
external Pointer<Utf8> pg_query_token_name(int token);

@Native<PgQuerySplitResult Function(Pointer<Utf8>)>()
external PgQuerySplitResult pg_query_split_with_parser(Pointer<Utf8> input);

@Native<Void Function(PgQuerySplitResult)>()
external void pg_query_free_split_result(PgQuerySplitResult result);

// --- deparse (formatting, spec 2.0/001) ---------------------------------------------------------------------------

final class PgQueryProtobuf extends Struct {
  @Size()
  external int len;
  external Pointer<Uint8> data;
}

final class PgQueryProtobufParseResult extends Struct {
  external PgQueryProtobuf parse_tree;
  external Pointer<Utf8> stderr_buffer;
  external Pointer<PgQueryError> error;
}

final class PgQueryDeparseResult extends Struct {
  external Pointer<Utf8> query;
  external Pointer<PgQueryError> error;
}

final class PgQueryDeparseCommentsResult extends Struct {
  external Pointer<Void> comments;
  @Size()
  external int comment_count;
  external Pointer<PgQueryError> error;
}

/// struct PostgresDeparseOpts (postgres_deparse.h).
final class PostgresDeparseOpts extends Struct {
  external Pointer<Void> comments;
  @Size()
  external int comment_count;
  @Bool()
  external bool pretty_print;
  @Int()
  external int indent_size;
  @Int()
  external int max_line_length;
  @Bool()
  external bool trailing_newline;
  @Bool()
  external bool commas_start_of_line;
}

final class PgQueryFingerprintResult extends Struct {
  @Uint64()
  external int fingerprint;
  external Pointer<Utf8> fingerprint_str;
  external Pointer<Utf8> stderr_buffer;
  external Pointer<PgQueryError> error;
}

@Native<PgQueryProtobufParseResult Function(Pointer<Utf8>)>()
external PgQueryProtobufParseResult pg_query_parse_protobuf(Pointer<Utf8> input);

@Native<Void Function(PgQueryProtobufParseResult)>()
external void pg_query_free_protobuf_parse_result(PgQueryProtobufParseResult result);

@Native<PgQueryDeparseResult Function(PgQueryProtobuf)>()
external PgQueryDeparseResult pg_query_deparse_protobuf(PgQueryProtobuf parseTree);

@Native<PgQueryDeparseResult Function(PgQueryProtobuf, PostgresDeparseOpts)>()
external PgQueryDeparseResult pg_query_deparse_protobuf_opts(PgQueryProtobuf parseTree, PostgresDeparseOpts opts);

@Native<Void Function(PgQueryDeparseResult)>()
external void pg_query_free_deparse_result(PgQueryDeparseResult result);

@Native<PgQueryDeparseCommentsResult Function(Pointer<Utf8>)>()
external PgQueryDeparseCommentsResult pg_query_deparse_comments_for_query(Pointer<Utf8> input);

@Native<Void Function(PgQueryDeparseCommentsResult)>()
external void pg_query_free_deparse_comments_result(PgQueryDeparseCommentsResult result);

@Native<PgQueryFingerprintResult Function(Pointer<Utf8>)>()
external PgQueryFingerprintResult pg_query_fingerprint(Pointer<Utf8> input);

@Native<Void Function(PgQueryFingerprintResult)>()
external void pg_query_free_fingerprint_result(PgQueryFingerprintResult result);
