import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/chat/application/chat_controller.dart';
import 'package:orialis_mobile/features/chat/data/chat_repository.dart';

void main() {
  test('controller keeps local-first send state and flushes once', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = ChatRepository(database: database);
    var flushes = 0;
    final controller = ChatController(
      repository: repository,
      flush: () async => flushes++,
    );

    await controller.send(conversationId: 'default', content: 'hello');

    expect(controller.state, ChatSendState.idle);
    expect(flushes, 1);
    expect(
      (await repository.watchMessages('default').first).single.content,
      'hello',
    );
  });

  test('controller exposes failed delivery for retry UI', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = ChatRepository(database: database);
    var attempts = 0;
    final controller = ChatController(
      repository: repository,
      flush: () async {
        attempts++;
        if (attempts == 1) throw StateError('offline');
      },
    );

    await expectLater(
      controller.send(conversationId: 'default', content: 'hello'),
      throwsStateError,
    );
    expect(controller.state, ChatSendState.failed);
    expect(controller.lastError, isA<StateError>());
    final messageId = controller.lastMessageId!;
    await controller.retry(messageId);
    expect(controller.state, ChatSendState.idle);
    expect(controller.lastMessageId, messageId);
    expect((await repository.watchMessages('default').first), hasLength(1));
  });
}
