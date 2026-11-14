# 0002. Two-phase analysis: per-file extraction, project-wide linking

Status: accepted (2026-11-14)

## Decision

1. **Phase 1, per file** (`packages/pg_core/lib/src/analysis/`), independent of other files, run in up to 8 isolates:
   - `liquibase.dart` prepares the text **without changing its length**: Liquibase properties `${name}` become the
     identifier `__name_`, psql meta-command lines (`\set`) become spaces and psql variables `:x` / `:'x'` lose the
     colon. Offsets in the prepared text are offsets in the file.
   - Each `--changeset` is parsed separately (`pg_query_parse`), so a syntax error stays in its changeset.
   - Definitions (`Definition`) come from the JSON tree: tables (columns, ALTER TABLE add/drop), views (select list),
     materialized views, functions/procedures (parameters as written, input types for the identity, RETURNS, language,
     `SET search_path`), types, domains, sequences, indexes, triggers, schemas, extensions. Name positions the tree
     lacks (routine, index, trigger names) come from the scanner tokens of the statement.
   - References in DDL, views, top-level DML and `LANGUAGE sql` bodies come from the tree (RangeVar, FuncCall,
     TypeName) with their context: INSERT/UPDATE/DELETE/MERGE/TRUNCATE target = write, `REFERENCES` = foreign key,
     `CREATE TRIGGER ... ON` = trigger, `CREATE INDEX ... ON` = index, GRANT/COMMENT/DROP/ALTER by name.
   - **PL/pgSQL bodies**: the PL/pgSQL tree of libpg_query has no positions of expressions, so references come from the
     body's tokens and the clause they are in (`body_scan.dart`): `x.y(` = call, after FROM/JOIN = read, INSERT INTO /
     UPDATE / DELETE FROM / MERGE INTO / TRUNCATE = write, `%ROWTYPE`, `::`, DECLARE = type. `ERRCODE = 'X'` is
     collected with the nearest earlier comment mentioning the code.
   - `pg_query_parse_plpgsql` is only a syntax check. Before it, schema-qualified types in parameters and DECLARE
     (`s.t`, `s.t[]`, `s.t%ROWTYPE`) are replaced at the same offsets by `record`/`int`/`text` padded with spaces
     (libpg_query: "LookupExplicitNamespace only supports pg_catalog and public"). Its JSON output is not decoded:
     libpg_query 18.1.0 emits invalid JSON for some trigger functions.
   - An exception in the analysis of a file becomes a problem with code `internal`; the folder still opens.
2. **Phase 2, the project** (`index/project_index.dart`, milliseconds): objects keyed by space (relation, routine, type,
   schema, trigger, extension) + schema + name (+ input types for routines); references resolved with the qualified
   schema or the search path; overloads narrowed by the argument count (procedures count OUT parameters, PostgreSQL
   14+). After a change only the changed files repeat phase 1 (`Indexer.update`), then the whole link runs again.

## Unresolved references

A reference is reported as a warning only when it is qualified with a schema of the project and its context is clear
(a call, a relation after FROM/JOIN/INTO/UPDATE, a type). Unqualified names, `alias.column`, CTEs, variables and
built-ins (`pg_catalog`, `information_schema`) are dropped silently; DROP of a missing object is not a problem.

## Known limits

- PL/pgSQL errors have no cursor position in libpg_query: the place is found from "near line N" and the token in
  `at or near "X"` (best effort).
- Bodies in single quotes (not `$$`) are not scanned (escapes break offsets); none in our folders.
- `EXECUTE format(...)` dynamic SQL is text: its tables are not references.

## Measured (2026-11-14, `./verify corpus`)

| Folder | Files | Objects | References | Problems | Time |
|---|---|---|---|---|---|
| ambit.jobtron.app/db | 36 | 99 | 218 | 0 | 91 ms |
| ambit.wms.app/db | 211 | 485 | 2256 | 0 | 61 ms |
| halycon.app.dev/db/changelog | 901 | 1521 | 5545 | 0 | 88 ms |
