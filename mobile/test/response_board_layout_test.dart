import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/domain/response_ui.dart';
import 'package:orialis_mobile/features/chat/presentation/response_ui_view.dart';

ResponseUiDocument _doc() => ResponseUiDocument.parse(
  jsonEncode({
    'version': 1,
    'fallback': '已复习3/5章。阅读说明和练习数据。',
    'blocks': [
      {
        'type': 'progress',
        'items': [
          {'label': '复习', 'value': 3, 'max': 5},
        ],
      },
      {
        'type': 'accordion',
        'items': [
          {'label': '说明', 'content': '按自己的节奏复习。'},
        ],
      },
      {
        'type': 'table',
        'columns': ['科目', '分钟'],
        'items': [
          {
            'label': '数学记录',
            'cells': ['数学', 30],
          },
        ],
      },
    ],
  }),
)!;

void main() {
  for (final (width, scale, split) in [
    (1200.0, 1.0, true),
    (600.0, 1.0, false),
    (1200.0, 2.0, false),
  ]) {
    testWidgets(
      'native cards use wide columns only with readable text at $width/$scale',
      (tester) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: LuminaTheme(
              highPerformanceMode: true,
              child: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 1200),
                  textScaler: TextScaler.linear(scale),
                ),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: ResponseUiView(document: _doc()),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final first = find.byKey(const ValueKey('response-block-slot-0'));
        final second = find.byKey(const ValueKey('response-block-slot-1'));
        final table = find.byKey(const ValueKey('response-block-slot-2'));
        expect(
          tester.getTopLeft(second).dx > tester.getTopLeft(first).dx,
          split,
        );
        expect(
          tester.getSize(table).width,
          split
              ? greaterThan(tester.getSize(first).width)
              : tester.getSize(first).width,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
