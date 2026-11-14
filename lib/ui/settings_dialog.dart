import 'package:flutter/material.dart';

import '../app/app_settings.dart';

/// Theme and editor font size (2.0 spec 013); changes apply at once and are saved.
Future<void> showSettingsDialog(BuildContext context, AppSettings settings) => showDialog<void>(
  context: context,
  builder: (context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Theme', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            SegmentedButton<ThemeMode>(
              key: const Key('settings.theme'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
                ButtonSegment(
                  value: ThemeMode.light,
                  label: Text('Light', key: Key('settings.theme.light')),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text('Dark', key: Key('settings.theme.dark')),
                ),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (v) => settings.setThemeMode(v.first),
            ),
            const SizedBox(height: 16),
            Text(
              'Editor font size: ${settings.fontSize} (Ctrl+= / Ctrl+- / Ctrl+0)',
              key: const Key('settings.fontLabel'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            Slider(
              key: const Key('settings.font'),
              min: AppSettings.minFont,
              max: AppSettings.maxFont,
              divisions: ((AppSettings.maxFont - AppSettings.minFont) * 2).round(),
              value: settings.fontSize,
              label: '${settings.fontSize}',
              onChanged: settings.setFontSize,
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    ),
  ),
);
