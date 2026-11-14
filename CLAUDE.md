# ambit.pg-studio.app

PG Studio: a Flutter desktop (Linux only) editor that opens a folder of PostgreSQL database files (Liquibase formatted
SQL: tables, procedures, views, functions) and analyses it **without a database connection** - go to definition, find
references, hover, quick search, dependency graph, editing with re-indexing, and the conventions of our stack (modules
`nn-`, `<module>_app` contract, `ERRCODE U1xxx`). What and why: `PRODUCT.md` (mirrors the SDD project
"ambit.pg-studio.app", http://127.0.0.1:9494/wiki/sdd); decisions: `docs/adr/`. Agent prompts:
`.instructions/NNN-slug.md` (local, not committed). Docs and code in English; the SDD project in Polish.

## Commands

```bash
git submodule update --init          # libpg_query 18.1.0 in third_party/
./verify core                        # pg_core unit tests (dart test, no Flutter)
./verify corpus                      # pg_core on the real db folders of ../ambit.wms.app etc. (read only, skipped when missing)
./verify conventions                 # stack conventions
./verify lint                        # dart format (page width 120) + analyzers
./verify ui|nav|editor|graph         # widget tests in test/<group>/ (also format, authoring, columns, history, cli, package)
./verify build                       # flutter build linux --release
./verify all                         # before a PR
flutter run -d linux
```

## Architecture

- `packages/pg_core` - pure Dart: `lib/src/pg_query/` (FFI to libpg_query, `SourceText` converts UTF-8 byte and
  character positions to UTF-16 offsets), the analysis runs in an isolate; phase 1 is cached in `~/.cache/pg_studio/`
  (bump `analysisVersion` in `lib/src/index/cache.dart` when phase 1 output changes); `hook/build.dart` builds
  libpg_query with its Makefile and bundles `libpg_query.so` (ADR 0001).
- `lib/app/` state (ChangeNotifier), `lib/ui/` widgets; the UI reads the index from pg_core and never parses SQL
  itself (ADR 0003: re_editor with our spans, pointer mapping, one editor per tab, the disk watched).
- `integration_test/screens_test.dart -d linux`: the real window on the real folders, writes `docs/screens/`.

## Rules

- Never connect to a database. Test folders of other repos (`../ambit.wms.app/db`, `../halycon.app.dev/db`,
  `../ambit.jobtron.app/db`) are read only: no files, caches or branches there; caches go to `~/.cache/pg_studio/`.
- SDD: every feature is a spec in the wiki with criteria; a criterion is Passed only with evidence (command output,
  screenshots in `docs/screens/`). Gates are approved only by the owner.
- Conventional commits, small commits that build (`./verify lint` and the touched group green).
- Remote: public `ambit-project/ambit-pg-studio` (MIT) (never `kldev/ambit.*`); push only on request; no force push.
