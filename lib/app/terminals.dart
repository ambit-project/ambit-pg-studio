import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path/path.dart' as p;
import 'package:xterm/xterm.dart';

/// One shell in a pseudo-terminal (3.0 spec 003).
class TerminalSession {
  TerminalSession._(this.pty, this.terminal, this.startDir);

  final Pty pty;
  final Terminal terminal;
  final String startDir;
  int? exitCode;

  bool get exited => exitCode != null;

  int get pid => pty.pid;

  /// The command in the foreground (`bash`, `vim`, `claude`...), from /proc: the tty's foreground process group.
  String get title {
    if (exited) return 'exited ($exitCode)';
    final fg = _foregroundPid();
    return _comm(fg ?? pid) ?? 'shell';
  }

  /// A program other than the shell runs in the foreground (closing the app asks first).
  bool get busy => !exited && (_foregroundPid() ?? pid) != pid;

  /// The current directory of the shell (where relative paths in its output are).
  String get cwd {
    try {
      return Link('/proc/$pid/cwd').resolveSymbolicLinksSync();
    } on Object {
      return startDir;
    }
  }

  int? _foregroundPid() {
    try {
      // /proc/<pid>/stat: "pid (comm) state ppid pgrp session tty_nr tpgid ..."; comm may contain spaces.
      final stat = File('/proc/$pid/stat').readAsStringSync();
      final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
      final tpgid = int.parse(fields[5]);
      return tpgid > 0 ? tpgid : null;
    } on Object {
      return null;
    }
  }

  static String? _comm(int pid) {
    try {
      return File('/proc/$pid/comm').readAsStringSync().trim();
    } on Object {
      return null;
    }
  }

  /// Ends the shell and everything started from it: SIGHUP to its process group (like closing a terminal window),
  /// SIGKILL to what is left after a moment.
  void kill() {
    if (exited) return;
    final group = pid;
    _signalGroup(group, 'HUP');
    pty.kill(ProcessSignal.sighup);
    Timer(const Duration(milliseconds: 400), () => _signalGroup(group, 'KILL'));
  }

  static void _signalGroup(int pgid, String signal) {
    try {
      Process.runSync('kill', ['-$signal', '--', '-$pgid']);
    } on Object {
      // Already gone.
    }
  }
}

/// The terminals of the bottom panel.
class Terminals extends ChangeNotifier {
  final List<TerminalSession> sessions = [];
  int active = -1;

  /// Bumped when a command wants the keyboard in the active terminal (the panel focuses it).
  int focusRequests = 0;

  void requestFocus() {
    focusRequests++;
    notifyListeners();
  }

  TerminalSession? get current => active >= 0 && active < sessions.length ? sessions[active] : null;

  /// The user's shell ($SHELL, else bash).
  static String get shell {
    final s = Platform.environment['SHELL'];
    return s != null && s.isNotEmpty && File(s).existsSync() ? s : 'bash';
  }

  /// A new shell in [dir]; the whole environment of the app is passed on (ssh agent, tokens, PATH).
  TerminalSession open(String dir, {double fontSize = 13.5}) {
    final terminal = Terminal(maxLines: 10000);
    final pty = Pty.start(
      shell,
      workingDirectory: dir,
      environment: {...Platform.environment, 'TERM': 'xterm-256color', 'COLORTERM': 'truecolor'},
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
    );
    final session = TerminalSession._(pty, terminal, dir);
    pty.output.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(terminal.write);
    terminal.onOutput = (data) => pty.write(const Utf8Encoder().convert(data));
    terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);
    unawaited(
      pty.exitCode.then((code) {
        session.exitCode = code;
        terminal.write('\r\n[process exited with code $code]\r\n');
        notifyListeners();
      }),
    );
    sessions.add(session);
    active = sessions.length - 1;
    notifyListeners();
    return session;
  }

  void activate(int i) {
    if (i < 0 || i >= sessions.length) return;
    active = i;
    notifyListeners();
  }

  /// Closes a terminal and ends its processes.
  void close(int i) {
    if (i < 0 || i >= sessions.length) return;
    sessions.removeAt(i).kill();
    if (active >= sessions.length) active = sessions.length - 1;
    notifyListeners();
  }

  /// Sessions where a program runs in the foreground.
  List<TerminalSession> get busy => sessions.where((s) => s.busy).toList();

  void closeAll() {
    for (final s in sessions) {
      s.kill();
    }
    sessions.clear();
    active = -1;
    notifyListeners();
  }

  /// `path`, `path:line` or `path:line:column` in a line of output around column [x], resolved against [cwd] and
  /// made relative to [root]; null when it is not a file under [root].
  static ({String path, int line, int column})? pathAt(String text, int x, String cwd, String root) {
    for (final m in _pathPattern.allMatches(text)) {
      if (x < m.start || x >= m.end) continue;
      final raw = m.group(1)!;
      final abs = p.normalize(p.isAbsolute(raw) ? raw : p.join(cwd, raw));
      if (!p.isWithin(root, abs) || !File(abs).existsSync()) return null;
      return (
        path: p.relative(abs, from: root).replaceAll(r'\', '/'),
        line: int.tryParse(m.group(2) ?? '') ?? 1,
        column: int.tryParse(m.group(3) ?? '') ?? 1,
      );
    }
    return null;
  }

  static final _pathPattern = RegExp(r'((?:[\w.\-]+/|/)*[\w.\-]+\.(?:sql|ya?ml|md|json|sh))(?::(\d+))?(?::(\d+))?');
}
