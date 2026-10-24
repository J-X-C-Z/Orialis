import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/domain/response_ui.dart';
import 'package:orialis_mobile/features/chat/domain/agent_event_state.dart';
import 'package:orialis_mobile/features/chat/presentation/agent_event_cards.dart';
import 'package:orialis_mobile/features/chat/presentation/response_ui_view.dart';
import 'package:orialis_mobile/features/chat/presentation/safe_markdown.dart';

Map<String, dynamic> _document() => {
  'version': 1,
  'title': '本周学习概览',
  'fallback': '本周完成 8 项，专注 12 小时。可选择查看明日安排。',
  'blocks': [
    {
      'type': 'metrics',
      'items': [
        {'label': '已完成', 'value': '8 项', 'detail': '比上周多 2 项'},
      ],
    },
    {
      'type': 'chart',
      'title': '每日专注',
      'unit': ' 小时',
      'items': [
        {'label': '星期一', 'value': 2},
        {'label': '星期二', 'value': 4},
        {'label': '星期三', 'value': 0},
      ],
    },
    {
      'type': 'tabs',
      'items': [
        {'label': '建议', 'content': '上午优先处理最重要的一件事。'},
        {'label': '安排', 'content': '下午留出半小时复习。'},
      ],
    },
    {
      'type': 'checklist',
      'title': '准备清单',
      'items': [
        {'label': '整理课堂笔记', 'checked': false},
        {'label': '完成今日复习', 'checked': true},
      ],
    },
    {
      'type': 'choices',
      'items': [
        {'label': '查看明日安排', 'prompt': '请查看明日安排'},
        {'label': '调整学习计划', 'prompt': '帮我调整学习计划'},
      ],
    },
  ],
};

String _fence(Map<String, dynamic> value) =>
    '```orialis-ui\n${jsonEncode(value)}\n```';

Widget _host(
  Widget child, {
  double width = 320,
  double scale = 1,
  String fontFamily = 'sans-serif',
}) => MaterialApp(
  theme: ThemeData(fontFamily: fontFamily),
  home: LuminaTheme(
    highPerformanceMode: true,
    data: LuminaThemeData(fontFamily: fontFamily),
    child: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  ),
);

void main() {
  test('plain text actions replace only valid response fences and preserve surrounding source', () {
    final source =
        '## Heading\r\n\r\n${_fence(_document())}\r\n  text **bold**\r\n';
    expect(
      responseUiPlainText(source),
      '## Heading\r\n\r\n${_document()['fallback']}\r\n  text **bold**\r\n',
    );
    for (final raw in [
      '```orialis-ui\n{broken}\n```',
      '```orialis-ui\n{"version":1}',
      '```json\n${jsonEncode(_document())}\n```',
      '```text\n${_fence(_document())}\n```',
    ]) {
      expect(responseUiPlainText(raw), raw);
    }
    expect(
      responseUiPlainText('${_fence(_document())}\n${_fence(_document())}'),
      '${_document()['fallback']}\n${_document()['fallback']}',
    );
  });
  test('parses all native blocks without interpreting embedded markup', () {
    final data = _document();
    data['blocks'][2]['items'][0]['content'] = '<script>alert(1)</script>';
    final document = ResponseUiDocument.parse(jsonEncode(data))!;
    expect(document.supported, isTrue);
    expect(document.blocks.map((block) => block.type), [
      'metrics',
      'chart',
      'tabs',
      'checklist',
      'choices',
    ]);
    expect(document.blocks[2].items.first.content, '<script>alert(1)</script>');
  });

  test(
    'rejects malformed, oversized, unknown and incorrectly typed documents',
    () {
      final invalid = <Object?>[
        null,
        [],
        {},
        {'version': 1, 'fallback': ''},
        {..._document(), 'version': 1.0},
        {..._document(), 'blocks': []},
        {..._document(), 'blocks': List.filled(13, _document()['blocks'][0])},
        {..._document(), 'title': 'x' * 81},
        {..._document(), 'fallback': 'x' * 4001},
      ];
      for (final type in [
        'metrics',
        'chart',
        'tabs',
        'checklist',
        'choices',
        'html',
      ]) {
        invalid.add({
          ..._document(),
          'blocks': [
            {
              'type': type,
              'items': [
                {
                  'label': 'bad',
                  'value': null,
                  'checked': 'true',
                  'content': [],
                  'prompt': '',
                },
              ],
            },
          ],
        });
        invalid.add({
          ..._document(),
          'blocks': [
            {
              'type': type,
              'items': List.filled(13, {'label': 'bad'}),
            },
          ],
        });
      }
      for (final data in invalid) {
        expect(
          ResponseUiDocument.parse(jsonEncode(data)),
          isNull,
          reason: '$data',
        );
      }
      expect(ResponseUiDocument.parse('{'), isNull);
      expect(
        ResponseUiDocument.parse(
          jsonEncode({..._document(), 'extra': '中' * 12000}),
        ),
        isNull,
      );
      expect(
        ResponseUiDocument.parse(
          '{"version":1,"fallback":"a","blocks":[{"type":"chart","items":[{"label":"bad","value":1e999}]}]}',
        ),
        isNull,
      );
    },
  );

  test(
    'enforces item limits while accepting zero and negative finite charts',
    () {
      final fields = <String, (String, Object?)>{
        'metrics': ('value', 'x' * 121),
        'tabs': ('content', 'x' * 4001),
        'choices': ('prompt', 'x' * 1001),
      };
      for (final entry in fields.entries) {
        final (field, value) = entry.value;
        expect(
          ResponseUiDocument.parse(
            jsonEncode({
              ..._document(),
              'blocks': [
                {
                  'type': entry.key,
                  'items': [
                    {'label': 'ok', field: value},
                  ],
                },
              ],
            }),
          ),
          isNull,
        );
      }
      for (final value in [0, -4, 1e308]) {
        expect(
          ResponseUiDocument.parse(
            jsonEncode({
              ..._document(),
              'blocks': [
                {
                  'type': 'chart',
                  'items': [
                    {'label': 'ok', 'value': value},
                  ],
                },
              ],
            }),
          ),
          isNotNull,
        );
      }
    },
  );

  testWidgets('response UI is opt-in and only exact language is intercepted', (
    tester,
  ) async {
    final source = _fence(_document());
    for (final language in ['json', 'orialis-ui-extra', 'ORIALIS-UI']) {
      await tester.pumpWidget(
        _host(
          SafeMarkdownView(
            source: source.replaceFirst('orialis-ui', language),
            allowResponseUi: true,
          ),
        ),
      );
      expect(find.byType(ResponseUiView), findsNothing);
    }
    await tester.pumpWidget(_host(SafeMarkdownView(source: source)));
    expect(find.byType(ResponseUiView), findsNothing);
    await tester.pumpWidget(
      _host(
        SafeMarkdownView(
          source: 'Before\n\n$source\n\nAfter',
          allowResponseUi: true,
        ),
      ),
    );
    expect(find.byType(ResponseUiView), findsOneWidget);
    expect(find.text('Before', findRichText: true), findsOneWidget);
    expect(find.text('After', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'partial streaming fences hide JSON and controls until exact closure',
    (tester) async {
      final full = _fence(_document());
      for (final tail in ['', '\n``', '\n```not-a-close']) {
        await tester.pumpWidget(
          _host(
            SafeMarkdownView(
              source: '${full.substring(0, full.length - 4)}$tail',
              allowResponseUi: true,
            ),
          ),
        );
        expect(find.text('正在生成交互内容…'), findsOneWidget);
        expect(find.byType(ResponseUiView), findsNothing);
        expect(find.byType(LuminaButton), findsNothing);
        expect(find.byType(LuminaSelectableText), findsNothing);
      }
      await tester.pumpWidget(
        _host(SafeMarkdownView(source: full, allowResponseUi: true)),
      );
      expect(find.byType(ResponseUiView), findsOneWidget);
    },
  );

  testWidgets(
    'invalid closed blocks show selectable code and future versions show fallback',
    (tester) async {
      const bad = '<script>fetch("https://evil.test")</script>';
      await tester.pumpWidget(
        _host(
          const SafeMarkdownView(
            source: '```orialis-ui\n$bad\n```',
            allowResponseUi: true,
          ),
        ),
      );
      expect(find.text(bad), findsOneWidget);
      expect(find.byType(LuminaSelectableText), findsOneWidget);
      await tester.pumpWidget(
        _host(
          SafeMarkdownView(
            source: _fence({
              ..._document(),
              'version': 2,
              'blocks': [
                {'type': 'future'},
              ],
            }),
            allowResponseUi: true,
          ),
        ),
      );
      expect(find.text(_document()['fallback']), findsOneWidget);
      expect(find.byType(LuminaButton), findsNothing);
    },
  );

  testWidgets(
    'tabs and checklist survive parent rebuild; choices only invoke callback',
    (tester) async {
      final prompts = <String>[];
      final source = _fence(_document());
      Widget view() => _host(
        SafeMarkdownView(
          source: source,
          allowResponseUi: true,
          onPromptSelected: prompts.add,
        ),
      );
      await tester.pumpWidget(view());
      await tester.tap(find.text('安排'));
      await tester.pump();
      await tester.ensureVisible(find.byType(LuminaCheck).first);
      await tester.tap(find.byType(LuminaCheck).first);
      await tester.pump();
      await tester.pumpWidget(view());
      expect(find.text('下午留出半小时复习。'), findsOneWidget);
      expect(
        tester.widget<LuminaCheck>(find.byType(LuminaCheck).first).value,
        isTrue,
      );
      expect(prompts, isEmpty);
      await tester.ensureVisible(find.text('查看明日安排'));
      await tester.tap(find.text('查看明日安排'));
      expect(prompts, ['请查看明日安排']);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets('all native blocks fit 240px at ${scale}x text', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SafeMarkdownView(source: _fence(_document()), allowResponseUi: true),
          width: 240,
          scale: scale,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final choices = tester
          .widgetList<LuminaButton>(find.byType(LuminaButton))
          .toList();
      expect(choices.last.onPressed, isNull);
      final chartFill = find.descendant(
        of: find.byType(FractionallySizedBox).first,
        matching: find.byType(ColoredBox),
      );
      expect(tester.getSize(chartFill).height, 8);
      expect(tester.getSize(chartFill).width, greaterThan(0));
    });
  }

  testWidgets('capture representative native response preview', (tester) async {
    const fontFamily = 'ResponseUiPreview';
    final fontPath = Platform.isWindows ? 'C:/Windows/Fonts/msyh.ttc' : null;
    if (fontPath != null && File(fontPath).existsSync()) {
      await tester.runAsync(() async {
        final loader = FontLoader(fontFamily)
          ..addFont(
            Future.value(
              ByteData.sublistView(await File(fontPath).readAsBytes()),
            ),
          );
        await loader.load();
      });
    }
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final key = GlobalKey();
    final store = AgentEventStore()
      ..agentStatus = 'completed'
      ..agentStatusDetail = '已核对本周记录，并整理出学习建议。';
    addTearDown(store.dispose);
    store.tools['records'] = const ToolTimelineItem(
      id: 'records',
      name: '读取学习记录',
      status: 'completed',
      detail: '已读取本周记录',
    );
    store.streams['preview'] = AgentStream(id: 'preview')
      ..markComplete(
        content: '这是本周的学习概览，可以切换建议或继续调整。\n\n${_fence(_document())}',
      );
    await tester.pumpWidget(
      _host(
        RepaintBoundary(
          key: key,
          child: Builder(
            builder: (context) => ColoredBox(
              color: LuminaTheme.of(context).colors.paper,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: AgentEventsPanel(
                  store: store,
                  onAction: (_, _, _) async {},
                  onRefresh: () async {},
                  onPromptSelected: (_) {},
                ),
              ),
            ),
          ),
        ),
        width: 420,
        fontFamily: fontPath == null ? 'sans-serif' : fontFamily,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('工具活动 · 1'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final output = File(
        '../../../outputs/intelligent-ui-20261023/mobile-preview.png',
      );
      await output.parent.create(recursive: true);
      await output.writeAsBytes(bytes!.buffer.asUint8List());
    });
  });
}
