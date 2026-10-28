import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/presentation/response_table_block.dart';

Map<String, dynamic> _data({int count = 12}) => {
  'columns': ['时间', '变更', '结果'],
  'items': [
    for (var i = 0; i < count; i++)
      {
        'label': ['恢复服务访问', '完成配置核对', '更新同步规则', '修复导出问题', '确认服务状态'][i % 5],
        'cells': [
          '10-27 ${8 + i}:39',
          ['调整网络配置', '核对运行参数', '同步新规则', '修复字段格式', '读取服务状态'][i % 5],
          '已验证（示例）',
        ],
      },
  ],
};
Widget _host(
  Map<String, dynamic> data, {
  double scale = 1,
  Brightness brightness = Brightness.light,
  bool hp = true,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  builder: (context, child) => LuminaTheme(
    brightness: brightness,
    highPerformanceMode: hp,
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
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
      ),
    ),
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: RepaintBoundary(
        key: const ValueKey('preview'),
        child: Builder(
          builder: (context) => ColoredBox(
            color: LuminaTheme.of(context).colors.paper,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '服务器记录',
                    style: LuminaTheme.of(context).textTheme.recessedTitle,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '布局演示 · 以下记录均为示例',
                    style: LuminaTheme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  ResponseTableBlock(data: data),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [240.0, 320.0, 390.0, 800.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('summary and pager fit width=$width scale=$scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(_host(_data(), scale: scale));
        await tester.pumpAndSettle();
        expect(find.text('展开行'), findsNothing);
        expect(find.text('恢复服务访问'), findsOneWidget);
        expect(find.byKey(const ValueKey('table-search')), findsNothing);
        expect(
          find.byType(DataTable),
          width < 680 ? findsNothing : findsOneWidget,
        );
        if (width < 680) {
          expect(find.textContaining('时间：10-27 8:39'), findsOneWidget);
        }
        final previous = find.byKey(const ValueKey('table-previous-page'));
        final next = find.byKey(const ValueKey('table-next-page'));
        expect(
          tester.getCenter(previous).dy,
          closeTo(tester.getCenter(next).dy, 1),
        );
        expect(tester.getRect(previous).left, greaterThanOrEqualTo(0));
        expect(tester.getRect(next).right, lessThanOrEqualTo(width));
        await _tap(tester, next);
        expect(find.text('2 / 3'), findsOneWidget);
        await _tap(tester, next);
        expect(find.text('3 / 3'), findsOneWidget);
        await _tap(tester, previous);
        expect(find.text('2 / 3'), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('table-tools')));
        expect(find.byKey(const ValueKey('table-search')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets(
    'compact tools sort numerically and keep filters when collapsed',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _host({
          'columns': ['项目', '数量'],
          'items': [
            {
              'label': '项目甲',
              'cells': ['甲', 10],
            },
            {
              'label': '项目乙',
              'cells': ['乙', 2],
            },
          ],
        }),
      );
      await _tap(tester, find.byKey(const ValueKey('table-tools')));
      await _tap(tester, find.byKey(const ValueKey('table-sort-column')));
      await _tap(tester, find.text('数量').last);
      expect(
        tester.getTopLeft(find.text('项目乙')).dy,
        lessThan(tester.getTopLeft(find.text('项目甲')).dy),
      );
      await _tap(tester, find.byKey(const ValueKey('table-sort-direction')));
      expect(
        tester.getTopLeft(find.text('项目甲')).dy,
        lessThan(tester.getTopLeft(find.text('项目乙')).dy),
      );
      await tester.enterText(find.byType(EditableText), '项目乙');
      await tester.pumpAndSettle();
      expect(find.text('项目甲'), findsNothing);
      await _tap(tester, find.byKey(const ValueKey('table-tools')));
      expect(find.text('1 / 2 条匹配'), findsOneWidget);
      expect(find.text('项目乙'), findsOneWidget);
      expect(find.byType(EditableText), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('small tables omit pager; old timestamp labels expose content', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final data = _data(count: 5);
    data['items'][0]['label'] = '10-27 8:39';
    data['items'][1]['label'] = '展开行';
    data['items'][1]['cells'] = ['10-27 9:39', 3, 9];
    await tester.pumpWidget(_host(data));
    expect(find.text('调整网络配置'), findsOneWidget);
    expect(find.text('展开行'), findsNothing);
    expect(find.text('时间：10-27 9:39 · 变更：3'), findsOneWidget);
    expect(find.byKey(const ValueKey('table-next-page')), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('table-row-0')));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(LuminaSelectableText), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });
  testWidgets('previews use actual app light dark and performance themes', (
    tester,
  ) async {
    final font = File('/System/Library/Fonts/STHeiti Light.ttc');
    if (font.existsSync()) {
      await tester.runAsync(() async {
        for (final family in ['sans-serif', 'Ahem']) {
          final loader = FontLoader(family)
            ..addFont(
              Future.value(ByteData.sublistView(await font.readAsBytes())),
            );
          await loader.load();
        }
        final manifest = jsonDecode(
          await rootBundle.loadString('FontManifest.json'),
        ) as List;
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
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final brightness in Brightness.values) {
      for (final hp in [true, false]) {
        await tester.pumpWidget(_host(_data(), brightness: brightness, hp: hp));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (Platform.environment['ORIALIS_TABLE_PREVIEW'] == '1') {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('preview')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            image.dispose();
            final file = File(
              '../../deliveries/table-summary-20261028/table-${brightness.name}-${hp ? 'fast' : 'normal'}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(png!.buffer.asUint8List());
          });
        }
      }
    }
  });
}
