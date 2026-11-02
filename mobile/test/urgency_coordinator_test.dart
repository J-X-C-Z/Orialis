import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/features/chat/data/agent_chat_service.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';
import 'package:orialis_mobile/features/events/data/urgency_coordinator.dart';

class FakeApi extends OrialisApiClient {
  FakeApi() : super(baseUrl: 'https://unused.invalid', deviceId: 'test');
  int calls = 0;
  Map<String, dynamic>? evidence;
  Future<void> Function()? duringAssessment;
  String? badId;
  bool fail = false;
  bool decidedUrgent = true;

  @override
  Future<Map<String, dynamic>> createMemoryAnalysis({
    required String id,
    required String content,
    String? imageBase64,
    List<String> sourceUrls = const [],
  }) async {
    calls++;
    evidence = jsonDecode(content) as Map<String, dynamic>;
    await duringAssessment?.call();
    if (fail) throw StateError('offline');
    final tasks = (evidence!['context'] as Map)['tasks'] as List;
    return {
      'id': id,
      'status': 'completed',
      'content': jsonEncode({
        'tasks': [
          {
            'id': badId ?? (tasks.first as Map)['id'],
            'urgent': decidedUrgent,
            'reason': '截止前的空闲时段不足以完成备注中的工作量',
          },
        ],
        'reviewAt': DateTime.now()
            .add(const Duration(hours: 3))
            .toUtc()
            .toIso8601String(),
      }),
    };
  }
}

class FakeAgents extends AgentChatService {
  FakeAgents(this.api) : super(AppConfig());
  final FakeApi api;
  String token = 'session-a';
  @override
  Future<(String, String)> identity() async =>
      ('https://unused.invalid', token);
  @override
  Future<OrialisApiClient> client() async => api;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late EventRepository repo;
  late FakeApi api;
  late FakeAgents agents;
  late UrgencyCoordinator coordinator;
  bool owns = true;

  setUp(() async {
    db = AppDatabase(executor: NativeDatabase.memory());
    repo = EventRepository(database: db, config: AppConfig());
    api = FakeApi();
    agents = FakeAgents(api);
    owns = true;
    coordinator = UrgencyCoordinator(
      database: db,
      repository: repo,
      agents: agents,
      ownsDatabase: () async => owns,
    );
    await repo.createTask(
      title: '作业',
      notes: '预计需要12小时，已完成一半',
      due: '2027-01-01',
      important: false,
      urgent: false,
    );
  });
  tearDown(() async {
    coordinator.dispose();
    agents.dispose();
    api.close();
    await db.close();
  });

  test(
    'AI uses context, preserves importance and saves urgency to sync outbox',
    () async {
      await coordinator.refresh();
      final task = await db.select(db.tasks).getSingle();
      expect(task.urgent, true);
      expect(task.important, false);
      expect(task.notes, contains('12小时'));
      expect(api.evidence!['kind'], 'orialis.urgency.v1');
      final context = api.evidence!['context'] as Map;
      expect(
        context.keys,
        containsAll([
          'now',
          'utcOffsetMinutes',
          'tasks',
          'schedules',
          'projects',
        ]),
      );
      expect(
        (await db.select(db.outboxMutations).get()).any(
          (m) => (jsonDecode(m.payloadJson) as Map)['urgent'] == true,
        ),
        true,
      );
      await coordinator.refresh();
      expect(
        api.calls,
        1,
        reason: 'own writes must not cause an AI request loop',
      );
    },
  );

  test(
    'AI can lower urgency on a later review without changing importance',
    () async {
      await coordinator.refresh();
      api.decidedUrgent = false;
      await coordinator.refresh(timeChanged: true);
      final task = await db.select(db.tasks).getSingle();
      expect(task.urgent, false);
      expect(task.important, false);
      expect(api.calls, 2);
    },
  );

  test('concurrent user changes invalidate the AI result', () async {
    api.duringAssessment = () async {
      final task = await db.select(db.tasks).getSingle();
      await repo.updateTask(task, title: '已延期的作业');
    };
    await coordinator.refresh();
    final task = await db.select(db.tasks).getSingle();
    expect(task.title, '已延期的作业');
    expect(task.urgent, false);
  });

  test('account change, wrong database, offline and invalid IDs never change tasks', () async {
    owns = false;
    await coordinator.refresh();
    expect(api.calls, 0);
    owns = true;
    api.duringAssessment = () async {
      agents.token = 'session-b';
    };
    await coordinator.refresh();
    expect((await db.select(db.tasks).getSingle()).urgent, false);
    api.duringAssessment = null;
    api.fail = true;
    await coordinator.refresh();
    api.fail = false;
    api.badId = 'not-supplied';
    await coordinator.refresh();
    expect((await db.select(db.tasks).getSingle()).urgent, false);
  });

  test('decisions validate the whole batch before any mutation', () {
    for (final rows in [
      [
        {'id': 'a', 'urgent': true, 'reason': '依据'},
        {'id': 'a', 'urgent': false, 'reason': '依据'},
      ],
      [
        {'id': 'a', 'urgent': 1, 'reason': '依据'},
      ],
      [
        {'id': 'a', 'urgent': true, 'reason': ''},
      ],
    ]) {
      expect(
        () => UrgencyAssessment.parse(
          jsonEncode({'tasks': rows, 'reviewAt': '2026-11-02T10:00:00+08:00'}),
          {'a'},
        ),
        throwsFormatException,
      );
    }
  });
}
