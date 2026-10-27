import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/features/chat/presentation/response_dashboard_blocks.dart';

void main() {
  testWidgets('render native inset progress in both appearances', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final font = File('/System/Library/Fonts/STHeiti Light.ttc');
      if (await font.exists()) {
        for (final family in ['sans-serif', 'Ahem']) {
          await (FontLoader(family)..addFont(
                Future.value(ByteData.sublistView(await font.readAsBytes())),
              ))
              .load();
        }
      }
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
                    child: const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: LuminaPalette(
                          palette: LuminaCardPalette.ocean,
                          child: LuminaSection(
                            title: '任务进度',
                            raised: true,
                            glassTitle: true,
                            child: ResponseDashboardProgress(
                              data: {
                                'style': 'linear',
                                'items': [
                                  {'label': '准备完成', 'value': 100, 'max': 100},
                                  {'label': '正在整理', 'value': 38, 'max': 100},
                                  {'label': '等待开始', 'value': 0, 'max': 100},
                                ],
                              },
                            ),
                          ),
                        ),
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
        final file = File(
          '../../deliveries/ui-polish-20261027/evidence/intelligent-${brightness.name}.png',
        );
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
