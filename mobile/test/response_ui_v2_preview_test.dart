import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/domain/response_ui.dart';
import 'package:orialis_mobile/features/chat/presentation/response_schedule_editor.dart';
import 'package:orialis_mobile/features/chat/presentation/response_ui_view.dart';

final _document = ResponseUiDocument.parse(
  jsonEncode({
    'version': 1,
    'title': '一周学习计划',
    'fallback': '演示数据，仅用于视觉验收。',
    'blocks': [
      {
        'type': 'callout',
        'title': '本周重点',
        'items': [
          {'label': '稳步推进', 'content': '每天留出一段专注时间，完成后及时记录。', 'tone': 'info'},
        ],
      },
      {
        'type': 'steps',
        'title': '学习步骤',
        'items': [
          {'label': '整理资料', 'detail': '收集本周课堂笔记', 'status': 'done'},
          {'label': '完成练习', 'detail': '按章节逐项复习', 'status': 'current'},
          {'label': '回顾错题', 'detail': '总结需要加强的内容', 'status': 'pending'},
        ],
      },
      {
        'type': 'comparison',
        'title': '复习方式',
        'columns': ['自主复习', '小组讨论'],
        'recommendedIndex': 0,
        'items': [
          {
            'label': '安排',
            'values': ['时间灵活', '需协调时间'],
          },
          {
            'label': '重点',
            'values': ['巩固基础', '交流思路'],
          },
        ],
      },
      {
        'type': 'facts',
        'title': '本周记录',
        'items': [
          {'label': '专注时长', 'value': '3小时45分钟', 'detail': '较上周增加 20 分钟'},
          {'label': '完成练习', 'value': '18 项', 'detail': '覆盖 4 个章节'},
        ],
      },
      {
        'type': 'code',
        'title': '复习计时示例',
        'items': [
          {
            'label': '简单计时器',
            'language': 'dart',
            'source': r'''final minutes = 25;
print('focus $minutes min');''',
          },
        ],
      },
      {
        'type': 'agenda',
        'title': '日程建议',
        'items': [
          {
            'id': 'preview-study-session',
            'label': '专题复习',
            'title': '数学专题复习',
            'startAt': '2026-10-29T09:00:00+08:00',
            'endAt': '2026-10-29T10:30:00+08:00',
            'location': '自习室',
            'notes': '复习函数与几何章节',
          },
        ],
      },
      {
        'type': 'metrics',
        'title': '学习概览',
        'items': [
          {'label': '专注时长', 'value': '3.8', 'detail': '小时'},
          {'label': '完成任务', 'value': '18', 'detail': '项'},
        ],
      },
      {
        'type': 'plot',
        'title': '每日专注时间',
        'kind': 'bar',
        'xLabel': '日期',
        'yLabel': '分钟',
        'items': [
          {
            'label': '专注时间',
            'points': [
              {'x': 1, 'y': 32, 'label': '一'},
              {'x': 2, 'y': 45, 'label': '二'},
              {'x': 3, 'y': 38, 'label': '三'},
              {'x': 4, 'y': 55, 'label': '四'},
            ],
          },
        ],
      },
      {
        'type': 'progress',
        'title': '每周目标',
        'style': 'linear',
        'items': [
          {'label': '专注时间', 'value': 225, 'max': 300, 'detail': '目标 5 小时'},
        ],
      },
      {
        'type': 'choices',
        'title': '继续探索',
        'items': [
          {'label': '制定计划', 'prompt': '帮我安排下周的复习计划'},
          {'label': '分析记录', 'prompt': '分析这周的学习记录'},
        ],
      },
    ],
  }),
)!;

const _schedule = <String, dynamic>{
  'id': 'preview-study-session',
  'label': '专题复习',
  'title': '数学专题复习',
  'kind': 'schedule',
  'startAt': '2026-10-29T09:00:00+08:00',
  'endAt': '2026-10-29T10:30:00+08:00',
  'location': '自习室',
  'notes': '复习函数与几何章节',
};

Future<void> _loadFonts(WidgetTester tester) async {
  final source = File('/System/Library/Fonts/STHeiti Light.ttc');
  final monospace = File('/System/Library/Fonts/Menlo.ttc');
  if (!source.existsSync() || !monospace.existsSync()) return;
  await tester.runAsync(() async {
    for (final name in ['sans-serif', 'Ahem']) {
      final loader = FontLoader(name)
        ..addFont(
          Future.value(ByteData.sublistView(await source.readAsBytes())),
        );
      await loader.load();
    }
    final codeLoader = FontLoader('monospace')
      ..addFont(
        Future.value(ByteData.sublistView(await monospace.readAsBytes())),
      )
      ..addFont(Future.value(ByteData.sublistView(await source.readAsBytes())));
    await codeLoader.load();
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in manifest) {
      if (entry['family'] != 'MaterialIcons') continue;
      final loader = FontLoader('MaterialIcons');
      for (final font in entry['fonts'] as List) {
        loader.addFont(rootBundle.load(font['asset']));
      }
      await loader.load();
    }
  });
}

Future<void> _save(
  WidgetTester tester,
  RenderRepaintBoundary boundary,
  String name,
) async {
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final output = File(
      '../../deliveries/intelligent-ui-v2-20261028/evidence/$name.png',
    );
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

Widget _previewApp({
  required Brightness brightness,
  required bool highPerformance,
  required Widget home,
  double textScale = 1,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  builder: (context, child) => LuminaTheme(
    brightness: brightness,
    highPerformanceMode: highPerformance,
    data: const LuminaThemeData(
      neumorphic: true,
      neumorphicGlass: true,
      fontFamily: 'sans-serif',
      motionScale: 0,
    ),
    child: LuminaMaterialBridge(
      child: Builder(
        builder: (context) => DefaultTextStyle(
          style: LuminaTheme.of(context).textTheme.bodyMedium,
          child: MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
      ),
    ),
  ),
  home: home,
);

Widget _preview({
  required Brightness brightness,
  required bool highPerformance,
  double textScale = 1,
}) => _previewApp(
  brightness: brightness,
  highPerformance: highPerformance,
  textScale: textScale,
  home: Scaffold(
    body: SingleChildScrollView(
      child: RepaintBoundary(
        key: const ValueKey('v2-preview-content'),
        child: Builder(
          builder: (context) => ColoredBox(
            color: LuminaTheme.of(context).colors.paper,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: ResponseUiView(document: _document),
            ),
          ),
        ),
      ),
    ),
  ),
);

void _expectGlassButtons({required bool highPerformance}) {
  final buttons = find.byType(LuminaButton);
  expect(buttons, findsWidgets);
  for (final button in buttons.evaluate()) {
    expect(
      find.descendant(
        of: find.byWidget(button.widget),
        matching: find.byType(LuminaGlassSandwich),
      ),
      findsOneWidget,
      reason: 'Every LuminaButton uses the app embedded-glass material',
    );
  }
  if (highPerformance) {
    expect(find.byType(BackdropFilter), findsNothing);
  }
}

void main() {
  testWidgets('render four mobile and one desktop V2 previews', (tester) async {
    await _loadFonts(tester);
    expect(_document.blocks, hasLength(10));
    for (final brightness in [Brightness.light, Brightness.dark]) {
      for (final highPerformance in [false, true]) {
        const size = Size(400, 900);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        final name =
            'v2-mobile-${brightness.name}-${highPerformance ? 'performance' : 'normal'}';
        await tester.pumpWidget(
          _preview(brightness: brightness, highPerformance: highPerformance),
        );
        await tester.pumpAndSettle();
        _expectGlassButtons(highPerformance: highPerformance);
        expect(tester.takeException(), isNull, reason: name);
        await _save(
          tester,
          tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('v2-preview-content')),
          ),
          name,
        );
      }
    }

    tester.view.physicalSize = const Size(1040, 1600);
    await tester.pumpWidget(
      _preview(brightness: Brightness.light, highPerformance: true),
    );
    await tester.pumpAndSettle();
    _expectGlassButtons(highPerformance: true);
    expect(tester.takeException(), isNull, reason: 'desktop');
    await _save(
      tester,
      tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('v2-preview-content')),
      ),
      'v2-desktop-light-performance',
    );
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });

  testWidgets('320 width and 2x text have no overflow in all four modes', (
    tester,
  ) async {
    await _loadFonts(tester);
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final brightness in [Brightness.light, Brightness.dark]) {
      for (final highPerformance in [false, true]) {
        for (final textScale in [1.0, 2.0]) {
          await tester.pumpWidget(
            _preview(
              brightness: brightness,
              highPerformance: highPerformance,
              textScale: textScale,
            ),
          );
          await tester.pumpAndSettle();
          _expectGlassButtons(highPerformance: highPerformance);
          expect(
            tester.takeException(),
            isNull,
            reason:
                '320 ${brightness.name} highPerformance=$highPerformance textScale=$textScale',
          );
        }
      }
    }
  });

  testWidgets('show actual schedule editor with local preview data', (
    tester,
  ) async {
    await _loadFonts(tester);
    tester.view.physicalSize = const Size(1040, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: _previewApp(
          brightness: Brightness.light,
          highPerformance: true,
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => LuminaButton(
                  onPressed: () => showLuminaDialog<Map<String, dynamic>>(
                    context: context,
                    builder: (_) =>
                        const ResponseScheduleEditor(item: _schedule),
                  ),
                  child: const Text('打开日程编辑预览'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开日程编辑预览'));
    await tester.pumpAndSettle();
    expect(find.byType(ResponseScheduleEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('确认添加'));
    await tester.pumpAndSettle();
    _expectGlassButtons(highPerformance: true);
    expect(tester.takeException(), isNull);
    expect(
      (Offset.zero & tester.view.physicalSize).overlaps(
        tester.getRect(find.text('确认添加')),
      ),
      isTrue,
      reason: 'schedule editor confirmation is visible in the lower preview',
    );
    await _save(
      tester,
      tester.renderObject<RenderRepaintBoundary>(find.byKey(key)),
      'v2-schedule-editor-preview',
    );
  });
}
