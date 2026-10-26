import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/core/attachments/attachment_bridge.dart';
import 'package:orialis_mobile/features/chat/domain/response_ui.dart';
import 'package:orialis_mobile/features/chat/presentation/chat_composer_attachments.dart';
import 'package:orialis_mobile/features/chat/presentation/chat_empty_suggestions.dart';
import 'package:orialis_mobile/features/chat/presentation/response_ui_view.dart';

Widget _host(
  Widget child, {
  double width = 420,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  home: LuminaTheme(
    brightness: brightness,
    highPerformanceMode: true,
    data: const LuminaThemeData(motionScale: 0),
    child: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  ),
);

ResponseUiDocument _document(List<ResponseUiBlock> blocks) =>
    ResponseUiDocument(
      version: 1,
      title: '学习概览',
      fallback: '先复习概念，再完成练习；图表记录实际学习时间。',
      blocks: blocks,
    );

AttachmentRecord _attachment({
  String path = 'https://example.invalid/preview.png',
  String mime = 'image/png',
  int size = 2048,
  AttachmentStatus status = AttachmentStatus.pending,
}) => AttachmentRecord(
  localPath: path,
  name: '课程资料.png',
  mimeType: mime,
  size: size,
  status: status,
);

void main() {
  testWidgets(
    'checklist counts real checks and clears edits for replaced items',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        const checklist = ResponseUiBlock(
          type: 'checklist',
          items: [
            ResponseUiItem(label: '复习概念', checked: true),
            ResponseUiItem(label: '完成练习'),
          ],
        );
        await tester.pumpWidget(
          _host(ResponseUiView(document: _document([checklist]))),
        );
        expect(find.text('已完成 1 / 2'), findsOneWidget);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          .5,
        );
        expect(
          tester
              .getSemantics(find.bySemanticsLabel('清单进度'))
              .getSemanticsData()
              .value,
          '已完成 1 / 2',
        );
        await tester.tap(find.text('完成练习'));
        await tester.pump();
        expect(find.text('已完成 2 / 2'), findsOneWidget);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          1,
        );
        await tester.pumpWidget(
          _host(
            ResponseUiView(
              document: _document([
                const ResponseUiBlock(
                  type: 'checklist',
                  items: [
                    ResponseUiItem(label: '另一课概念'),
                    ResponseUiItem(label: '另一课练习'),
                  ],
                ),
              ]),
            ),
          ),
        );
        expect(find.text('已完成 0 / 2'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'document copy exports the complete declared summary without JSON',
    (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData')
            copied = call.arguments['text'] as String;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final document = _document(const [
        ResponseUiBlock(
          type: 'metrics',
          items: [ResponseUiItem(label: '学习时间', value: '2 小时')],
        ),
      ]);
      await tester.pumpWidget(_host(ResponseUiView(document: document)));
      expect(find.text('关键指标'), findsOneWidget);
      expect(find.text('metrics'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('response-copy-summary')));
      await tester.pump();
      expect(copied, '${document.title}\n\n${document.fallback}');
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    },
  );

  for (final (width, scale, brightness) in [
    (240.0, 2.0, Brightness.dark),
    (420.0, 1.0, Brightness.light),
  ]) {
    testWidgets(
      'board fits ${width}px at ${scale}x with working tabs and drafts',
      (tester) async {
        final prompts = <String>[];
        await tester.pumpWidget(
          _host(
            ResponseUiView(
              document: _document(const [
                ResponseUiBlock(
                  type: 'metrics',
                  items: [
                    ResponseUiItem(
                      label: '复习时间',
                      value: '2 小时',
                      detail: '来自学习记录',
                    ),
                    ResponseUiItem(label: '完成练习', value: '8 题'),
                  ],
                ),
                ResponseUiBlock(
                  type: 'tabs',
                  items: [
                    ResponseUiItem(label: '知识点', content: '先理解概念'),
                    ResponseUiItem(label: '练习安排', content: '再安排练习'),
                  ],
                ),
                ResponseUiBlock(
                  type: 'choices',
                  items: [
                    ResponseUiItem(label: '继续学习这个知识点', prompt: '请详细解释这个知识点'),
                  ],
                ),
              ]),
              onPromptSelected: prompts.add,
            ),
            width: width,
            scale: scale,
            brightness: brightness,
          ),
        );
        final first = tester.getTopLeft(find.text('复习时间'));
        final second = tester.getTopLeft(find.text('完成练习'));
        if (scale == 1) {
          expect(second.dy, first.dy);
        } else {
          expect(second.dy, greaterThan(first.dy));
        }
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('练习安排'));
        await tester.tap(find.text('练习安排'));
        await tester.pumpAndSettle();
        expect(find.text('再安排练习'), findsOneWidget);
        expect(prompts, isEmpty);
        await tester.ensureVisible(find.text('继续学习这个知识点'));
        await tester.tap(find.text('继续学习这个知识点'));
        expect(prompts, ['请详细解释这个知识点']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('choices without a draft callback stay disabled', (tester) async {
    await tester.pumpWidget(
      _host(
        ResponseUiView(
          document: _document(const [
            ResponseUiBlock(
              type: 'choices',
              items: [ResponseUiItem(label: '填写草稿', prompt: '解释概念')],
            ),
          ]),
        ),
      ),
    );
    expect(
      tester
          .widget<LuminaButton>(find.widgetWithText(LuminaButton, '填写草稿'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('empty suggestions only emit the four editable draft prompts', (
    tester,
  ) async {
    final selected = <String>[];
    await tester.pumpWidget(
      _host(ChatEmptySuggestions(onSelect: selected.add), width: 240, scale: 2),
    );
    expect(selected, isEmpty);
    for (final label in ['学习', '图表', '计划', '资料']) {
      final suggestion = find.byKey(ValueKey('chat-suggestion-$label'));
      await tester.ensureVisible(suggestion);
      await tester.tap(suggestion);
    }
    expect(selected, [
      '请帮我理解一个知识点：',
      '请用图表帮我分析：',
      '请帮我制定一个可执行的计划：',
      '请帮我整理这些资料的要点：',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'draft attachments show real metadata and disable removal while busy',
    (tester) async {
      final removed = <int>[];
      final attachments = [_attachment(status: AttachmentStatus.uploading)];
      await tester.pumpWidget(
        _host(
          ChatComposerAttachments(
            attachments: attachments,
            onRemove: removed.add,
            busy: true,
          ),
          width: 240,
          scale: 2,
        ),
      );
      expect(find.text('图片 · 2.0 KB'), findsOneWidget);
      expect(find.text('正在上传'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      final remove = find.byKey(const ValueKey('chat-remove-attachment-0'));
      expect(tester.widget<LuminaIconButton>(remove).onPressed, isNull);
      expect(
        tester.widget<Dismissible>(find.byType(Dismissible)).direction,
        DismissDirection.none,
      );
      await tester.tap(remove);
      expect(removed, isEmpty);
      await tester.pumpWidget(
        _host(
          ChatComposerAttachments(
            attachments: attachments,
            onRemove: removed.add,
          ),
        ),
      );
      await tester.tap(remove);
      expect(removed, [0]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('attachments support horizontal browsing and swipe removal', (
    tester,
  ) async {
    final attachments = [
      _attachment(path: 'first'),
      _attachment(path: 'second'),
    ];
    final removed = <int>[];
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => ChatComposerAttachments(
            attachments: attachments,
            onRemove: (index) => setState(() {
              removed.add(index);
              attachments.removeAt(index);
            }),
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('chat-composer-attachments')),
          )
          .scrollDirection,
      Axis.horizontal,
    );
    await tester.drag(find.byType(Dismissible).first, const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(removed, [0]);
    expect(find.byType(Dismissible), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (mime, size, expected) in [
    ('application/pdf', 0, 'PDF · 0 B'),
    ('audio/mpeg', 1024 * 1024, '音频 · 1.0 MB'),
    ('video/mp4', 1024 * 1024 * 1024, '视频 · 1.0 GB'),
    ('text/plain', -1, '文本 · 大小未知'),
    ('application/zip', 1, '压缩包 · 1 B'),
    ('application/octet-stream', 1, '文件 · 1 B'),
  ]) {
    testWidgets('attachment category and size: $expected', (tester) async {
      await tester.pumpWidget(
        _host(
          ChatComposerAttachments(
            attachments: [_attachment(mime: mime, size: size)],
            onRemove: (_) {},
          ),
        ),
      );
      expect(find.text(expected), findsOneWidget);
      expect(find.byType(FutureBuilder<FileStat>), findsNothing);
      expect(find.byType(Image), findsNothing);
    });
  }

  testWidgets(
    'only safe local raster files are decoded; directories and SVG fall back',
    (tester) async {
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('response-board-'),
      );
      addTearDown(() async {
        await directory!.delete(recursive: true);
      });
      final imageFile = File('${directory!.path}/pixel.png');
      await tester.runAsync(
        () => imageFile.writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=',
          ),
        ),
      );
      Future<void> show(AttachmentRecord attachment) async {
        await tester.pumpWidget(
          _host(
            ChatComposerAttachments(
              attachments: [attachment],
              onRemove: (_) {},
            ),
          ),
        );
        final stat = find.byType(FutureBuilder<FileStat>);
        if (stat.evaluate().isNotEmpty) {
          await tester.runAsync(() => File(attachment.localPath).stat());
          await tester.pump();
        }
      }

      await show(_attachment(path: directory.path));
      expect(find.byType(Image), findsNothing);
      await show(_attachment(path: imageFile.path, mime: 'image/svg+xml'));
      expect(find.byType(Image), findsNothing);
      await show(_attachment(path: imageFile.path));
      for (
        var attempt = 0;
        attempt < 40 && find.byType(Image).evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.byType(Image), findsOneWidget);
      final image = tester.widget<Image>(find.byType(Image));
      await tester.runAsync(() async {
        // Resolve outside fake time so the native codec can finish its IO.
        await image.image.evict();
        final done = Completer<void>();
        final stream = image.image.resolve(ImageConfiguration.empty);
        final listener = ImageStreamListener(
          (_, _) => done.complete(),
          onError: (Object error, StackTrace? stack) =>
              done.completeError(error, stack),
        );
        stream.addListener(listener);
        try {
          await done.future.timeout(const Duration(seconds: 15));
        } finally {
          stream.removeListener(listener);
        }
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty attachment strips take no space', (tester) async {
    await tester.pumpWidget(
      _host(
        ChatComposerAttachments(
          attachments: const [],
          onRemove: (_) => fail('empty strip cannot remove'),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('chat-composer-attachments')),
      findsNothing,
    );
  });
}
