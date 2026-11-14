# 0004. SQL formatting changes whitespace only, never deployed changesets

Status: accepted (2026-11-14) - project "ambit.pg-studio.app 2.0", spec 001

## Context

Formatting runs on files that are the logic of the system (procedures, views) and on Liquibase changesets. Two risks:
a change of meaning, and a change of a changeset Liquibase has already run (its checksum fails the next deployment;
`check-module-changesets.sh --base` forbids such edits).

The plan (Shape, decision D2) was to use the libpg_query 18 deparser (`pretty_print`, comments from
`pg_query_deparse_comments_for_query`). A spike on the three folders showed it keeps the meaning (canonical deparse
equal) but degrades hand-written code: it moves comments into expressions (even inside `ARRAY[...]`), rewrites
`interval '1 day'` to `'1 day'::interval` and `::integer` to `::int`, packs select lists, expands `(SELECT f())` over
four lines and flattens routine headers to one line. The repositories are written carefully; the deparser made 69 of
69 wms views worse.

## Decision

- **Whitespace only.** Our own formatter on scanner tokens; a guard compares the token streams (dollar-quoted bodies
  by their own tokens, comments by their text) and rejects any result where something else changed - the text stays
  as written and the summary says why.
- **Statements** (SELECT, DML, views, tables, indexes): the author's line breaks stay; indentation follows the
  structure - clauses (`SELECT`, `FROM`, `JOIN`, `WHERE`, ...) at the level of their query, items one level deeper,
  parenthesised subqueries and lists and `CASE` as nested groups; a comment line takes the indentation of the code
  below it; a line over `maxLineLength` is broken before its clauses, then after the items of its SELECT list.
- **Routines**: header with one parameter per line (a short one-line list stays one line; a list the author wrote on
  several lines stays multi-line), each clause (`RETURNS`, `LANGUAGE`, `SECURITY`, `SET`, ...) on its line,
  `RETURNS TABLE (...)` like the parameters, `AS $$` in column 0. PL/pgSQL bodies are re-indented by their blocks
  (`DECLARE`/`BEGIN`/`END`, `IF`/`ELSIF`/`ELSE`, loops, `CASE`, `EXCEPTION`/`WHEN`); a SQL statement inside a body
  keeps the relative indentation of its lines and ends only at `;`.
- **Other statements** (`SET`, `GRANT`, `CREATE SCHEMA`, ...) stay exactly as written.
- **Liquibase**: changesets without `runOnChange:true` are not touched unless the file is not in the main branch yet
  (`git cat-file -e main:<path>`; without git: treated as deployed). psql scripts are not formatted.
- **Options** in `.pgstudio.json` of the project (or a folder above): `format.indent` (4), `maxLineLength` (120),
  `clauseIndent` (0; 4 for the halycon style), `keywordCase` (`preserve` | `upper`, bodies only), `formatOnSave`.
  `AS` before aliases and commas at line ends are kept by construction (D5).
- The deparser bindings stay in pg_core (`PgQuery.deparsePretty`, `canonical`, `fingerprint`) for later uses.

## Measured (`./verify format`)

| Folder | Files changed | Deployed changesets left | Rejected by the guard | Not idempotent |
|---|---|---|---|---|
| ambit.jobtron.app/db | 1 | 8 | 0 | 0 |
| ambit.wms.app/db | 69 | 33 | 0 | 0 |
| halycon.app.dev/db/changelog | 444 | 201 | 0 | 0 |

`orders_app.asn_save.sql` formats to itself byte for byte. wms changes are `AND` lines indented by 4 instead of 2;
halycon has two header styles (functions indent their clauses, procedures do not) - `clauseIndent` picks one.
