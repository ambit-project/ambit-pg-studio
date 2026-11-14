import 'package:flutter/material.dart';

import 'settings_store.dart';

/// Theme and editor font size (2.0 spec 013), kept in [SettingsStore].
class AppSettings extends ChangeNotifier {
  AppSettings(this.store) {
    final all = store.read();
    themeMode = switch (all[_themeKey]) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    final size = all[_fontKey];
    fontSize = size is num ? size.toDouble().clamp(minFont, maxFont) : defaultFont;
  }

  final SettingsStore store;
  static const _themeKey = 'theme';
  static const _fontKey = 'editorFontSize';
  static const defaultFont = 13.5;
  static const minFont = 9.0;
  static const maxFont = 28.0;

  late ThemeMode themeMode;
  late double fontSize;

  void setThemeMode(ThemeMode mode) {
    if (mode == themeMode) return;
    themeMode = mode;
    store.write(_themeKey, mode.name);
    notifyListeners();
  }

  void setFontSize(double size) {
    final s = (size * 2).round() / 2; // half points
    final clamped = s.clamp(minFont, maxFont);
    if (clamped == fontSize) return;
    fontSize = clamped;
    store.write(_fontKey, clamped);
    notifyListeners();
  }

  void zoom(int steps) => setFontSize(steps == 0 ? defaultFont : fontSize + steps);
}
