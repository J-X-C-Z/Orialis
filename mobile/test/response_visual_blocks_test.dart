import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/domain/response_visual_schema.dart';
import 'package:orialis_mobile/features/chat/presentation/response_visual_blocks.dart';

Map<String, dynamic> diagram() => {
  'type': 'diagram',
  'layout': 'mindmap',
  'items': [
    {'id': 'root', 'label': '复习', 'detail': '先回顾知识'},
    {'id': 'practice', 'label': '练习', 'parent': 'root', 'detail': '完成三道题'},
  ],
  'edges': [
    {'from': 'root', 'to': 'practice', 'label': '然后'},
  ],
};

Map<String, dynamic> plot(String kind) => {
  'type': 'plot',
  'kind': kind,
  'items': [
    {
      'label': '数学',
      'points': [
        {'x': 0, 'y': 2},
        {'x': 1, 'y': 4},
      ],
    },
    {
      'label': '英语',
      'points': [
        {'x': 0, 'y': 3},
        {'x': 1, 'y': 1},
      ],
    },
  ],
};

Widget host(Map<String, dynamic> data) => MaterialApp(
  home: LuminaTheme(
    child: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2)),
      child: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(width: 240, child: ResponseVisualBlock(data: data)),
        ),
      ),
    ),
  ),
);

void main() {
  test('bounded visual schemas accept all supported shapes', () {
    for (final raw in [
      diagram(),
      plot('line'),
      plot('scatter'),
      plot('pie'),
      {
        'type': 'math',
        'items': [
          {'label': '积分', 'source': r'\int_0^1 x\,dx=\frac12'},
        ],
      },
      {
        'type': 'timeline',
        'items': [
          {
            'label': '开始',
            'time': '2026-10-25T09:00:00+08:00',
            'detail': '复习导数',
          },
        ],
      },
      {
        'type': 'simulation',
        'items': [
          {'label': '傅里叶', 'kind': 'fourier', 'terms': 5},
        ],
      },
    ]) {
      expect(validateVisualResponseBlock(raw), isTrue, reason: '$raw');
    }
  });

  test(
    'rejects dangling/cyclic graph links and malformed simulation/plot input',
    () {
      final invalid = [
        {
          ...diagram(),
          'items': [
            {'id': 'root', 'label': 'A', 'parent': 'missing'},
          ],
        },
        {
          ...diagram(),
          'items': [
            {'id': 'a', 'label': 'A', 'parent': 'b'},
            {'id': 'b', 'label': 'B', 'parent': 'a'},
          ],
        },
        {
          ...diagram(),
          'items': [
            {'id': 'a', 'label': 'A'},
            {'id': 'a', 'label': 'B'},
          ],
        },
        {
          ...diagram(),
          'edges': [
            {'from': 'root', 'to': 'missing'},
          ],
        },
        {
          ...plot('line'),
          'items': [
            {
              'label': 'A',
              'points': [
                {'x': 1, 'y': double.infinity},
              ],
            },
          ],
        },
        {
          ...plot('pie'),
          'items': [
            {
              'label': 'A',
              'points': [
                {'x': 1, 'y': -1},
              ],
            },
          ],
        },
        {
          ...plot('pie'),
          'items': [
            {
              'label': 'A',
              'points': [
                {'x': 1, 'y': 0},
              ],
            },
          ],
        },
        {
          'type': 'math',
          'items': [
            {'label': 'A', 'source': 'x' * 4001},
          ],
        },
        {
          'type': 'timeline',
          'items': [
            {'label': 'A', 'time': 'soon'},
          ],
        },
        {
          'type': 'simulation',
          'items': [
            {'label': 'A', 'kind': 'eval', 'source': 'alert(1)'},
          ],
        },
        {
          'type': 'simulation',
          'items': [
            {'label': 'A', 'kind': 'fourier', 'terms': 26},
          ],
        },
      ];
      for (final raw in invalid) {
        expect(validateVisualResponseBlock(raw), isFalse, reason: '$raw');
      }
    },
  );

  testWidgets(
    'diagram uses native labels and opens node details at narrow large text',
    (tester) async {
      await tester.pumpWidget(host(diagram()));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.ensureVisible(find.widgetWithText(LuminaButton, '练习'));
      await tester.tap(find.widgetWithText(LuminaButton, '练习'));
      await tester.pumpAndSettle();
      expect(find.text('完成三道题'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final kind in ['line', 'scatter', 'pie']) {
    testWidgets('$kind plot lets users choose series and inspect raw data', (
      tester,
    ) async {
      await tester.pumpWidget(host(plot(kind)));
      await tester.pumpAndSettle();
      final label = kind == 'pie' ? '2. 英语' : '英语';
      await tester.tap(find.widgetWithText(LuminaButton, label));
      await tester.pumpAndSettle();
      if (kind == 'pie') {
        expect(find.text('英语: 4.0'), findsOneWidget);
      } else if (kind == 'scatter') {
        final chart = tester.widget<ScatterChart>(find.byType(ScatterChart));
        expect(chart.data.scatterSpots.first.y, 3);
      } else {
        final chart = tester.widget<LineChart>(find.byType(LineChart));
        expect(chart.data.lineBarsData.single.spots.first.y, 3);
      }
      await tester.ensureVisible(find.text('查看数据'));
      await tester.tap(find.text('查看数据'));
      await tester.pumpAndSettle();
      expect(find.text('x=0, y=3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'formula errors retain source and timeline content fits narrow large text',
    (tester) async {
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = call.arguments['text'] as String;
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
        host({
          'type': 'math',
          'items': [
            {'label': '分式', 'source': r'\frac{1}{2}'},
          ],
        }),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Math), findsOneWidget);
      await tester.tap(find.text('复制公式'));
      await tester.pumpAndSettle();
      expect(clipboard, r'\frac{1}{2}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        host({
          'type': 'math',
          'items': [
            {'label': '公式', 'source': r'\unknowncommand'},
          ],
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text(r'\unknowncommand'), findsOneWidget);
      expect(find.text('复制公式'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        host({
          'type': 'timeline',
          'items': [
            {
              'label': '很长的阶段名称也应该自动换行显示',
              'detail': '先复习再练习',
              'time': '2026-10-25',
            },
          ],
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('先复习再练习'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('simulation computation changes with the actual parameter', () {
    final a = responseSimulationPoints(
      kind: 'fourier',
      terms: 1,
      amplitude: 1,
      frequency: 1,
    );
    final b = responseSimulationPoints(
      kind: 'fourier',
      terms: 5,
      amplitude: 1,
      frequency: 1,
    );
    final c = responseSimulationPoints(
      kind: 'sine',
      terms: 1,
      amplitude: 2,
      frequency: 1,
    );
    expect(a.length, 121);
    expect(a[40].y, isNot(closeTo(b[40].y, 0.001)));
    expect(c[30].y, closeTo(-2, 0.001));
  });

  testWidgets(
    'Fourier slider changes plotted samples and reset restores defaults',
    (tester) async {
      await tester.pumpWidget(
        host({
          'type': 'simulation',
          'items': [
            {'label': '傅里叶叠加', 'kind': 'fourier', 'terms': 3},
          ],
        }),
      );
      await tester.pumpAndSettle();
      final before = tester
          .widget<LineChart>(find.byType(LineChart))
          .data
          .lineBarsData
          .single
          .spots[40]
          .y;
      tester
          .widget<LuminaValueSlider>(find.byType(LuminaValueSlider))
          .onChanged!(10);
      await tester.pumpAndSettle();
      final after = tester
          .widget<LineChart>(find.byType(LineChart))
          .data
          .lineBarsData
          .single
          .spots[40]
          .y;
      expect(after, isNot(closeTo(before, 0.001)));
      expect(find.text('项数：10'), findsOneWidget);
      await tester.ensureVisible(find.text('恢复参数'));
      await tester.tap(find.text('恢复参数'));
      await tester.pumpAndSettle();
      expect(find.text('项数：3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
