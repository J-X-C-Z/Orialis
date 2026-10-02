import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/features/chat/data/chat_repository.dart';

class _DomainApi extends OrialisApiClient {
  _DomainApi() : super(baseUrl: 'http://127.0.0.1:1', deviceId: 'desktop-test');
  int pulls = 0;
  @override
  Future<Map<String, dynamic>> syncSnapshot() async => {
    'cursor': 0,
    'tasks': [],
    'calendarEvents': [],
    'projects': [],
    'milestones': [],
  };
  @override
  Future<Map<String, dynamic>> syncEvents({required int after}) async {
    pulls++;
    return {'nextCursor': after, 'events': [], 'hasMore': false};
  }

  @override
  Future<List<Map<String, dynamic>>> listConversations() =>
      throw StateError('chat HTTP called');
  @override
  Future<List<Map<String, dynamic>>> listMessages(String conversationId) =>
      throw StateError('message HTTP called');
}

void main() {
  test(
    'desktop sync ignores pending chat while continuing snapshot and cursor pulls',
    () async {
      final db = AppDatabase(executor: AppDatabase.inMemoryExecutor());
      addTearDown(db.close);
      // Pending chat in a compatible database must neither upload nor block sync.
      final chat = ChatRepository(database: db);
      await chat.createConversation(title: 'Excluded desktop data');
      final api = _DomainApi();
      final sync = SyncEngine(
        database: db,
        config: AppConfig(),
        apiClient: api,
        includeChat: false,
      );
      expect(await sync.syncOnce(), SyncState.idle);
      expect(await sync.syncOnce(), SyncState.idle);
      expect(api.pulls, 2);
      expect(
        (await db.select(db.conversations).get()).single.syncStatus,
        'pendingCreate',
      );
    },
  );
}
