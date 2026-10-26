import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/chat/presentation/chat_message_search.dart';

Message _message(String id, String content, {String role = 'assistant'}) =>
    Message(
      conversationId: 'test',
      id: id,
      role: role,
      content: content,
      createdAt: '2026-10-25T08:00:00Z',
      attachmentsJson: '[]',
      syncStatus: 'synced',
      remoteVersion: 1,
    );

void main() {
  testWidgets(
    'search finds saved rich-card fallback and returns exact identity',
    (tester) async {
      final messages = StreamController<List<Message>>();
      addTearDown(messages.close);
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: LuminaTheme(
            child: Scaffold(
              body: ChatMessageSearch(
                messages: messages.stream,
                onSelected: (id) => selected = id,
              ),
            ),
          ),
        ),
      );
      messages.add([
        _message('plain', '普通消息'),
        _message(
          'rich',
          '```orialis-ui\n{"version":1,"fallback":"专注时间 45 分钟","blocks":[{"type":"metrics","items":[{"label":"时间","value":"45"}]}]}\n```',
        ),
        _message('user', '我的专注目标', role: 'user'),
      ]);
      await tester.pump();
      await tester.enterText(find.byType(EditableText), '专注');
      await tester.pump();
      expect(find.text('2 条结果'), findsOneWidget);
      expect(find.text('专注时间 45 分钟'), findsOneWidget);
      expect(find.textContaining('"blocks"'), findsNothing);
      await tester.tap(find.text('专注时间 45 分钟'));
      expect(selected, 'rich');
      await tester.enterText(find.byType(EditableText), '不存在的词');
      await tester.pump();
      expect(find.text('0 条结果'), findsOneWidget);
      expect(find.text('没有匹配的消息，试试其他关键词。'), findsOneWidget);
    },
  );

  testWidgets('search stays readable on narrow large-text screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(240, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: LuminaTheme(
          child: MediaQuery(
            data: const MediaQueryData(
              size: Size(240, 720),
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: ChatMessageSearch(
                messages: Stream.value([_message('m', '查找消息')]),
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(EditableText), '消息');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('1 条结果'), findsOneWidget);
  });
}
