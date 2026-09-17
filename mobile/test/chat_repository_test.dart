import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/chat/data/chat_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sendMessage writes a pending local user message', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = ChatRepository(database: database);

    final message = await repository.sendMessage(
      conversationId: 'conversation-1',
      content: '  hello Orialis  ',
    );

    expect(message.role, 'user');
    expect(message.content, 'hello Orialis');
    expect(message.syncStatus, 'pendingCreate');
    expect(await repository.watchMessages('conversation-1').first, [message]);
  });

  test('conversation lifecycle stays local-first and protects main', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = ChatRepository(database: database);

    final conversation = await repository.createConversation(title: '项目讨论');
    expect(conversation.type, 'normal');
    await repository.renameConversation(conversation, '项目讨论 2');
    final renamed = await (database.select(
      database.conversations,
    )..where((row) => row.id.equals(conversation.id))).getSingle();
    expect(renamed.title, '项目讨论 2');
    expect(renamed.syncStatus, 'pendingCreate');

    await expectLater(
      repository.deleteConversation(
        renamed.copyWith(type: 'main', id: 'default'),
      ),
      throwsStateError,
    );
  });

  test('applyRemoteMessage stores an assistant reply', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = ChatRepository(database: database);

    await repository.applyRemoteMessage({
      'conversationId': 'default',
      'id': 'reply-1',
      'role': 'assistant',
      'content': '收到，我在。',
      'createdAt': '2026-09-16T15:23:11Z',
      'version': 1,
    });

    final messages = await repository.watchMessages('default').first;
    expect(messages.single.role, 'assistant');
    expect(messages.single.content, '收到，我在。');
    expect(messages.single.syncStatus, 'synced');
  });

  test('local messages preserve attachment metadata for sync', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = ChatRepository(database: database);

    final message = await repository.sendMessage(
      conversationId: 'default',
      content: '一张照片',
      attachmentsJson:
          '[{"localPath":"/tmp/photo.jpg","name":"photo.jpg","mimeType":"image/jpeg","size":12}]',
    );

    expect(message.attachmentsJson, contains('photo.jpg'));
    expect(message.syncStatus, 'pendingCreate');
  });

  test(
    'applyRemoteMessage does not overwrite a queued local mutation',
    () async {
      final database = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(database.close);
      final repository = ChatRepository(database: database);

      final local = await repository.sendMessage(
        conversationId: 'default',
        content: '本地消息',
      );
      await repository.applyRemoteMessage({
        'conversationId': 'default',
        'id': local.id,
        'role': 'user',
        'content': '不应覆盖',
        'createdAt': local.createdAt,
        'version': 2,
      });

      final messages = await repository.watchMessages('default').first;
      expect(messages.single.content, '本地消息');
      expect(messages.single.syncStatus, 'pendingCreate');
    },
  );
}
