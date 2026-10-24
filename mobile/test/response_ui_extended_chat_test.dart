import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orialis_mobile/features/chat/presentation/response_ui_view.dart';

import 'lumina_chat_flow_test.dart' show openChat, iconAction;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets(
    'extended saved reply restores all blocks and persisted action scope',
    (tester) async {
      final h = await openChat(tester);
      final raw = File('../docs/contracts/response-ui-v1.extended.example.json')
          .readAsStringSync();
      final content = '扩展能力演示\n\n```orialis-ui\n$raw\n```';
      final write = h.repo.applyRemoteMessage({
        'conversationId': h.id,
        'id': 'extended-assistant',
        'role': 'assistant',
        'content': content,
        'createdAt': '2026-10-25T00:00:00Z',
        'version': 1,
      });
      await tester.pumpAndSettle();
      await write;
      await tester.pumpAndSettle();
      final view = tester.widget<ResponseUiView>(find.byType(ResponseUiView));
      expect(view.document.blocks.length, 11);
      expect(view.actionScope, startsWith('extended-assistant:'));
      await tester.enterText(find.byType(EditableText).last, '保留的草稿');
      final attempts = h.realtime.attempts;
      // Invoke the same validated form submission callback without sending a turn.
      view.onPromptSelected!('科目：数学\n可用分钟：45');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).last)
            .controller
            .text,
        '保留的草稿\n科目：数学\n可用分钟：45',
      );
      expect(h.realtime.attempts, attempts);
      expect(
        (await tester.runAsync(() => h.db.select(h.db.tasks).get()))!,
        isEmpty,
      );
      final saved = (await tester.runAsync(
        () => h.db.select(h.db.messages).get(),
      ))!;
      expect(saved.single.content, content);
      await tester.tap(iconAction('返回会话列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('离线会话').first);
      await tester.pumpAndSettle();
      final reopened = tester.widget<ResponseUiView>(
        find.byType(ResponseUiView),
      );
      expect(reopened.document.blocks.length, 11);
      expect(reopened.actionScope, view.actionScope);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
