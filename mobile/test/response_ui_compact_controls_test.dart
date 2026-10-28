import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/domain/response_ui.dart';
import 'package:orialis_mobile/features/chat/presentation/response_ui_view.dart';

ResponseUiDocument document(Map<String, dynamic> block) =>
    ResponseUiDocument.parse(
      jsonEncode({
        'version': 1,
        'fallback': '摘要内容',
        'blocks': [block],
      }),
    )!;

Widget host(ResponseUiDocument document, {ValueChanged<String>? onPrompt}) =>
    MaterialApp(
      home: LuminaTheme(
        child: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 360,
              child: ResponseUiView(
                document: document,
                onPromptSelected: onPrompt,
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('untitled accordion does not repeat a generic expand heading', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        document({
          'type': 'accordion',
          'items': [
            {'label': '关键结论', 'content': '摘要正文'},
          ],
        }),
      ),
    );

    expect(find.text('展开阅读'), findsNothing);
    expect(find.text('关键结论'), findsOneWidget);
  });

  testWidgets(
    'chart instruction stays in semantics without duplicate visible text',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          host(
            document({
              'type': 'plot',
              'kind': 'line',
              'items': [
                {
                  'label': '专注时间',
                  'points': [
                    {'x': 1, 'y': 30},
                    {'x': 2, 'y': 45},
                  ],
                },
              ],
            }),
          ),
        );

        expect(find.text('点击图表查看数值'), findsNothing);
        expect(
          find.byKey(const ValueKey('response-chart-surface')),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel(RegExp('专注时间，点击图表查看数值；也可展开查看数据')),
          findsOneWidget,
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'form reset appears only after editing and actions stay in one row',
    (tester) async {
      await tester.pumpWidget(
        host(
          document({
            'type': 'form',
            'prompt': '请按偏好安排。',
            'items': [
              {
                'id': 'mode',
                'label': '方式',
                'kind': 'select',
                'options': ['复习', '练习'],
                'value': '复习',
              },
            ],
          }),
          onPrompt: (_) {},
        ),
      );

      expect(find.byKey(const ValueKey('form-reset')), findsNothing);
      await tester.tap(find.text('练习'));
      await tester.pump();

      final fill = tester.getRect(find.text('填入输入框'));
      final reset = tester.getRect(find.text('重置表单'));
      expect(find.byKey(const ValueKey('form-reset')), findsOneWidget);
      expect(reset.top, fill.top);
    },
  );

  testWidgets('source open and copy actions stay on the same row', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        document({
          'type': 'sources',
          'items': [
            {
              'label': '参考资料',
              'url': 'https://example.com/article',
              'excerpt': '摘录内容',
            },
          ],
        }),
      ),
    );

    expect(
      tester.getRect(find.text('打开来源')).top,
      tester.getRect(find.text('复制地址')).top,
    );
  });
}
