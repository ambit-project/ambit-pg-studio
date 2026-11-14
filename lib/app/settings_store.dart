import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The user's settings and session in `$XDG_CONFIG_HOME/pg-studio/settings.json` (default `~/.config/...`).
/// A plain JSON file instead of shared_preferences: that plugin pulls JNI (Android) native code into the Linux bundle.
class SettingsStore {
  SettingsStore([String? path]) : path = path ?? defaultPath();

  final String path;

  static String defaultPath() {
    final env = Platform.environment;
    final base = env['XDG_CONFIG_HOME']?.isNotEmpty == true
        ? env['XDG_CONFIG_HOME']!
        : p.join(env['HOME'] ?? Directory.systemTemp.path, '.config');
    return p.join(base, 'pg-studio', 'settings.json');
  }

  /// The whole settings object; empty when the file is missing or unreadable.
  Map<String, Object?> read() {
    try {
      final file = File(path);
      if (!file.existsSync()) return {};
      return (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
    } on Object {
      return {};
    }
  }

  /// Sets [key] to [value] (written atomically: a temp file renamed over the old one).
  void write(String key, Object? value) {
    final all = read()..[key] = value;
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      final tmp = File('$path.tmp');
      tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(all));
      tmp.renameSync(path);
    } on Object {
      // Settings are a convenience; the app works without them.
    }
  }
}
