import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/domain/response_ui.dart';
import 'package:orialis_mobile/features/chat/domain/response_visual_schema.dart';
import 'package:orialis_mobile/features/chat/presentation/response_chart_radar.dart';
import 'package:orialis_mobile/features/chat/presentation/response_ui_view.dart';
import 'package:orialis_mobile/features/chat/presentation/response_visual_blocks.dart';

Map<String, dynamic> _plot(String kind) => {
  'type': 'plot',
  'kind': kind,
  'unit': '件',
  'xLabel': '月',
  'yLabel': '数量',
  'xUnit': '天',
  'items': [
    for (final label in ['A', 'B'])
      {
        'label': label,
        'points': [
          {
            'x': 0,
            'y': kind == 'radar' || kind == 'pie' ? 4 : -4,
            'label': '阅读',
          },
          {'x': 1, 'y': label == 'A' ? 2 : 6, 'label': '练习'},
          {'x': 2, 'y': 8, 'label': '复盘'},
        ],
      },
  ],
};

Map<String, dynamic> _progress({String style = 'linear'}) => {
  'type': 'progress',
  'style': style,
  'items': [
    {'label': '本次已确认的完成数量', 'value': 3, 'max': 8, 'detail': '来自实际结果'},
    {'label': '尚未完成', 'value': 0},
  ],
};

Map<String, dynamic> _heatmap() => {
  'type': 'heatmap',
  'unit': '次',
  'items': [
    {'label': '周日复习与练习', 'value': 7, 'date': '2026-10-25'},
    {'label': '没有记录的活动', 'value': 0, 'date': '2026-10-24'},
  ],
};

ResponseUiDocument? _parse(List<Map<String, dynamic>> blocks) =>
    ResponseUiDocument.parse(
      jsonEncode({'version': 1, 'fallback': '图表文字回退', 'blocks': blocks}),
    );

Widget _host(
  Map<String, dynamic> data, {
  bool document = false,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  theme: ThemeData(brightness: brightness),
  home: LuminaTheme(
    brightness: brightness,
    child: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2)),
      child: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 240,
            child: document
                ? ResponseUiView(document: _parse([data])!)
                : ResponseVisualBlock(data: data),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  test('all six plots preserve version 1 and existing document limits', () {
    for (final kind in ['line', 'scatter', 'pie', 'area', 'bar', 'radar']) {
      expect(_parse([_plot(kind)])?.blocks.single.type, 'plot');
    }
    expect(_parse(List.generate(12, (_) => _progress())), isNotNull);
    expect(_parse(List.generate(13, (_) => _progress())), isNull);
    final tooLarge = _progress();
    tooLarge['ignored'] = '汉' * 11000;
    expect(_parse([tooLarge]), isNull);
  });

  test('new plot metadata and geometry are bounded', () {
    for (final field in ['xLabel', 'yLabel', 'xUnit']) {
      expect(
        validateVisualResponseBlock({..._plot('area'), field: 42}),
        isFalse,
      );
      expect(
        validateVisualResponseBlock({..._plot('area'), field: 'a' * 81}),
        isFalse,
      );
    }
    for (final kind in ['area', 'bar', 'radar']) {
      final raw = _plot(kind);
      raw['items'][0]['points'][1]['x'] = 0;
      expect(
        validateVisualResponseBlock(raw),
        isFalse,
        reason: 'duplicate $kind x',
      );
    }
    final backwards = _plot('area');
    backwards['items'][0]['points'] = (backwards['items'][0]['points'] as List)
        .reversed
        .toList();
    expect(validateVisualResponseBlock(backwards), isFalse);
    final tooMany = _plot('bar');
    tooMany['items'][0]['points'] = List.generate(121, (i) => {'x': i, 'y': 1});
    expect(validateVisualResponseBlock(tooMany), isFalse);
    for (final value in [double.nan, double.infinity, -1000001, '3']) {
      final raw = _plot('area');
      raw['items'][0]['points'][0]['y'] = value;
      expect(validateVisualResponseBlock(raw), isFalse);
    }
  });

  test('radar requires at least three shared axes and nonnegative values', () {
    for (final length in [1, 2, 121]) {
      final raw = _plot('radar');
      for (final item in raw['items']) {
        item['points'] = List.generate(length, (i) => {'x': i, 'y': 1});
      }
      expect(validateVisualResponseBlock(raw), isFalse);
    }
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (raw) => raw['items'][1]['points'].removeLast(),
      (raw) => raw['items'][1]['points'][1]['x'] = 4,
      (raw) => raw['items'][1]['points'][1]['label'] = '不相同的轴',
      (raw) => raw['items'][0]['points'][0]['y'] = -1,
    ]) {
      final raw = _plot('radar');
      mutate(raw);
      expect(validateVisualResponseBlock(raw), isFalse);
    }
  });

  test(
    'progress has explicit finite bounds and does not accept simulated status',
    () {
      expect(_parse([_progress()])?.blocks.single.type, 'progress');
      expect(_parse([_progress(style: 'ring')]), isNotNull);
      expect(_parse([_progress(style: 'automatic')]), isNull);
      for (final item in [
        {'label': 'A', 'value': 101},
        {'label': 'A', 'value': -1},
        {'label': 'A', 'value': double.nan},
        {'label': 'A', 'value': '12'},
        {'label': 'A', 'value': 1, 'max': 0},
        {'label': 'A', 'value': 1, 'max': -10},
        {'label': 'A', 'value': 1, 'max': double.infinity},
        {'label': 'A', 'value': 1, 'max': double.nan},
        {'label': 'A', 'value': 1, 'detail': 'a' * 241},
      ]) {
        expect(
          validateVisualResponseBlock({
            'type': 'progress',
            'items': [item],
          }),
          isFalse,
          reason: '$item',
        );
      }
      expect(
        validateVisualResponseBlock({
          'type': 'progress',
          'items': [
            {'label': 'A', 'value': 100},
          ],
        }),
        isTrue,
      );
      expect(
        validateVisualResponseBlock({
          'type': 'progress',
          'items': [
            {'label': 'A', 'value': 0.125, 'max': 0.5},
          ],
        }),
        isTrue,
      );
    },
  );

  test(
    'heatmap validates real dates, finite nonnegative values and 1..12 cells',
    () {
      expect(_parse([_heatmap()])?.blocks.single.type, 'heatmap');
      for (final date in [
        '2026-02-29',
        '2026-02-30',
        '2026-13-01',
        '2026-1-01',
        '2026-10-25T00:00:00Z',
        '0000-01-01',
      ]) {
        expect(
          validateVisualResponseBlock({
            'type': 'heatmap',
            'items': [
              {'label': 'A', 'value': 1, 'date': date},
            ],
          }),
          isFalse,
          reason: date,
        );
      }
      expect(
        validateVisualResponseBlock({
          'type': 'heatmap',
          'items': [
            {'label': 'A', 'value': 1e6, 'date': '2024-02-29'},
          ],
        }),
        isTrue,
      );
      for (final value in [
        -1,
        1000001,
        double.nan,
        double.infinity,
        '4',
        null,
      ]) {
        expect(
          validateVisualResponseBlock({
            'type': 'heatmap',
            'items': [
              {'label': 'A', 'value': value, 'date': '2026-10-25'},
            ],
          }),
          isFalse,
        );
      }
      for (final type in ['heatmap', 'progress']) {
        expect(
          validateVisualResponseBlock({'type': type, 'items': []}),
          isFalse,
        );
        final raw = type == 'heatmap' ? _heatmap() : _progress();
        raw['items'] = List.generate(
          13,
          (i) => {'label': '$i', 'value': 0, 'date': '2026-10-${i + 10}'},
        );
        expect(validateVisualResponseBlock(raw), isFalse);
      }
      final duplicate = _heatmap();
      duplicate['items'][1]['date'] = duplicate['items'][0]['date'];
      expect(validateVisualResponseBlock(duplicate), isFalse);
    },
  );

  for (final brightness in Brightness.values) {
    for (final kind in ['line', 'scatter', 'pie', 'area', 'bar', 'radar']) {
      testWidgets('$kind switches real series at 240px/2x in $brightness', (
        tester,
      ) async {
        await tester.pumpWidget(_host(_plot(kind), brightness: brightness));
        await tester.pumpAndSettle();
        final button = find.widgetWithText(
          LuminaButton,
          kind == 'pie' ? '2. B' : 'B',
        );
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        if (kind == 'area' || kind == 'line') {
          final data = tester.widget<LineChart>(find.byType(LineChart)).data;
          expect(data.lineBarsData.single.spots[1].y, 6);
          expect(data.lineBarsData.single.belowBarData.show, kind == 'area');
          if (kind == 'area') {
            expect(data.lineBarsData.single.belowBarData.cutOffY, 0);
            expect(data.lineBarsData.single.aboveBarData.show, isTrue);
          }
        } else if (kind == 'bar') {
          final data = tester.widget<BarChart>(find.byType(BarChart)).data;
          expect(data.minY, -4);
          expect(data.maxY, 8);
          expect(data.barGroups.first.barRods.single.toY, -4);
          expect(data.barGroups[1].barRods.single.toY, 6);
        } else if (kind == 'radar') {
          final data = tester.widget<ResponseChartRadar>(
            find.byType(ResponseChartRadar),
          );
          expect(data.maximum, 8);
          expect(data.points[1]['y'], 6);
        } else if (kind == 'scatter') {
          expect(
            tester
                .widget<ScatterChart>(find.byType(ScatterChart))
                .data
                .scatterSpots[1]
                .y,
            6,
          );
        } else {
          expect(find.text('B: 18.0件'), findsOneWidget);
        }
        await tester.ensureVisible(find.text('查看数据'));
        await tester.tap(find.text('查看数据'));
        await tester.pumpAndSettle();
        expect(find.textContaining('练习 · 月=1天, 数量=6件'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('touching an area sample reads its actual signed data', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_plot('area')));
    await tester.pumpAndSettle();
    final surface = find.byKey(const ValueKey('response-chart-surface'));
    await tester.ensureVisible(surface);
    await tester.tapAt(tester.getTopLeft(surface) + const Offset(120, 115));
    await tester.pumpAndSettle();
    expect(find.text('A: 练习 · 月=1天, 数量=2件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'radar touch identifies axis and resets inspection on replacement',
    (tester) async {
      await tester.pumpWidget(_host(_plot('radar')));
      await tester.pumpAndSettle();
      final surface = find.byKey(const ValueKey('response-chart-surface'));
      await tester.ensureVisible(surface);
      await tester.tapAt(tester.getTopLeft(surface) + const Offset(120, 24));
      await tester.pumpAndSettle();
      expect(find.text('A: 阅读 · 月=0天, 数量=4件'), findsOneWidget);
      final replacement = _plot('radar');
      replacement['items'][0]['points'][0]['y'] = 1;
      await tester.pumpWidget(_host(replacement));
      await tester.pumpAndSettle();
      expect(find.text('A: 阅读 · 月=0天, 数量=4件'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final style in ['linear', 'ring']) {
    testWidgets(
      '$style progress dispatches through the unchanged main view and stays determinate',
      (tester) async {
        await tester.pumpWidget(
          _host(
            _progress(style: style),
            document: true,
            brightness: Brightness.dark,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('3 / 8 · 37.5%'), findsOneWidget);
        expect(find.text('来自实际结果'), findsOneWidget);
        if (style == 'linear') {
          expect(
            tester
                .widgetList<LinearProgressIndicator>(
                  find.byType(LinearProgressIndicator),
                )
                .map((w) => w.value),
            [0.375, 0],
          );
        } else {
          expect(
            tester
                .widgetList<CircularProgressIndicator>(
                  find.byType(CircularProgressIndicator),
                )
                .map((w) => w.value),
            [0.375, 0],
          );
        }
        await tester.pump(const Duration(seconds: 30));
        expect(find.text('3 / 8 · 37.5%'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'same heatmap labels on distinct dates select only the tapped item',
    (tester) async {
      final data = {
        'type': 'heatmap',
        'items': [
          {'label': '同名记录', 'date': '2026-10-24', 'value': 3},
          {'label': '同名记录', 'date': '2026-10-25', 'value': 7},
        ],
      };
      expect(validateVisualResponseBlock(data), isTrue);
      await tester.pumpWidget(_host(data, brightness: Brightness.dark));
      await tester.pumpAndSettle();
      for (var index = 0; index < 2; index++) {
        final date = index == 0 ? '2026-10-24' : '2026-10-25';
        final cell = find.byKey(ValueKey('heatmap-$date-$index'));
        await tester.ensureVisible(cell);
        await tester.tap(cell);
        await tester.pumpAndSettle();
        expect(find.text('数值：${index == 0 ? 3 : 7}'), findsOneWidget);
        expect(
          tester
              .widgetList<Semantics>(find.byType(Semantics))
              .where((widget) => widget.properties.selected == true),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      }
      expect(find.text('数值：3'), findsNothing);
    },
  );

  testWidgets('heatmap exposes exact touch detail and clears old selection', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_heatmap(), document: true, brightness: Brightness.dark),
    );
    await tester.pumpAndSettle();
    final cell = find.byKey(const ValueKey('heatmap-2026-10-25-1'));
    await tester.ensureVisible(cell);
    expect(tester.getSize(cell).height, greaterThanOrEqualTo(48));
    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(find.text('2026-10-25'), findsOneWidget);
    expect(find.text('周日复习与练习'), findsOneWidget);
    expect(find.text('数值：7次'), findsOneWidget);
    final replacement = _heatmap();
    replacement['items'][0]['value'] = 0;
    await tester.pumpWidget(
      _host(replacement, document: true, brightness: Brightness.dark),
    );
    await tester.pumpAndSettle();
    expect(find.text('数值：7次'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
