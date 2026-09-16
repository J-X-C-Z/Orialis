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
}
