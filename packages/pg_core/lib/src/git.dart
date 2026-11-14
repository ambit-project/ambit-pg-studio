import 'dart:io';

import 'package:path/path.dart' as p;

/// Whether files are already in the main branch (deployed changesets must not be reformatted, ADR 0004). Used by
/// the app and the CLI.
abstract final class Git {
  /// True when [path] (relative to [root]) exists in `main` (or `master`) of the repository holding [root]. Without
  /// git or outside a repository: true - unknown is treated as deployed, the safe side.
  static bool inMainBranch(String root, String path) {
    try {
      final prefix = Process.runSync('git', ['-C', root, 'rev-parse', '--show-prefix']);
      if (prefix.exitCode != 0) return true;
      final inRepo = p.posix.join((prefix.stdout as String).trim(), path);
      for (final branch in ['main', 'master']) {
        final has = Process.runSync('git', ['-C', root, 'rev-parse', '--verify', '--quiet', branch]);
        if (has.exitCode != 0) continue;
        return Process.runSync('git', ['-C', root, 'cat-file', '-e', '$branch:$inRepo']).exitCode == 0;
      }
      return true;
    } on Object {
      return true;
    }
  }

  /// Paths (relative to [root]) of the files in `main` (or `master`) under [root], with one `git ls-tree`; null without
  /// git or outside a repository (then every file counts as deployed).
  static Set<String>? filesInMain(String root) {
    try {
      final prefix = Process.runSync('git', ['-C', root, 'rev-parse', '--show-prefix']);
      if (prefix.exitCode != 0) return null;
      final pre = (prefix.stdout as String).trim();
      for (final branch in ['main', 'master']) {
        final has = Process.runSync('git', ['-C', root, 'rev-parse', '--verify', '--quiet', branch]);
        if (has.exitCode != 0) continue;
        final list = Process.runSync('git', [
          '-C',
          root,
          'ls-tree',
          '-r',
          '--name-only',
          '--full-name',
          branch,
          '--',
          '.',
        ]);
        if (list.exitCode != 0) return null;
        return {
          for (final line in (list.stdout as String).split('\n'))
            if (line.startsWith(pre) && line.length > pre.length) line.substring(pre.length),
        };
      }
      return null;
    } on Object {
      return null;
    }
  }
}

/// A file changed on the branch: status A (added), M (modified), D (deleted), R (renamed; [from] the old path).
final class GitChange {
  const GitChange(this.status, this.path, [this.from]);

  final String status;

  /// Relative to the opened folder.
  final String path;
  final String? from;
}

/// The branch against main (or master): what changed since they diverged, the working tree and untracked files
/// included. [branch] is the current branch name; null without git, a repository or a main branch.
({String branch, String base, List<GitChange> changes})? branchChanges(String root) {
  ProcessResult git(List<String> args) => Process.runSync('git', ['-C', root, ...args]);
  try {
    final prefixRun = git(['rev-parse', '--show-prefix']);
    if (prefixRun.exitCode != 0) return null;
    final prefix = (prefixRun.stdout as String).trim();
    String? base;
    for (final b in ['main', 'master']) {
      if (git(['rev-parse', '--verify', '--quiet', b]).exitCode == 0) {
        base = b;
        break;
      }
    }
    if (base == null) return null;
    final mergeBase = (git(['merge-base', base, 'HEAD']).stdout as String).trim();
    final branch = (git(['rev-parse', '--abbrev-ref', 'HEAD']).stdout as String).trim();
    String rel(String repoPath) => repoPath.startsWith(prefix) ? repoPath.substring(prefix.length) : repoPath;
    final changes = <GitChange>[];
    final diff = git(['diff', '--name-status', '-M', mergeBase, '--', '.']);
    for (final line in (diff.stdout as String).split('\n')) {
      if (line.trim().isEmpty) continue;
      final parts = line.split('\t');
      final status = parts[0].substring(0, 1);
      if (status == 'R' && parts.length >= 3) {
        changes.add(GitChange('R', rel(parts[2]), rel(parts[1])));
      } else {
        changes.add(GitChange(status, rel(parts[1])));
      }
    }
    final untracked = git(['ls-files', '--others', '--exclude-standard', '--full-name', '--', '.']);
    for (final line in (untracked.stdout as String).split('\n')) {
      if (line.trim().isNotEmpty) changes.add(GitChange('A', rel(line.trim())));
    }
    return (branch: branch, base: base, changes: changes);
  } on Object {
    return null;
  }
}

/// The text of [path] (relative to [root]) in [ref], or null.
String? textAt(String root, String ref, String path) {
  try {
    final prefix = (Process.runSync('git', ['-C', root, 'rev-parse', '--show-prefix']).stdout as String).trim();
    final r = Process.runSync('git', ['-C', root, 'show', '$ref:$prefix$path']);
    return r.exitCode == 0 ? r.stdout as String : null;
  } on Object {
    return null;
  }
}
