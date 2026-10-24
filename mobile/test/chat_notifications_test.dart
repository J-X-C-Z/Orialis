import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/chat/data/chat_repository.dart';
import 'package:orialis_mobile/features/system_integration/system_integration_controller.dart';

import 'system_integration_test.dart' show FakeConfig;

Future<
  ({
    AppDatabase db,
    SystemIntegrationController controller,
    List<MethodCall> calls,
  })
>
_setup() async {
  SharedPreferences.setMockInitialValues({});
  final db = AppDatabase(executor: AppDatabase.inMemoryExecutor());
  const channel = MethodChannel('test/chat-notifications');
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
  final controller = SystemIntegrationController(
    database: db,
    config: FakeConfig(),
    channel: channel,
    supported: true,
  );
  await controller.start();
  await controller.setEnabled(true);
  calls.clear();
  addTearDown(() async {
    await controller.dispose();
    await db.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  return (db: db, controller: controller, calls: calls);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('only assistant replies reach the native notification bridge', () async {
    final h = await _setup();
    for (final role in ['user', 'system', 'tool', 'unknown', null, 42]) {
      expect(
        await h.controller.notifyChatMessage({
          'id': 'own-message',
          'conversationId': 'chat',
          'role': role,
          'content': '我的发送回执，不应弹窗',
          'title': '别被这个标题绕过',
        }),
        isFalse,
      );
    }
    for (final content in [
      '⏳ Working — 3 min — terminal',
      '💾 Self-improvement review: Memory updated',
    ]) {
      expect(
        await h.controller.notifyChatMessage({
          'id': 'internal',
          'conversationId': 'chat',
          'role': 'assistant',
          'content': content,
        }),
        isFalse,
      );
    }
    expect(
      await h.controller.notifyChatMessage({
        'id': 'background',
        'conversationId': 'memory-123',
        'role': 'assistant',
        'content': '内部处理完成',
      }),
      isFalse,
    );
    expect(
      h.calls.where((call) => call.method == 'notifyChatMessage'),
      isEmpty,
    );
  });

  test(
    'notification summarizes the matching turn instead of a newer question',
    () async {
      final h = await _setup();
      await h.db
          .into(h.db.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: 'chat',
              title: 'Mac 电脑',
              createdAt: '2026-10-24T00:00:00Z',
              updatedAt: '2026-10-24T00:00:00Z',
            ),
          );
      final repo = ChatRepository(database: h.db);
      for (final (id, content, time) in [
        ('question-1', '请帮我优化消息提醒，自己的消息不要弹窗', '00:01:00'),
        ('question-2', '重新设计日历', '00:03:00'),
      ]) {
        await repo.applyRemoteMessage({
          'id': id,
          'conversationId': 'chat',
          'role': 'user',
          'content': content,
          'createdAt': '2026-10-24T${time}Z',
          'version': 1,
        });
      }
      expect(
        await h.controller.notifyChatMessage({
          'id': 'answer-1',
          'conversationId': 'chat',
          'role': 'assistant',
          'title': '新消息',
          'replyToMessageId': 'question-1',
          'createdAt': '2026-10-24T00:04:00Z',
          'content': '**提醒标题**已更新为会话主题。自发消息不再弹窗。其他细节已保存。',
        }),
        isTrue,
      );
      final notice =
          h.calls
                  .singleWhere((call) => call.method == 'notifyChatMessage')
                  .arguments
              as Map;
      expect(notice['title'], '优化消息提醒');
      expect(notice['body'], '提醒标题已更新为会话主题。 自发消息不再弹窗。');
      expect(notice['role'], 'assistant');
      expect(notice['conversationId'], 'chat');
      expect(notice['id'], 'answer-1');
      expect(notice['scope'], isNotEmpty);
      expect(notice.containsKey('token'), isFalse);
      h.calls.clear();
      expect(
        await h.controller.notifyChatMessage({
          'id': 'answer-2',
          'conversationId': 'chat',
          'role': 'assistant',
          'createdAt': '2026-10-24T00:02:00Z',
          'content': '通知已更新。',
        }),
        isTrue,
      );
      final lateNotice =
          h.calls
                  .singleWhere((call) => call.method == 'notifyChatMessage')
                  .arguments
              as Map;
      expect(lateNotice['title'], '优化消息提醒');
    },
  );

  test('manual preview uses an explicit assistant role and summarized presentation', () async {
    final h = await _setup();
    expect(await h.controller.previewChatMessage(), isTrue);
    final notice =
        h.calls
                .singleWhere((call) => call.method == 'testChatMessage')
                .arguments
            as Map;
    expect(notice['role'], 'assistant');
    expect(notice['title'], isNot('新消息'));
    expect(notice['body'], isNotEmpty);
  });
}
