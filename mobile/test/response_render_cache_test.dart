import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/features/chat/presentation/safe_markdown.dart';
import 'package:orialis_mobile/features/chat/presentation/response_ui_view.dart';

const _response =
    '```orialis-ui\n'
    '{"version":1,"fallback":"可读摘要","blocks":[{"type":"choices",'
    '"items":[{"label":"查看","prompt":"查看安排"}]}]}\n```';

void main() {
  testWidgets(
    'cached documents keep each message action identity and callback',
    (tester) async {
      var dark = false;
      var firstChoice = '';
      var secondChoice = '';
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return LuminaTheme(
                brightness: dark ? Brightness.dark : Brightness.light,
                child: Column(
                  children: [
                    SafeMarkdownView(
                      source: _response,
                      allowResponseUi: true,
                      actionScope: 'account-a:message-one',
                      onPromptSelected: (value) => firstChoice = value,
                    ),
                    SafeMarkdownView(
                      source: _response,
                      allowResponseUi: true,
                      actionScope: 'account-b:message-two',
                      onPromptSelected: (value) => secondChoice = value,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
      final before = tester
          .widgetList<ResponseUiView>(find.byType(ResponseUiView))
          .toList();
      expect(before, hasLength(2));
      expect(identical(before[0].document, before[1].document), isTrue);
      expect(before[0].actionScope, startsWith('account-a:message-one:'));
      expect(before[1].actionScope, startsWith('account-b:message-two:'));
      update(() => dark = true);
      await tester.pumpAndSettle();
      final after = tester
          .widgetList<ResponseUiView>(find.byType(ResponseUiView))
          .toList();
      expect(identical(before[0].document, after[0].document), isTrue);
      await tester.tap(find.text('查看').first);
      expect(firstChoice, '查看安排');
      expect(secondChoice, '');
      await tester.tap(find.text('查看').last);
      expect(secondChoice, '查看安排');
      expect(tester.takeException(), isNull);
    },
  );
}
