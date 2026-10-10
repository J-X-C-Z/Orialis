import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';

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
  Completer<void>? conversationGate;
  Completer<void>? scheduleGate;

  @override
  Future<Map<String, dynamic>> createConversation({
    required String title,
    String? id,
    String? mutationId,
    int? manualPosition,
    bool pinned = false,
  }) async {
    calls.add('conversation-start');
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
    await scheduleGate?.future;
    calls.add('schedule-finish');
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
  }) async => const MessagePage(items: []);
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
    'conversation and schedule pushes start together and both gate task pull',
    () async {
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
              syncStatus: Value('pendingCreate'),
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
              syncStatus: Value('pendingCreate'),
            ),
          );
      final engine = SyncEngine(
        database: database,
        config: config,
        apiClient: api,
      );

      final run = engine.syncOnce();
      await Future<void>.delayed(Duration.zero);
      expect(api.calls.toSet(), {'conversation-start', 'schedule-start'});
      expect(api.snapshotCalls, 0);
      api.scheduleGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(api.snapshotCalls, 0);
      api.conversationGate!.complete();

      expect(await run, SyncState.idle);
      expect(
        api.calls,
        containsAllInOrder(['conversation-start', 'conversation-finish']),
      );
      expect(api.snapshotCalls, 1);
      expect(api.eventCalls, 1);
    },
  );
}
