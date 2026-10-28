import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/domain/response_content_schema.dart';
import 'package:orialis_mobile/features/chat/domain/response_ui.dart';
import 'package:orialis_mobile/features/chat/presentation/response_content_blocks.dart';

Map<String, dynamic> _block(String type, List<Map<String, dynamic>> items) => {
  'type': type,
  'items': items,
};

Widget _host(Map<String, dynamic> data, {bool dark = false}) => MaterialApp(
  theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
  home: LuminaTheme(
    highPerformanceMode: true,
    brightness: dark ? Brightness.dark : Brightness.light,
    child: MediaQuery(
      data: const MediaQueryData(
        size: Size(320, 900),
        textScaler: TextScaler.linear(2),
      ),
      child: Scaffold(
        body: SingleChildScrollView(child: ResponseContentBlock(data: data)),
      ),
    ),
  ),
);

void main() {
  final valid = <String, Map<String, dynamic>>{
    'callout': _block('callout', [
      {'label': '提示', 'content': '内容', 'tone': 'warning'},
    ]),
    'steps': _block('steps', [
      {'label': '完成', 'status': 'done', 'detail': '说明'},
    ]),
    'comparison': {
      ..._block('comparison', [
        {
          'label': '价格',
          'values': ['', '免费'],
        },
      ]),
      'columns': ['A', 'B'],
      'recommendedIndex': 1,
    },
    'facts': _block('facts', [
      {'label': '温度', 'value': '20°C', 'detail': '室内'},
    ]),
    'code': _block('code', [
      {'label': '示例', 'source': 'print(1)', 'language': 'l' * 32},
    ]),
  };

  test(
    'all five protocols validate exact bounds and reject malformed data',
    () {
      expect(contentResponseTypes, valid.keys.toSet());
      for (final data in valid.values) {
        expect(validateContentResponseBlock(data), isTrue, reason: '$data');
        expect(
          validateContentResponseBlock({
            ...data,
            'items': List<Map<String, dynamic>>.filled(
              12,
              data['items']!.first as Map<String, dynamic>,
            ),
          }),
          isTrue,
        );
        expect(validateContentResponseBlock({...data, 'items': []}), isFalse);
        expect(
          validateContentResponseBlock({
            ...data,
            'items': List.filled(13, data['items']!.first),
          }),
          isFalse,
        );
        final item = Map<String, dynamic>.from(data['items']!.first as Map);
        expect(
          validateContentResponseBlock({
            ...data,
            'items': [item..['label'] = 'x' * 121],
          }),
          isFalse,
        );
        expect(
          validateContentResponseBlock({
            ...data,
            'items': [item..['label'] = 'x' * 120],
          }),
          isTrue,
        );
      }
      expect(
        validateContentResponseBlock(
          _block('callout', [
            {'label': 'x', 'content': 'ok', 'tone': 'urgent'},
          ]),
        ),
        isFalse,
      );
      expect(
        validateContentResponseBlock(
          _block('callout', [
            {'label': 'x', 'content': 'x' * 4000},
          ]),
        ),
        isTrue,
      );
      expect(
        validateContentResponseBlock(
          _block('callout', [
            {'label': 'x', 'content': 'x' * 4001},
          ]),
        ),
        isFalse,
      );
      expect(
        validateContentResponseBlock(
          _block('steps', [
            {'label': 'x', 'detail': 'x' * 1000, 'status': 'pending'},
          ]),
        ),
        isTrue,
      );
      expect(
        validateContentResponseBlock(
          _block('steps', [
            {'label': 'x', 'status': 'running'},
          ]),
        ),
        isFalse,
      );
      for (final columns in [
        [],
        ['A'],
        ['A', 'B', 'C', 'D', 'E'],
        ['A', 'A'],
        ['A', ''],
      ]) {
        expect(
          validateContentResponseBlock({
            ...valid['comparison']!,
            'columns': columns,
          }),
          isFalse,
        );
      }
      expect(
        validateContentResponseBlock({
          ...valid['comparison']!,
          'recommendedIndex': 2,
        }),
        isFalse,
      );
      expect(
        validateContentResponseBlock({
          ...valid['comparison']!,
          'items': [
            {
              'label': 'x',
              'values': ['a'],
            },
          ],
        }),
        isFalse,
      );
      expect(
        validateContentResponseBlock({
          ...valid['facts']!,
          'items': [
            {'label': 'x', 'value': ''},
          ],
        }),
        isFalse,
      );
      expect(
        validateContentResponseBlock({
          ...valid['facts']!,
          'items': [
            {'label': 'x', 'value': 'x' * 1001},
          ],
        }),
        isFalse,
      );
      expect(
        validateContentResponseBlock({
          ...valid['code']!,
          'items': [
            {'label': 'x', 'source': ''},
          ],
        }),
        isFalse,
      );
      expect(
        validateContentResponseBlock({
          ...valid['code']!,
          'items': [
            {'label': 'x', 'source': 'x' * 16000, 'language': 'l' * 32},
          ],
        }),
        isTrue,
      );
      expect(
        validateContentResponseBlock({
          ...valid['code']!,
          'items': [
            {'label': 'x', 'source': 'x' * 16001},
          ],
        }),
        isFalse,
      );
      expect(
        validateContentResponseBlock({
          ...valid['code']!,
          'items': [
            {'label': 'x', 'source': 'x', 'language': 'l' * 33},
          ],
        }),
        isFalse,
      );
    },
  );

  test(
    'response document routes the five types through content validation',
    () {
      final block = valid['facts']!;
      expect(
        ResponseUiDocument.parse(
          '''{"version":1,"fallback":"text","blocks":[${_json(block)}]}''',
        )?.blocks.single.data,
        block,
      );
      expect(
        ResponseUiDocument.parse(
          '''{"version":1,"fallback":"text","blocks":[{"type":"facts","items":[{"label":"x","value":""}]}]}''',
        ),
        isNull,
      );
    },
  );

  for (final entry in valid.entries) {
    testWidgets(
      '${entry.key} fits 320px at large text in light and dark themes',
      (tester) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        for (final dark in [false, true]) {
          await tester.pumpWidget(_host(entry.value, dark: dark));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byType(BackdropFilter), findsNothing);
          expect(tester.getSize(find.byType(ResponseContentBlock)).width, 320);
        }
      },
    );
  }

  testWidgets('code copies exact source and reports success', (tester) async {
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
    await tester.pumpWidget(_host(valid['code']!));
    await tester.tap(find.text('复制源码'));
    await tester.pump();
    expect(copied, 'print(1)');
    expect(find.text('源码已复制'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}

String _json(Map<String, dynamic> value) => const JsonEncoder().convert(value);
