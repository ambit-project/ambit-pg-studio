import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pg_studio/app/workspace.dart';
import 'package:pg_studio/ui/editor_view.dart';

import '../helpers.dart';

const _save = 'changelog/modules/10-sales/procedures/sales_app.order_save.sql';

/// Types [text] the way the platform IME does (TextInputClient.updateEditingStateWithDeltas), so re_editor treats
/// it as user input (programmatic edits never open completion).
Future<void> type(WidgetTester tester, String text) async {
  // re_editor keeps the IME value of the current line; it sends a new one when the line changes (a newline), so the
  // value is tracked here between characters and read again after a newline.
  var old = tester.testTextInput.editingState!['text'] as String;
  var at = tester.testTextInput.editingState!['selectionExtent'] as int;
  for (final ch in text.split('')) {
    final setClient = tester.testTextInput.log.lastWhere((c) => c.method == 'TextInput.setClient');
    final client = (setClient.arguments as List).first as int;
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(
        MethodCall('TextInputClient.updateEditingStateWithDeltas', [
          client,
          {
            'deltas': [
              {
                'oldText': old,
                'deltaText': ch,
                'deltaStart': at,
                'deltaEnd': at,
                'selectionBase': at + 1,
                'selectionExtent': at + 1,
                'selectionAffinity': 'TextAffinity.downstream',
                'selectionIsDirectional': false,
                'composingBase': -1,
                'composingExtent': -1,
              },
            ],
          },
        ]),
      ),
      (_) {},
    );
    await tester.pump();
    if (ch == '\n') {
      old = tester.testTextInput.editingState!['text'] as String;
      at = tester.testTextInput.editingState!['selectionExtent'] as int;
    } else {
      old = old.substring(0, at) + ch + old.substring(at);
      at++;
    }
  }
  await tester.pump(const Duration(milliseconds: 80)); // re_editor waits 50 ms before asking for prompts
  await tester.pump();
}

/// Puts the cursor at the end of a new line after [anchor] and focuses the editor.
Future<EditorTab> editAfter(WidgetTester tester, App app, String anchor) async {
  final tab = await openFile(tester, app, _save, select: 0);
  final view = find.byWidgetPredicate((w) => w is EditorView && w.tab == tab);
  await tester.tap(view); // focus: re_editor opens its text input connection
  await tester.pump();
  final at = tab.text.indexOf(anchor) + anchor.length;
  tab.reveal(at, at);
  await tester.pump();
  return tab;
}

Future<void> finish(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 400));
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
  }
}

void main() {
  testWidgets('typing schema. shows its objects; Enter inserts the selected one', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    final tab = await editAfter(tester, app, 'PERFORM sales_app.order_total(p_id, true);');
    await type(tester, '\n    PERFORM sales_app.order_lis');
    expect(find.byKey(const Key('editor.completion')), findsOneWidget);
    expect(find.text('order_list'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter, platform: 'linux');
    await tester.pump();
    expect(tab.text, contains('PERFORM sales_app.order_list'));
    await finish(tester);
  });

  testWidgets('typing alias. inside a statement shows the columns of the aliased table', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    await editAfter(tester, app, 'SELECT o.* INTO v_order FROM sales.orders AS o WHERE o.id = p_id');
    await type(tester, ' AND o.cu');
    expect(find.byKey(const Key('editor.completion')), findsOneWidget);
    expect(find.text('customer_id'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('inside CALL x( the signature shows with the current parameter', (tester) async {
    final app = await pumpApp(tester, fixture('shop'));
    await editAfter(tester, app, 'CALL sales_app.missing_proc(p_id);');
    await type(tester, '\n    CALL sales_app.order_save(p_id, ');
    final card = find.byKey(const Key('editor.signature'));
    expect(card, findsOneWidget);
    final bold = find.descendant(of: card, matching: find.byType(RichText));
    final spans = <TextSpan>[];
    (tester.widget<RichText>(bold.first).text as TextSpan).visitChildren((s) {
      if (s is TextSpan && s.text != null) spans.add(s);
      return true;
    });
    final active = spans.firstWhere((s) => s.style?.fontWeight == FontWeight.w700);
    expect(active.text, 'p_customer_id uuid');
    await finish(tester);
  });
}
