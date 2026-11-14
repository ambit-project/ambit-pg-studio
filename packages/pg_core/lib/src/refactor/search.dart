// Search and replace in all files of the project (2.0 spec 007). Texts come from the index, so unsaved edits count.
import '../index/project_index.dart';
import 'rename.dart';

final class SearchHit {
  const SearchHit(this.path, this.start, this.end, this.line, this.lineText, this.match);

  final String path;
  final int start;
  final int end;

  /// 0-based.
  final int line;
  final String lineText;
  final Match match;
}

/// Matches of [query] (plain text, or a regular expression with [regex]); [pathFilter] keeps files whose path
/// contains it. At most [limit] hits.
({List<SearchHit> hits, String? error}) searchProject(
  ProjectIndex index,
  String query, {
  bool regex = false,
  bool caseSensitive = false,
  bool wholeWord = false,
  String pathFilter = '',
  int limit = 5000,
}) {
  if (query.isEmpty) return (hits: const [], error: null);
  final RegExp pattern;
  try {
    var source = regex ? query : RegExp.escape(query);
    if (wholeWord) source = '\\b(?:$source)\\b';
    pattern = RegExp(source, caseSensitive: caseSensitive, multiLine: true);
  } on FormatException catch (e) {
    return (hits: const [], error: 'Invalid regular expression: ${e.message}');
  }
  final hits = <SearchHit>[];
  final filter = pathFilter.trim().toLowerCase();
  for (final path in index.order) {
    if (filter.isNotEmpty && !path.toLowerCase().contains(filter)) continue;
    final file = index.files[path];
    if (file == null) continue;
    for (final m in pattern.allMatches(file.text)) {
      if (m.end == m.start) continue;
      final (line, _) = file.lineColumn(m.start);
      final ls = file.lineStarts[line];
      final le = line + 1 < file.lineStarts.length ? file.lineStarts[line + 1] - 1 : file.text.length;
      hits.add(SearchHit(path, m.start, m.end, line, file.text.substring(ls, le), m));
      if (hits.length >= limit) return (hits: hits, error: null);
    }
  }
  return (hits: hits, error: null);
}

/// A plan replacing every hit with [replacement] (`$1`, `$2` ... are groups with [regex]); deployed changesets
/// (in main, without runOnChange) are skipped with a warning, like a rename.
RenamePlan replacePlan(
  ProjectIndex index,
  List<SearchHit> hits,
  String replacement, {
  bool regex = false,
  Set<String>? inMain,
}) {
  final plan = RenamePlan('Replace ${hits.length} matches');
  bool editable(String path) {
    final file = index.files[path];
    if (file == null) return false;
    if (inMain != null && !inMain.contains(path)) return true;
    return file.changesets.isEmpty
        ? inMain == null || !inMain.contains(path)
        : file.changesets.every((c) => c.attributes['runOnChange'] == 'true');
  }

  final skipped = <String, int>{};
  for (final h in hits) {
    if (!editable(h.path)) {
      skipped[h.path] = (skipped[h.path] ?? 0) + 1;
      continue;
    }
    final text = regex
        ? replacement.replaceAllMapped(RegExp(r'\$(\d)'), (m) {
            final g = int.parse(m.group(1)!);
            return g <= h.match.groupCount ? (h.match.group(g) ?? '') : m.group(0)!;
          })
        : replacement;
    plan.edit(h.path, TextEdit(h.start, h.end, text));
  }
  for (final e in skipped.entries) {
    plan.warnings.add('${e.key}: ${e.value} matches left as they are (deployed changeset).');
  }
  return plan;
}
