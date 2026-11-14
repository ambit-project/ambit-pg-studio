import 'package:flutter/material.dart';

import '../app/commands.dart';
import '../app/help.dart';
import 'theme.dart';

/// F1 / the ? button (3.0 spec 002): topics with the commands of the registry, every shortcut, what each problem
/// means. [problem] opens the description of that problem code.
Future<void> showHelp(BuildContext context, {String? problem}) => showDialog<void>(
  context: context,
  builder: (context) => HelpDialog(problem: problem),
);

const _shortcutsId = 'shortcuts';
const _problemsId = 'problems';

class HelpDialog extends StatefulWidget {
  const HelpDialog({super.key, this.problem});

  final String? problem;

  @override
  State<HelpDialog> createState() => _HelpDialogState();
}

class _HelpDialogState extends State<HelpDialog> {
  late String topic = widget.problem != null && problemHelpOf(widget.problem) != null ? _problemsId : 'start';
  String query = '';
  final _problemKeys = {for (final h in problemHelp) h.code: GlobalKey()};

  @override
  void initState() {
    super.initState();
    final code = widget.problem;
    if (code != null && _problemKeys[code] != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _problemKeys[code]!.currentContext;
        if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 150));
      });
    }
  }

  bool _has(String text) => query.isEmpty || text.toLowerCase().contains(query);

  bool _commandMatches(AppCommand c) =>
      _has(c.title) || _has(c.description) || c.keys.any((k) => _has(shortcutLabel(k)));

  /// Topics shown on the left: with a query, only those that contain it.
  List<(String id, String title)> get _topics => [
    for (final t in helpTopics)
      if (_has(t.title) || _has(t.body) || t.commands.any(_commandMatches)) (t.id, t.title),
    if (appCommands.any((c) => c.keys.isNotEmpty && _commandMatches(c))) (_shortcutsId, 'Keyboard shortcuts'),
    if (problemHelp.any((h) => _has(h.code) || _has(h.title) || _has(h.body))) (_problemsId, 'Problems'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topics = _topics;
    final current = topics.any((t) => t.$1 == topic) ? topic : (topics.isEmpty ? null : topics.first.$1);
    return Dialog(
      key: const Key('help'),
      child: SizedBox(
        width: 1000,
        height: 680,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.help_outline, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Text('Help', style: theme.textTheme.titleLarge),
                  const SizedBox(width: 24),
                  Expanded(
                    child: TextField(
                      key: const Key('help.search'),
                      autofocus: true,
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search, size: 18),
                        hintText: 'Search commands, shortcuts, problems',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => setState(() => query = v.trim().toLowerCase()),
                    ),
                  ),
                  IconButton(
                    key: const Key('help.close'),
                    tooltip: 'Close (Esc)',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 230,
                    child: ListView(
                      children: [
                        for (final (id, title) in topics)
                          ListTile(
                            key: Key('help.topic.$id'),
                            dense: true,
                            selected: id == current,
                            title: Text(title),
                            onTap: () => setState(() => topic = id),
                          ),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: current == null
                        ? Center(child: Text('Nothing about "$query".', key: const Key('help.empty')))
                        : SingleChildScrollView(
                            key: ValueKey('help.page.$current:$query'),
                            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                            child: _page(current),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _page(String id) {
    if (id == _shortcutsId) return _shortcuts();
    if (id == _problemsId) return _problems();
    final t = helpTopics.firstWhere((t) => t.id == id);
    final theme = Theme.of(context);
    final commands = t.commands.where(_commandMatches).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.title, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 10),
        ..._body(t.body),
        if (commands.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Commands', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          for (final c in commands) _command(c),
        ],
      ],
    );
  }

  List<Widget> _body(String body) {
    final theme = Theme.of(context);
    final out = <Widget>[];
    for (final para in body.split('\n\n')) {
      final lines = para.split('\n');
      if (lines.every((l) => l.startsWith('    '))) {
        out.add(_code(lines.map((l) => l.substring(4)).join('\n')));
      } else {
        out.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(para, style: theme.textTheme.bodyMedium?.copyWith(height: 1.45)),
          ),
        );
      }
    }
    return out;
  }

  Widget _code(String text) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: SyntaxColors.of(context).background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.dividerColor),
      ),
      child: SelectableText(
        text,
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: editorFont, fontFamilyFallback: editorFontFallback),
      ),
    );
  }

  Widget _keys(AppCommand c) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final k in c.keys)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: theme.dividerColor),
            ),
            child: Text(shortcutLabel(k), style: theme.textTheme.labelSmall?.copyWith(fontFamily: editorFont)),
          ),
      ],
    );
  }

  Widget _command(AppCommand c) {
    final theme = Theme.of(context);
    return Padding(
      key: Key('help.command.${c.id}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 28, child: c.icon == null ? null : Icon(c.icon, size: 18)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(c.title, style: theme.textTheme.titleSmall),
                    const SizedBox(width: 10),
                    _keys(c),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  c.description,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _shortcuts() {
    final theme = Theme.of(context);
    final rows = appCommands.where((c) => c.keys.isNotEmpty && _commandMatches(c)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Keyboard shortcuts', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'Every shortcut of the app. Right-click shows the same commands with their keys.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        for (final section in CommandSection.values)
          if (rows.any((c) => c.section == section)) ...[
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Text(section.title, style: theme.textTheme.titleSmall),
            ),
            for (final c in rows.where((c) => c.section == section))
              Padding(
                key: Key('help.shortcut.${c.id}'),
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(width: 260, child: _keys(c)),
                    SizedBox(width: 220, child: Text(c.title, style: theme.textTheme.bodyMedium)),
                    Expanded(
                      child: Text(
                        c.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
          ],
      ],
    );
  }

  Widget _problems() {
    final theme = Theme.of(context);
    final list = problemHelp.where((h) => _has(h.code) || _has(h.title) || _has(h.body)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Problems', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'What each problem in the Problems panel means, with an example of a fix. Right-click a problem: '
          'What does this mean?',
          style: theme.textTheme.bodySmall,
        ),
        for (final h in list)
          Container(
            key: _problemKeys[h.code],
            margin: const EdgeInsets.only(top: 14),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: h.code == widget.problem ? theme.colorScheme.primary.withValues(alpha: 0.08) : null,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: h.code == widget.problem ? theme.colorScheme.primary : theme.dividerColor),
            ),
            child: Column(
              key: Key('help.problem.${h.code}'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(h.title, style: theme.textTheme.titleSmall),
                    const SizedBox(width: 8),
                    Text(h.code, style: theme.textTheme.labelSmall?.copyWith(fontFamily: editorFont)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(h.body, style: theme.textTheme.bodyMedium?.copyWith(height: 1.45)),
                if (h.before != null) ...[
                  const SizedBox(height: 8),
                  Text('Before', style: theme.textTheme.labelMedium),
                  _code(h.before!),
                  Text('After', style: theme.textTheme.labelMedium),
                  _code(h.after!),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
