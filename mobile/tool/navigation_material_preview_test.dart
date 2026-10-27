import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/pages/shared/mobile_navigation.dart';
import 'package:orialis_mobile/pages/shared/glass_segmented.dart';

void main() {
  testWidgets('preview navigation material', (tester) async {
    tester.view.physicalSize = const Size(400, 380);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final bytes = await File('/System/Library/Fonts/STHeiti Light.ttc')
          .readAsBytes();
      for (final family in ['sans-serif', 'Ahem']) {
        await (FontLoader(
          family,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
      final icons = await rootBundle.load('fonts/MaterialIcons-Regular.otf');
      await (FontLoader('MaterialIcons')..addFont(Future.value(icons))).load();
    });
    for (final brightness in Brightness.values) {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: LuminaTheme(
            brightness: brightness,
            highPerformanceMode: true,
            data: const LuminaThemeData(
              neumorphic: true,
              neumorphicGlass: true,
            ),
            child: Builder(
              builder: (context) => RepaintBoundary(
                key: key,
                child: ColoredBox(
                  color: LuminaTheme.of(context).colors.paper,
                  child: DefaultTextStyle(
                    style: LuminaTheme.of(context).textTheme.bodyMedium,
                    child: OrialisMobileNavigationOverlay(
                      selectedIndex: 1,
                      onDestinationSelected: (_) {},
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.today_outlined),
                          label: '今日',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.checklist),
                          label: '事件',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.chat_bubble_outline),
                          label: '聊天',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.calendar_month_outlined),
                          label: '日历',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.person_outline),
                          label: '我的',
                        ),
                      ],
                      child: Column(
                        children: [
                          const SizedBox(height: 36),
                          OrialisGlassSegmented(
                            items: const {0: '四象限', 1: '项目'},
                            value: 0,
                            onChanged: (_) {},
                          ),
                          const SizedBox(height: 28),
                          OrialisGlassSegmented(
                            items: const {0: '日', 1: '周', 2: '月'},
                            value: 2,
                            onChanged: (_) {},
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '../../deliveries/navigation-depth-build27-20261027/evidence/preview-${brightness.name}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
