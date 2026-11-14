# 0001. libpg_query through dart:ffi, built by a build hook

Status: accepted (2026-11-14)

## Context

The editor analyses a folder of SQL files (Liquibase formatted SQL: tables, procedures, views, functions, PL/pgSQL
bodies) without a database connection. It needs the real PostgreSQL grammar: the folders use PostgreSQL 18 syntax,
`$$` bodies, `CREATE OR REPLACE PROCEDURE ... INOUT`, composite array parameters, `SECURITY DEFINER`,
`SET search_path`. A hand-written Dart parser would cover a subset and drift from PostgreSQL.

## Decision

- Parser: [libpg_query](https://github.com/pganalyze/libpg_query) **18.1.0** (the PostgreSQL 18 parser as a library),
  vendored as the git submodule `third_party/libpg_query` pinned to the tag.
- Functions used: `pg_query_parse` (JSON tree), `pg_query_parse_plpgsql` (PL/pgSQL bodies), `pg_query_scan_tokens`
  (tokens without protobuf, for highlighting), `pg_query_split_with_parser`; every result freed with its
  `pg_query_free_*`. Bindings are hand-written (`packages/pg_core/lib/src/pg_query/bindings.dart`, a dozen symbols;
  ffigen is not worth it for that).
- Build: `packages/pg_core/hook/build.dart` (Dart build hooks, `package:hooks` / `package:code_assets` 2.2) copies
  the submodule to the hook's shared output directory, runs the library's own `make build_shared` there (about 10 s,
  once per version) and registers `libpg_query.so` as the code asset of `bindings.dart` (`DynamicLoadingBundled`).
  The same hook serves `dart test`, `flutter test`, `flutter run` and `flutter build linux` (the `.so` lands in
  `bundle/lib/`); `linux/CMakeLists.txt` is untouched.
- Positions: libpg_query reports UTF-8 byte offsets (tree locations, tokens) and character positions (error
  cursor). `SourceText` converts both to UTF-16 offsets of the Dart string; comments in the folders are Polish.
- Linux only (D2): the hook refuses other target OSes.

## Spike (2026-11-14, before the decision)

| Folder | Files | Statements | Routines | Parse time |
|---|---|---|---|---|
| ambit.jobtron.app/db | 36 | 205 | 25 | 0.01 s |
| ambit.wms.app/db | 211 | 1009 | 123 | 0.05 s |
| halycon.app.dev/db | 902 | 3790 | 710 | 0.11 s |

Two workarounds were needed, both handled in pg_core (spec 002), not in the library:

1. Liquibase properties `${role_prefix}` are not SQL: replaced by an identifier of the same length before parsing.
2. `pg_query_parse_plpgsql` refuses parameter and variable types from a schema other than `pg_catalog`/`public`
   ("LookupExplicitNamespace only supports pg_catalog and public"). Before the PL/pgSQL parse such type names are
   replaced, at the same offsets, by a built-in type of the same length padding.

## Alternatives

- Pure Dart tokenizer/parser: simpler build, but a subset of the grammar and no PL/pgSQL tree.
- `postgresql_parser` on pub.dev (0.1.0, the only version, 2026-10-05; libpg_query through hooks, SQL and PL/pgSQL):
  closest match, but one release by a single author, 0 likes, unknown libpg_query version. Our bindings are a dozen
  symbols pinned to 18.1.0 with `pg_query_scan_tokens`; the dependency is not worth the risk. Revisit if it matures.
- `linux/CMakeLists.txt` building the library: works for the app bundle only, not for `dart test` of pg_core.

## Revisit when

libpg_query stops following PostgreSQL releases, or a platform other than Linux is needed.
