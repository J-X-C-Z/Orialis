import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/domain/response_ui.dart';
import 'package:orialis_mobile/features/chat/presentation/response_ui_view.dart';

const _metrics = ResponseUiBlock(
  type: 'metrics',
  items: [
    ResponseUiItem(
      label: 'Completed tasks',
      value: '8 tasks',
      detail: '2 more than last week',
    ),
    ResponseUiItem(
      label: 'Focus time',
      value: '12 hours',
      detail: 'A steady daily rhythm',
    ),
  ],
);

const _tabs = ResponseUiBlock(
  type: 'tabs',
  items: [
    ResponseUiItem(
      label: 'Suggestions',
      content: 'Start with the most important task.',
    ),
    ResponseUiItem(label: 'Schedule', content: 'Leave half an hour to review.'),
    ResponseUiItem(
      label: 'Next week',
      content: 'Make room for a longer project.',
    ),
  ],
);

ResponseUiDocument _document(List<ResponseUiBlock> blocks) =>
    ResponseUiDocument(
      version: 1,
      title: 'Your weekly overview',
      fallback: '8 tasks completed and 12 hours of focus.',
      blocks: blocks,
    );

Widget _host(
  ResponseUiDocument document, {
  double width = 420,
  double scale = 1,
  ValueChanged<String>? onPromptSelected,
}) => MaterialApp(
  home: LuminaTheme(
    child: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: width,
            child: ResponseUiView(
              document: document,
              onPromptSelected: onPromptSelected,
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('metrics share a row when there is room', (tester) async {
    await tester.pumpWidget(_host(_document([_metrics])));
    final first = tester.getTopLeft(find.text('Completed tasks'));
    final second = tester.getTopLeft(find.text('Focus time'));
    expect(second.dy, first.dy);
    expect(second.dx, greaterThan(first.dx));
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.8, 2.0]) {
    testWidgets('240px at ${scale}x stacks metrics and keeps controls usable', (
      tester,
    ) async {
      final prompts = <String>[];
      await tester.pumpWidget(
        _host(
          _document([
            _metrics,
            _tabs,
            const ResponseUiBlock(
              type: 'chart',
              unit: ' hours',
              items: [ResponseUiItem(label: 'Wednesday afternoon', value: -2)],
            ),
            const ResponseUiBlock(
              type: 'checklist',
              items: [
                ResponseUiItem(label: 'Review notes from the previous lesson'),
              ],
            ),
            const ResponseUiBlock(
              type: 'choices',
              items: [
                ResponseUiItem(
                  label: 'Plan tomorrow together',
                  prompt: 'Help me plan tomorrow',
                ),
              ],
            ),
          ]),
          width: 240,
          scale: scale,
          onPromptSelected: prompts.add,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Focus time')).dy,
        greaterThan(tester.getBottomLeft(find.text('Completed tasks')).dy),
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Schedule'));
      await tester.tap(find.text('Schedule'));
      await tester.pumpAndSettle();
      expect(find.text('Leave half an hour to review.'), findsOneWidget);
      expect(prompts, isEmpty);
      await tester.ensureVisible(find.text('Plan tomorrow together'));
      await tester.tap(find.text('Plan tomorrow together'));
      expect(prompts, ['Help me plan tomorrow']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'a replaced document drops a tab selection that no longer exists',
    (tester) async {
      await tester.pumpWidget(_host(_document([_tabs])));
      await tester.tap(find.text('Next week'));
      await tester.pump();
      await tester.pumpWidget(_host(_document([_tabs])));
      expect(find.text('Make room for a longer project.'), findsOneWidget);

      await tester.pumpWidget(
        _host(
          _document([
            ResponseUiBlock(type: 'tabs', items: [_tabs.items.first]),
          ]),
        ),
      );
      expect(find.text('Start with the most important task.'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(_host(_document([_tabs])));
      expect(find.text('Start with the most important task.'), findsOneWidget);
      expect(find.text('Make room for a longer project.'), findsNothing);
      await tester.tap(find.text('Schedule'));
      await tester.pump();
      expect(find.text('Leave half an hour to review.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
