import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/domain/response_ui.dart';
import 'package:orialis_mobile/features/chat/presentation/response_ui_view.dart';

ResponseUiDocument _document() => ResponseUiDocument.parse(
  jsonEncode({
    'version': 1,
    'title': '学习概览',
    'fallback': '先复习，再练习。',
    'blocks': [
      {
        'type': 'chart',
        'title': '学习对比',
        'items': [
          {'label': '阅读', 'value': 8},
          {'label': '练习', 'value': -3},
        ],
      },
      {
        'type': 'tabs',
        'items': [
          {'label': '概念', 'content': '概念正文'},
          {'label': '例题', 'content': '例题正文'},
        ],
      },
      {
        'type': 'form',
        'title': '学习计划',
        'items': [
          {'id': 'topic', 'label': '主题', 'kind': 'text', 'required': true},
        ],
      },
      {
        'type': 'checklist',
        'items': [
          {'label': '复习概念', 'checked': false},
        ],
      },
      {
        'type': 'choices',
        'items': [
          {'label': '继续练习', 'prompt': '再给一道练习'},
        ],
      },
      {
        'type': 'progress',
        'items': [
          {'label': '已确认完成', 'value': 3, 'max': 8},
        ],
      },
      {
        'type': 'heatmap',
        'items': [
          {'label': '当天学习', 'value': 2, 'date': '2026-10-25'},
        ],
      },
    ],
  }),
)!;

const _titles = ['学习概览', '学习对比', '分段阅读', '学习计划', '行动清单', '继续探索', '目标进度', '热力图'];

Widget _host({
  bool? enabled,
  Brightness brightness = Brightness.light,
  double scale = 1,
  ValueChanged<String>? onPromptSelected,
  ResponseUiDocument? document,
}) {
  Widget response = ResponseUiView(
    document: document ?? _document(),
    onPromptSelected: onPromptSelected,
  );
  if (enabled != null) {
    response = LuminaGlassTitleScope(enabled: enabled, child: response);
  }
  return MaterialApp(
    home: LuminaTheme(
      brightness: brightness,
      highPerformanceMode: true,
      data: const LuminaThemeData(
        neumorphic: true,
        neumorphicGlass: true,
        motionScale: 0,
      ),
      child: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(width: 360, child: response),
          ),
        ),
      ),
    ),
  );
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  for (final (brightness, scale) in [
    (Brightness.light, 1.0),
    (Brightness.dark, 2.0),
  ]) {
    testWidgets('rich card titles use clear glass at $brightness ${scale}x', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(enabled: true, brightness: brightness, scale: scale),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LuminaCardHeader), findsNWidgets(_titles.length));
      for (final title in _titles) {
        final header = find.byWidgetPredicate(
          (widget) => widget is LuminaCardHeader && widget.title == title,
        );
        final surface = find.descendant(
          of: header,
          matching: find.byKey(const ValueKey('lumina-glass-card-title')),
        );
        expect(surface, findsOneWidget, reason: title);
        expect(
          tester.widget<LuminaSurface>(surface).depth,
          LuminaSurfaceDepth.recessed,
        );
        for (final layer in [LuminaGlassWell, LuminaGlassCoat]) {
          expect(
            find.descendant(of: surface, matching: find.byType(layer)),
            findsOneWidget,
          );
        }
        final label = find.descendant(of: header, matching: find.text(title));
        final bounds = tester.getRect(surface);
        final text = tester.getRect(label);
        expect(bounds.contains(text.topLeft), isTrue);
        expect(bounds.contains(text.bottomRight), isTrue);
        expect(
          find.ancestor(of: label, matching: find.byType(BackdropFilter)),
          findsNothing,
        );
      }
      final copy = find.byKey(const ValueKey('response-copy-summary'));
      expect(copy, findsOneWidget);
      expect(
        find.ancestor(of: copy, matching: find.byType(LuminaGlassCoat)),
        findsNothing,
      );
      expect(
        find.ancestor(
          of: copy,
          matching: find.byKey(const ValueKey('lumina-glass-card-title')),
        ),
        findsNothing,
      );
      for (final body in ['主题', '概念正文', '已确认完成', '活动热力图']) {
        expect(find.text(body), findsOneWidget);
        expect(
          find.ancestor(
            of: find.text(body),
            matching: find.byType(LuminaCardHeader),
          ),
          findsNothing,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final enabled in [true, false]) {
    testWidgets('chart tabs form checklist choices and copy work: $enabled', (
      tester,
    ) async {
      final prompts = <String>[];
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = call.arguments['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        _host(enabled: enabled, onPromptSelected: prompts.add),
      );
      await tester.pumpAndSettle();
      expect(find.text('阅读  8'), findsOneWidget);
      expect(find.text('练习  -3'), findsOneWidget);
      expect(
        tester
            .widgetList<FractionallySizedBox>(
              find.descendant(
                of: find.byKey(const ValueKey('response-block-0')),
                matching: find.byType(FractionallySizedBox),
              ),
            )
            .map((widget) => widget.widthFactor),
        [1.0, 3 / 8],
      );
      await _tap(tester, find.text('例题'));
      expect(find.text('例题正文'), findsOneWidget);
      expect(find.text('概念正文'), findsNothing);
      final editor = find.descendant(
        of: find.byKey(const ValueKey('field-topic')),
        matching: find.byType(EditableText),
      );
      await tester.ensureVisible(editor);
      await tester.enterText(editor, '傅里叶级数');
      await _tap(tester, find.text('填入输入框'));
      expect(prompts.single, contains('主题：傅里叶级数'));
      await _tap(tester, find.byKey(const ValueKey('form-reset')));
      expect(tester.widget<EditableText>(editor).controller.text, isEmpty);
      await _tap(tester, find.text('复习概念'));
      expect(find.text('已完成 1 / 1'), findsOneWidget);
      await _tap(tester, find.text('继续练习'));
      expect(prompts.last, '再给一道练习');
      await _tap(tester, find.byKey(const ValueKey('response-copy-summary')));
      expect(copied, '学习概览\n\n先复习，再练习。');
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('false scope preserves default widget tree styles and layout', (
    tester,
  ) async {
    final document = _document();
    final shapes = <List<String>>[];
    final bounds = <List<Rect>>[];
    final styles = <List<TextStyle?>>[];
    for (final enabled in <bool?>[null, false]) {
      await tester.pumpWidget(_host(enabled: enabled, document: document));
      await tester.pumpAndSettle();
      expect(find.byType(LuminaCardHeader), findsNothing);
      expect(
        find.byKey(const ValueKey('lumina-glass-card-title')),
        findsNothing,
      );
      final shape = <String>[];
      void visit(Element element) {
        shape.add(element.widget.runtimeType.toString());
        element.visitChildren(visit);
      }

      visit(tester.element(find.byType(ResponseUiView)));
      shapes.add(shape);
      bounds.add([
        for (final title in _titles) tester.getRect(find.text(title)),
        tester.getRect(find.byKey(const ValueKey('response-copy-summary'))),
        for (var index = 0; index < document.blocks.length; index++)
          tester.getRect(find.byKey(ValueKey('response-block-$index'))),
      ]);
      styles.add([
        for (final title in _titles)
          tester.widget<Text>(find.text(title)).style,
      ]);
      expect(tester.takeException(), isNull);
    }
    expect(shapes.last, shapes.first);
    expect(bounds.last, bounds.first);
    expect(styles.last, styles.first);
  });

  testWidgets('unsupported responses remain plain fallback text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        enabled: true,
        document: const ResponseUiDocument(
          version: 2,
          fallback: '普通回退文本',
          blocks: [],
        ),
      ),
    );
    expect(find.text('普通回退文本'), findsOneWidget);
    expect(find.byType(LuminaCardHeader), findsNothing);
  });
}
