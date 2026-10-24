import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/features/chat/application/chat_controller.dart';
import 'package:orialis_mobile/features/chat/data/chat_repository.dart';

class CharacterizationConfig extends AppConfig {
  CharacterizationConfig({this.token});

  final String? token;
  int serverUrlReads = 0;
  int deviceIdReads = 0;

  @override
  Future<String?> sessionToken() async => token;

  @override
  Future<String> serverUrl() async {
    serverUrlReads++;
    return 'http://unused.invalid';
  }

  @override
  Future<String> deviceId() async {
    deviceIdReads++;
    return 'characterization-device';
  }
}

class CharacterizationApi extends OrialisApiClient {
  CharacterizationApi()
    : super(baseUrl: 'http://unused.invalid', deviceId: 'injected-device');

  int snapshotCalls = 0;
  int eventCalls = 0;
  final calls = <String>[];
  final conversationStarted = Completer<void>();
  final scheduleStarted = Completer<void>();
  final historyStarted = Completer<void>();
  final messageStarted = Completer<void>();
  int messagePosts = 0;
  final postedMessageIds = <String>[];
  final gatedMessageIds = <String>{};
  Completer<void>? conversationGate;
  Completer<void>? scheduleGate;
  Completer<void>? historyGate;
  Completer<void>? messageGate;

  @override
  Future<Map<String, dynamic>> createConversation({
    required String title,
    String? id,
    String? mutationId,
    int? manualPosition,
    bool pinned = false,
  }) async {
    calls.add('conversation-start');
    if (!conversationStarted.isCompleted) conversationStarted.complete();
    await conversationGate?.future;
    calls.add('conversation-finish');
    return {'version': 1};
  }

  @override
  Future<Map<String, dynamic>> createSchedule(
    Map<String, dynamic> payload,
    String mutationId,
  ) async {
    calls.add('schedule-start');
    if (!scheduleStarted.isCompleted) scheduleStarted.complete();
    await scheduleGate?.future;
    calls.add('schedule-finish');
    return {'version': 1};
  }

  @override
  Future<Map<String, dynamic>> createMessage({
    required String conversationId,
    required String id,
    required String content,
    List<Map<String, dynamic>> attachments = const [],
    String? replyToMessageId,
    String? replyQuote,
    String? replyRole,
  }) async {
    messagePosts++;
    postedMessageIds.add(id);
    calls.add('message:$id');
    if (!messageStarted.isCompleted) messageStarted.complete();
    if (messageGate != null &&
        (gatedMessageIds.isEmpty || gatedMessageIds.contains(id))) {
      await messageGate!.future;
    }
    return {'version': 1};
  }

  @override
  Future<Map<String, dynamic>> syncSnapshot() async {
    snapshotCalls++;
    return {
      'cursor': 0,
      'projects': <Map<String, dynamic>>[],
      'milestones': <Map<String, dynamic>>[],
      'tasks': <Map<String, dynamic>>[],
      'calendarEvents': <Map<String, dynamic>>[],
    };
  }

  @override
  Future<Map<String, dynamic>> syncEvents({required int after}) async {
    eventCalls++;
    return {'events': [], 'nextCursor': after};
  }

  @override
  Future<List<Map<String, dynamic>>> listConversations() async => [];

  @override
  Future<MessagePage> listMessagesPage(
    String conversationId, {
    String? after,
    int? limit,
  }) async {
    if (!historyStarted.isCompleted) historyStarted.complete();
    await historyGate?.future;
    return const MessagePage(items: []);
  }
}

void main() {
  test(
    'an injected API is selected before config URL/device resolution',
    () async {
      final database = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(database.close);
      final config = CharacterizationConfig(token: 'fake-session');
      final api = CharacterizationApi();
      final engine = SyncEngine(
        database: database,
        config: config,
        apiClient: api,
        includeChat: false,
      );

      expect(await engine.syncOnce(), SyncState.idle);

      expect(api.snapshotCalls, 1);
      expect(api.eventCalls, 1);
      expect(config.serverUrlReads, 0);
      expect(config.deviceIdReads, 0);
    },
  );

  test('required session is checked before any API call', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final config = CharacterizationConfig();
    final api = CharacterizationApi();
    final engine = SyncEngine(
      database: database,
      config: config,
      apiClient: api,
      includeChat: false,
      requireSession: true,
    );

    expect(await engine.syncOnce(), SyncState.authRequired);

    expect(api.snapshotCalls, 0);
    expect(api.eventCalls, 0);
    expect(config.serverUrlReads, 0);
    expect(config.deviceIdReads, 0);
  });

  test(
    'a new message is acknowledged while full history sync is stalled',
    () async {
      final database = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(database.close);
      final api = CharacterizationApi()..historyGate = Completer<void>();
      final engine = SyncEngine(
        database: database,
        config: CharacterizationConfig(token: 'fake-session'),
        apiClient: api,
      );
      final fullSync = engine.syncOnce();
      await api.historyStarted.future.timeout(const Duration(seconds: 5));

      final repository = ChatRepository(database: database);
      final controller = ChatController(
        repository: repository,
        flush: (conversationId, messageId) => engine.flushChatMessage(
          conversationId: conversationId,
          messageId: messageId,
        ),
      );
      await controller.send(conversationId: 'default', content: 'hello');

      expect(api.messagePosts, 1);
      expect(api.historyGate!.isCompleted, isFalse);
      expect(
        (await repository.watchMessages('default').first).single.syncStatus,
        'synced',
      );
      api.historyGate!.complete();
      expect(await fullSync, SyncState.idle);
    },
  );

  test('targeted flush shares an in-flight full-sync message POST', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final api = CharacterizationApi()..messageGate = Completer<void>();
    final engine = SyncEngine(
      database: database,
      config: CharacterizationConfig(token: 'fake-session'),
      apiClient: api,
    );
    final message = await ChatRepository(database: database)
        .sendMessage(conversationId: 'default', content: 'hello');
    final fullSync = engine.syncOnce();
    await api.messageStarted.future.timeout(const Duration(seconds: 5));

    final targeted = engine.flushChatMessage(
      conversationId: 'default',
      messageId: message.id,
    );
    api.messageGate!.complete();
    await targeted;
    expect(api.messagePosts, 1);
    expect(await fullSync, SyncState.idle);
  });

  test(
    'targeted flush uploads a pending conversation before its message',
    () async {
      final database = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(database.close);
      const now = '2026-10-10T00:00:00Z';
      await database
          .into(database.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: 'chat',
              title: 'Chat',
              createdAt: now,
              updatedAt: now,
              syncStatus: const Value('pendingCreate'),
            ),
          );
      final message = await ChatRepository(database: database)
          .sendMessage(conversationId: 'chat', content: 'hello');
      final api = CharacterizationApi();
      final engine = SyncEngine(
        database: database,
        config: CharacterizationConfig(token: 'fake-session'),
        apiClient: api,
      );

      await engine.flushChatMessage(
        conversationId: 'chat',
        messageId: message.id,
      );

      expect(api.calls, [
        'conversation-start',
        'conversation-finish',
        'message:${message.id}',
      ]);
    },
  );

  test('targeted flush works with background chat sync disabled and preserves same-conversation order', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = ChatRepository(database: database);
    final first = await repository.sendMessage(
      conversationId: 'chat',
      content: 'first',
    );
    final second = await repository.sendMessage(
      conversationId: 'chat',
      content: 'second',
      replyToMessageId: first.id,
    );
    await repository.sendMessage(
      conversationId: 'another-chat',
      content: 'must not block this send',
    );
    final api = CharacterizationApi();
    final engine = SyncEngine(
      database: database,
      config: CharacterizationConfig(token: 'fake-session'),
      apiClient: api,
      includeChat: false,
    );

    expect(await engine.syncOnce(), SyncState.idle);
    expect(api.messagePosts, 0);

    await engine.flushChatMessage(conversationId: 'chat', messageId: second.id);

    expect(api.postedMessageIds, [first.id, second.id]);
    expect(
      (await repository.watchMessages('another-chat').first).single.syncStatus,
      'pendingCreate',
    );
  });

  test('full sync skips a target message sent while another conversation is blocked', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = ChatRepository(database: database);
    await repository.sendMessage(
      conversationId: 'blocked-chat',
      content: 'earlier full-sync message',
    );
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final target = await repository.sendMessage(
      conversationId: 'target-chat',
      content: 'target message',
    );
    final blocked =
        (await repository.watchMessages('blocked-chat').first).single;
    final api = CharacterizationApi()
      ..messageGate = Completer<void>()
      ..gatedMessageIds.add(blocked.id);
    final engine = SyncEngine(
      database: database,
      config: CharacterizationConfig(token: 'fake-session'),
      apiClient: api,
    );

    final fullSync = engine.syncOnce();
    await api.messageStarted.future.timeout(const Duration(seconds: 5));
    await engine.flushChatMessage(
      conversationId: 'target-chat',
      messageId: target.id,
    );
    expect(api.postedMessageIds, [blocked.id, target.id]);

    api.messageGate!.complete();
    expect(await fullSync, SyncState.idle);
    expect(api.postedMessageIds, [blocked.id, target.id]);
  });

  test('conversation push finishes before calendar pushes begin', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final config = CharacterizationConfig(token: 'fake-session');
    final api = CharacterizationApi()
      ..conversationGate = Completer<void>()
      ..scheduleGate = Completer<void>();
    const now = '2026-10-10T00:00:00Z';
    await database
        .into(database.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: 'conversation-1',
            title: 'Local',
            createdAt: now,
            updatedAt: now,
            syncStatus: const Value('pendingCreate'),
          ),
        );
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'schedule-1',
            title: 'Local',
            startAt: now,
            endAt: now,
            createdAt: now,
            updatedAt: now,
            syncStatus: const Value('pendingCreate'),
          ),
        );
    final engine = SyncEngine(
      database: database,
      config: config,
      apiClient: api,
    );

    final run = engine.syncOnce();
    addTearDown(() async {
      if (!api.conversationGate!.isCompleted) {
        api.conversationGate!.complete();
      }
      if (!api.scheduleGate!.isCompleted) api.scheduleGate!.complete();
      await run.timeout(const Duration(seconds: 10));
    });
    await api.conversationStarted.future.timeout(const Duration(seconds: 10));
    expect(api.scheduleStarted.isCompleted, isFalse);
    expect(api.snapshotCalls, 0);
    api.conversationGate!.complete();
    await api.scheduleStarted.future.timeout(const Duration(seconds: 10));
    expect(
      api.calls,
      containsAllInOrder([
        'conversation-start',
        'conversation-finish',
        'schedule-start',
      ]),
    );
    await Future<void>.delayed(Duration.zero);
    expect(api.snapshotCalls, 0);
    api.scheduleGate!.complete();

    expect(await run, SyncState.idle);
    expect(
      api.calls,
      containsAllInOrder(['conversation-start', 'conversation-finish']),
    );
    expect(api.snapshotCalls, 1);
    expect(api.eventCalls, 1);
  });
}
