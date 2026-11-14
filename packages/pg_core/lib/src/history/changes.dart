// The branch against main for a review (2.0 spec 010): changed objects, their uses, new problems, and changed
// deployed changesets (Liquibase would refuse them).
import 'dart:io';

import 'package:path/path.dart' as p;

import '../analysis/extract.dart';
import '../git.dart';
import '../index/indexer.dart';
import '../index/project_index.dart';
import '../model.dart';

final class ChangedObject {
  const ChangedObject(this.object, this.change, this.uses);

  final DbObject object;

  /// added (its file is new) or changed.
  final String change;
  final int uses;
}

final class BranchReview {
  const BranchReview(this.branch, this.base, this.files, this.objects, this.newProblems, this.warnings);

  final String branch;
  final String base;
  final List<GitChange> files;
  final List<ChangedObject> objects;
  final List<Problem> newProblems;
  final List<(GitChange, String)> warnings;
}

Future<BranchReview?> reviewBranch(ProjectIndex index) async {
  final b = branchChanges(index.root);
  if (b == null) return null;
  final sql = [
    for (final c in b.changes)
      if (c.path.toLowerCase().endsWith('.sql')) c,
  ];
  // An object changed when the text of its defining statement differs from main (whitespace aside); added when its
  // file had no such definition in main.
  String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
  final objects = <ChangedObject>[];
  for (final c in sql.where((c) => c.status != 'D')) {
    final file = index.files[c.path];
    if (file == null) continue;
    final mainText = c.status == 'A' ? null : textAt(index.root, b.base, c.from ?? c.path);
    final mainFile = mainText == null ? null : analyzeFile(c.path, mainText);
    for (final d in file.definitions) {
      final o = index.objects[d.key];
      if (o == null || objects.any((x) => x.object.key == o.key)) continue;
      final now = norm(file.text.substring(d.statementSpan.start, d.statementSpan.end));
      final before = [
        for (final m in mainFile?.definitions ?? const <Definition>[])
          if (m.key == d.key) norm(mainText!.substring(m.statementSpan.start, m.statementSpan.end)),
      ];
      if (before.contains(now)) continue;
      objects.add(ChangedObject(o, before.isEmpty ? 'added' : 'changed', index.referencesTo(o.key).length));
    }
  }
  // Deployed changesets: in main, not runOnChange - changing or deleting them breaks the next deployment.
  final warnings = <(GitChange, String)>[];
  for (final c in sql.where((c) => c.status != 'A')) {
    final path = c.from ?? c.path;
    final main = textAt(index.root, b.base, path);
    if (main == null) continue;
    final changesets = RegExp(r'^--changeset\s+\S+(.*)$', multiLine: true).allMatches(main).toList();
    if (changesets.isEmpty || changesets.every((m) => m.group(1)!.contains('runOnChange:true'))) continue;
    final what = switch (c.status) {
      'D' => 'deleted',
      'R' => 'renamed',
      _ => 'changed',
    };
    warnings.add((
      c,
      '$path: a deployed changeset was $what - Liquibase checks its checksum; add a new changeset instead.',
    ));
  }
  // New problems: the same project with the changed files as they are in main.
  final mainTexts = <String, String>{};
  final removed = <String>[];
  for (final c in sql) {
    if (c.status == 'A') {
      removed.add(c.path);
      continue;
    }
    final t = textAt(index.root, b.base, c.from ?? c.path);
    if (t != null) mainTexts[c.from ?? c.path] = t;
    if (c.status == 'R') removed.add(c.path);
  }
  var before = index;
  if (mainTexts.isNotEmpty || removed.isNotEmpty) {
    // Indexer.update re-reads paths missing from texts from disk; removed ones must not exist there.
    final files = Map.of(index.files)..removeWhere((k, _) => removed.contains(k));
    final base = ProjectIndex.link(index.root, files, [
      for (final o in index.order)
        if (!removed.contains(o)) o,
    ]);
    before = await Indexer.update(base, mainTexts.keys, texts: mainTexts);
  }
  String id(Problem x) => '${x.span.file}|${x.message}';
  final old = {for (final x in before.allProblems) id(x)};
  final newProblems = [
    for (final x in index.allProblems)
      if (!old.contains(id(x))) x,
  ];
  return BranchReview(b.branch, b.base, b.changes, objects, newProblems, warnings);
}

/// True when [root] is inside a git repository (the Changes panel is offered then).
bool isGitFolder(String root) =>
    Directory(p.join(root, '.git')).existsSync() ||
    (Process.runSync('git', ['-C', root, 'rev-parse', '--is-inside-work-tree']).stdout as String).trim() == 'true';
