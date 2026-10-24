import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/domain/response_ui.dart';
import 'package:orialis_mobile/features/chat/presentation/response_ui_view.dart';
import 'package:orialis_mobile/features/chat/presentation/safe_markdown.dart';

Map<String, dynamic> extended() => jsonDecode(
  File('../docs/contracts/response-ui-v1.extended.example.json')
      .readAsStringSync(),
) as Map<String, dynamic>;

String fence(Map<String, dynamic> data) =>
    '```orialis-ui\n${jsonEncode(data)}\n```';

Widget host(String source, {String? scope, ValueChanged<String>? onPrompt}) =>
    MaterialApp(
      home: LuminaTheme(
        child: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 240,
                child: SafeMarkdownView(
                  source: source,
                  allowResponseUi: true,
                  actionScope: scope,
                  onPromptSelected: onPrompt,
                ),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('capture a rendered native capability overview', (tester) async {
    const font = 'IntelligentUiPreview';
    final fontFile = File('/System/Library/Fonts/STHeiti Light.ttc');
    if (!fontFile.existsSync()) return;
    await tester.runAsync(() async {
      final loader = FontLoader(font)
        ..addFont(
          Future.value(ByteData.sublistView(await fontFile.readAsBytes())),
        );
      await loader.load();
      // Widget tests omit bundled fonts unless loaded explicitly.
      final manifest =
          jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      for (final entry in manifest) {
        final family = entry['family'] as String;
        if (!family.contains('KaTeX') && family != 'MaterialIcons') continue;
        final bundled = FontLoader(family);
        for (final asset in entry['fonts'] as List) {
          bundled.addFont(rootBundle.load(asset['asset'] as String));
        }
        await bundled.load();
      }
    });
    tester.view.physicalSize = const Size(600, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sample = extended();
    sample['blocks'] = [
      sample['blocks'][0],
      sample['blocks'][1],
      sample['blocks'][2],
      sample['blocks'][6],
    ];
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: font),
        home: LuminaTheme(
          data: const LuminaThemeData(fontFamily: font),
          child: Scaffold(
            body: SingleChildScrollView(
              child: RepaintBoundary(
                key: boundaryKey,
                child: SizedBox(
                  width: 600,
                  child: ColoredBox(
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: ResponseUiView(
                        document: ResponseUiDocument.parse(jsonEncode(sample))!,
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
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final picture = await boundary.toImage(pixelRatio: 1.5);
      final png = await picture.toByteData(format: ui.ImageByteFormat.png);
      picture.dispose();
      final output = File(
        '../docs/implementation/assets/intelligent-ui-extended-preview.png',
      );
      await output.parent.create(recursive: true);
      await output.writeAsBytes(png!.buffer.asUint8List());
    });
  });
  test(
    'all advertised additions parse without changing opaque stored content',
    () {
      final raw = File('../docs/contracts/response-ui-v1.extended.example.json')
          .readAsStringSync();
      final parsed = ResponseUiDocument.parse(raw)!;
      expect(parsed.blocks.map((b) => b.type), [
        'diagram',
        'math',
        'plot',
        'timeline',
        'simulation',
        'form',
        'table',
        'sources',
        'diff',
        'media',
        'actions',
      ]);
      expect(responseUiPlainText(fence(extended())), parsed.fallback);
      expect(parsed.blocks.first.data['items'][0]['label'], '复习概念');
      expect(parsed.blocks.last.data['items'][1]['kind'], 'schedule');
      expect(
        ResponseUiDocument.parse(jsonEncode({...extended(), 'version': 99}))!
            .supported,
        isFalse,
      );
    },
  );

  test('malformed extended fields never reach native renderers', () {
    final bad = <Map<String, dynamic>>[
      {
        'type': 'diagram',
        'items': [
          {'label': 'bad', 'id': 'a', 'parent': 'missing'},
        ],
      },
      {
        'type': 'math',
        'items': [
          {'label': 'bad', 'source': 42},
        ],
      },
      {
        'type': 'plot',
        'kind': 'line',
        'items': [
          {
            'label': 'bad',
            'points': [
              {'x': '1', 'y': 2},
            ],
          },
        ],
      },
      {
        'type': 'timeline',
        'items': [
          {'label': 'bad', 'time': true},
        ],
      },
      {
        'type': 'simulation',
        'items': [
          {'label': 'bad', 'kind': 'javascript', 'source': 'eval(1)'},
        ],
      },
      {
        'type': 'form',
        'items': [
          {
            'label': 'bad',
            'id': 'x',
            'kind': 'slider',
            'min': 0,
            'max': 1,
            'value': 2,
          },
        ],
      },
      {
        'type': 'table',
        'columns': ['a'],
        'items': [
          {'label': 'bad', 'cells': []},
        ],
      },
      {
        'type': 'sources',
        'items': [
          {'label': 'bad', 'url': 'javascript:alert(1)'},
        ],
      },
      {
        'type': 'diff',
        'items': [
          {'label': 'bad', 'before': false, 'after': 'a'},
        ],
      },
      {
        'type': 'media',
        'items': [
          {'label': 'bad', 'id': '../../secret', 'mimeType': 'text/plain'},
        ],
      },
      {
        'type': 'actions',
        'items': [
          {
            'label': 'bad',
            'id': 'x',
            'kind': 'schedule',
            'title': 'meeting',
            'startAt': '2030-01-01T09:00:00',
            'endAt': '2030-01-01T10:00:00',
          },
        ],
      },
    ];
    for (final block in bad) {
      final source = jsonEncode({
        'version': 1,
        'fallback': 'readable',
        'blocks': [block],
      });
      expect(
        ResponseUiDocument.parse(source),
        isNull,
        reason: block['type'] as String,
      );
    }
    for (final block in extended()['blocks'] as List) {
      for (final items in [
        null,
        [],
        List.filled(13, block['items'][0]),
        [null],
        [
          {'label': 42},
        ],
      ]) {
        expect(
          ResponseUiDocument.parse(
            jsonEncode({
              'version': 1,
              'fallback': 'readable',
              'blocks': [
                {...block, 'items': items},
              ],
            }),
          ),
          isNull,
        );
      }
    }
  });

  testWidgets(
    'every extended type dispatches at 240px and 2x text without side effects',
    (tester) async {
      final prompts = <String>[];
      for (final block in extended()['blocks'] as List) {
        final data = {
          'version': 1,
          'fallback': 'readable',
          'blocks': [block],
        };
        await tester.pumpWidget(host(fence(data), onPrompt: prompts.add));
        await tester.pumpAndSettle();
        expect(
          find.byType(ResponseUiView),
          findsOneWidget,
          reason: block['type'] as String,
        );
        expect(tester.takeException(), isNull, reason: block['type'] as String);
      }
      expect(prompts, isEmpty);
      expect(find.text('预览并创建任务'), findsOneWidget);
      expect(
        tester
            .widget<LuminaButton>(find.widgetWithText(LuminaButton, '预览并创建任务'))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'cached Markdown forwards changed persisted identities and composer callbacks',
    (tester) async {
      final source = fence({
        'version': 1,
        'fallback': 'a',
        'blocks': [
          {
            'type': 'metrics',
            'items': [
              {'label': 'a', 'value': '1'},
            ],
          },
        ],
      });
      final prompts = <String>[];
      await tester.pumpWidget(host(source));
      expect(
        tester.widget<ResponseUiView>(find.byType(ResponseUiView)).actionScope,
        isNull,
      );
      await tester.pumpWidget(
        host(source, scope: 'saved-message-A', onPrompt: prompts.add),
      );
      final first = tester.widget<ResponseUiView>(find.byType(ResponseUiView));
      expect(first.actionScope, startsWith('saved-message-A:'));
      expect(first.actionScope!.split(':').last.length, 64);
      expect(first.onPromptSelected, isNotNull);
      await tester.pumpWidget(
        host(source, scope: 'saved-message-B', onPrompt: prompts.add),
      );
      expect(
        tester.widget<ResponseUiView>(find.byType(ResponseUiView)).actionScope,
        startsWith('saved-message-B:'),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
