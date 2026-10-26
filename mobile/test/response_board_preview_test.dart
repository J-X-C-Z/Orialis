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
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lumina_chat_flow_test.dart' show openChat, iconAction;

Future<void> _fonts(WidgetTester tester) async {
  final source = File('/System/Library/Fonts/STHeiti Light.ttc');
  if (!source.existsSync()) return;
  await tester.runAsync(() async {
    for (final name in ['sans-serif', 'Ahem']) {
      final loader = FontLoader(name)
        ..addFont(
          Future.value(ByteData.sublistView(await source.readAsBytes())),
        );
      await loader.load();
    }
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
      '../../deliveries/intelligent-ui-board-20261025/evidence/$name.png',
    );
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets(
    'render actual native Board components in light and dark themes',
    (tester) async {
      await _fonts(tester);
      tester.view.physicalSize = const Size(1040, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final source = jsonDecode(
        File('../docs/contracts/response-ui-v1.board.example.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      final legacy = jsonDecode(
        File('../docs/contracts/response-ui-v1.example.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      final extended = jsonDecode(
        File('../docs/contracts/response-ui-v1.extended.example.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      ResponseUiDocument doc(String title, List<dynamic> blocks) =>
          ResponseUiDocument.parse(
            jsonEncode({
              'version': 1,
              'title': title,
              'fallback': '学习安排与复习记录，演示数据。',
              'blocks': blocks,
            }),
          )!;
      for (final brightness in [Brightness.light, Brightness.dark]) {
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(fontFamily: 'sans-serif'),
            home: LuminaTheme(
              brightness: brightness,
              highPerformanceMode: true,
              data: const LuminaThemeData(
                fontFamily: 'sans-serif',
                motionScale: 0,
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: RepaintBoundary(
                    key: key,
                    child: Builder(
                      builder: (context) => ColoredBox(
                        color: LuminaTheme.of(context).colors.paper,
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Intelligent UI',
                                style: LuminaTheme.of(context)
                                    .textTheme
                                    .titleLarge,
                              ),
                              const SizedBox(height: 6),
                              const Text('学习记录 · 直观比较，按需展开'),
                              const SizedBox(height: 16),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: ResponseUiView(
                                      document: doc('学习概览', [
                                        legacy['blocks'][0],
                                        source['blocks'][3],
                                        source['blocks'][0],
                                      ]),
                                    ),
                                  ),
                                  const SizedBox(width: 20),
                                  Expanded(
                                    child: ResponseUiView(
                                      document: doc('记录与详情', [
                                        source['blocks'][1],
                                        extended['blocks'][6],
                                        source['blocks'][2],
                                        legacy['blocks'][2],
                                      ]),
                                    ),
                                  ),
                                ],
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
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _save(
          tester,
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary,
          'board-${brightness.name}',
        );
      }
    },
  );

  testWidgets(
    'render actual chat and verify suggestions and search preserve the draft',
    (tester) async {
      await _fonts(tester);
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = await openChat(tester);
      await tester.enterText(find.byType(EditableText).first, '保留的草稿');
      await tester.tap(find.text('图表'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).first)
            .controller
            .text,
        contains('保留的草稿'),
      );
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).first)
            .controller
            .text,
        contains('请用图表帮我分析：'),
      );
      expect(
        (await tester.runAsync(() => h.repo.watchMessages(h.id).first))!,
        isEmpty,
      );
      await _save(
        tester,
        tester.renderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary).first,
        ),
        'chat-composer',
      );
      final write = h.repo.applyRemoteMessage({
        'conversationId': h.id,
        'id': 'search-hit',
        'role': 'assistant',
        'content': '本周专注时间为45分钟。',
        'createdAt': '2026-10-25T08:00:00Z',
        'version': 1,
      });
      await tester.pumpAndSettle();
      await write;
      await tester.pumpAndSettle();
      await tester.tap(iconAction('更多会话操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索会话消息'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('chat-message-search-input')),
        '专注',
      );
      await tester.pumpAndSettle();
      expect(find.text('1 条结果'), findsOneWidget);
      await tester.tap(find.text('本周专注时间为45分钟。').last);
      await tester.pumpAndSettle();
      expect(find.text('搜索会话'), findsNothing);
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).first)
            .controller
            .text,
        contains('保留的草稿'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
