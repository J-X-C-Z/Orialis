import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/presentation/safe_markdown.dart';

Widget _host(Widget child) => MaterialApp(
  home: LuminaTheme(
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);
Map<String, dynamic> _document() => {
  'version': 1,
  'fallback': '学习安排',
  'blocks': [
    {
      'type': 'agenda',
      'items': [
        {
          'id': 'study',
          'label': '学习安排',
          'title': '复习',
          'startAt': '2026-10-26T09:00:00+08:00',
          'endAt': '2026-10-26T10:00:00+08:00',
        },
      ],
    },
  ],
};
void main() {
  testWidgets('unpersisted and streaming agenda cannot write or send prompts', (
    tester,
  ) async {
    final prompts = <String>[];
    final source = '```orialis-ui\n${jsonEncode(_document())}\n```';
    for (final scope in [null, 'persisted']) {
      await tester.pumpWidget(
        _host(
          SafeMarkdownView(
            source: source,
            allowResponseUi: true,
            actionScope: scope,
            onPromptSelected: scope == null ? prompts.add : null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('待确认'), findsOneWidget);
      expect(
        tester
            .widget<LuminaButton>(find.widgetWithText(LuminaButton, '确认添加日程'))
            .onPressed,
        isNull,
      );
    }
    expect(prompts, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
