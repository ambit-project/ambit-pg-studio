/// Offline analysis of PostgreSQL database projects (SQL files, Liquibase changesets) for ambit.pg-studio.app.
library;

export 'src/analysis/columns.dart' show ColumnUse;
export 'src/analysis/extract.dart' show analyzeFile;
export 'src/complete/complete.dart';
export 'src/conventions/conventions.dart';
export 'src/conventions/rules.dart' show RuleOptions, ActorRule, applyQuickFix, quickFixTitle;
export 'src/format/formatter.dart';
export 'src/git.dart';
export 'src/graph/er.dart';
export 'src/graph/graph.dart';
export 'src/highlight/highlight.dart';
export 'src/history/changes.dart';
export 'src/history/history.dart';
export 'src/index/cache.dart' show Phase1Cache, analysisVersion, encodeAnalysis;
export 'src/index/indexer.dart';
export 'src/index/project_index.dart';
export 'src/liquibase.dart' show prepareSql, PreparedText;
export 'src/model.dart';
export 'src/pg_query/pg_query.dart';
export 'src/refactor/rename.dart';
export 'src/refactor/search.dart';
export 'src/refactor/templates.dart';
