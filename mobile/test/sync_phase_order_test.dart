import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/core/sync/outbox_store.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';

const _now = '2026-10-10T00:00:00Z';
const _stages = [
  'conversation.push',
  'schedule.push',
  'task.push',
  'conversation.pull',
  'message.push',
  'message.pull',
  'events.pull',
  'derived.push',
  'project.push',
  'milestone.push',
];

class _Gate {
  final started = Completer<void>();
  final release = Completer<void>();
  final finished = Completer<void>();

  void open() {
    if (!release.isCompleted) release.complete();
  }
}

class _PhaseApi extends OrialisApiClient {
  _PhaseApi({bool blocked = true})
    : super(baseUrl: 'http://unused.invalid', deviceId: 'phase-test') {
    if (!blocked) releaseAll();
  }

  final gates = {for (final stage in _stages) stage: _Gate()};
  final calls = <String>[];
  final messageConversations = <String>[];
  final taskPayloads = <String, Map<String, dynamic>>{};

  Future<void> enter(String stage) async {
    calls.add(stage);
    final gate = gates[stage]!;
    if (!gate.started.isCompleted) gate.started.complete();
    await gate.release.future;
    if (!gate.finished.isCompleted) gate.finished.complete();
  }

  Future<void> started(String stage) =>
      gates[stage]!.started.future.timeout(const Duration(seconds: 10));

  Future<void> finish(String stage) async {
    gates[stage]!.open();
    await gates[stage]!.finished.future.timeout(const Duration(seconds: 10));
  }

  void releaseAll() {
    for (final gate in gates.values) {
      gate.open();
    }
  }

  @override
  Future<Set<String>> capabilities() async => {'task_children'};

  @override
  Future<Map<String, dynamic>> createConversation({
    required String title,
    String? id,
    String? mutationId,
    int? manualPosition,
    bool pinned = false,
  }) async {
    await enter('conversation.push');
    return {'version': 1};
  }

  @override
  Future<Map<String, dynamic>> createSchedule(
    Map<String, dynamic> payload,
    String mutationId,
  ) async {
    await enter('schedule.push');
    return {'version': 1};
  }

  @override
  Future<Map<String, dynamic>> createTask(
    Map<String, dynamic> payload,
    String mutationId,
  ) async {
    taskPayloads[payload['id'] as String] = Map.of(payload);
    await enter('task.push');
    return {'version': 1};
  }

  @override
  Future<Map<String, dynamic>> updateTask(
    String id,
    Map<String, dynamic> payload,
    String mutationId,
  ) async {
    taskPayloads[id] = Map.of(payload);
    await enter('derived.push');
    return {'version': 2};
  }

  @override
  Future<List<Map<String, dynamic>>> listConversations() async {
    await enter('conversation.pull');
    return [];
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
    await enter('message.push');
    return {'version': 1};
  }

  @override
  Future<List<Map<String, dynamic>>> listMessages(String conversationId) async {
    messageConversations.add(conversationId);
    await enter('message.pull');
    return [];
  }

  @override
  Future<Map<String, dynamic>> syncEvents({required int after}) async {
    await enter('events.pull');
    return {'events': [], 'nextCursor': after};
  }

  @override
  Future<Map<String, dynamic>> syncSnapshot() async =>
      throw StateError('Seeded cursor must not need a snapshot');

  @override
  Future<Map<String, dynamic>> createProject(
    Map<String, dynamic> payload,
    String mutationId,
  ) async {
    await enter('project.push');
    return {'version': 1};
  }

  @override
  Future<Map<String, dynamic>> createProjectMilestone(
    String projectId,
    Map<String, dynamic> payload,
    String mutationId,
  ) async {
    await enter('milestone.push');
    return {'version': 1};
  }
}

Future<void> _seed(AppDatabase db) async {
  await db.batch((batch) {
    batch.insertAll(db.syncMetadata, [
      SyncMetadataCompanion.insert(key: 'serverCursor', value: '0'),
      SyncMetadataCompanion.insert(
        key: 'projectMilestoneSnapshotVersion',
        value: '1',
      ),
    ]);
    batch.insert(
      db.conversations,
      ConversationsCompanion.insert(
        id: 'chat',
        title: 'Chat',
        createdAt: _now,
        updatedAt: _now,
        syncStatus: const drift.Value('pendingCreate'),
      ),
    );
    batch.insert(
      db.messages,
      MessagesCompanion.insert(
        conversationId: 'chat',
        id: 'message',
        role: 'user',
        content: 'Queued message',
        createdAt: _now,
        syncStatus: const drift.Value('pendingCreate'),
      ),
    );
    batch.insert(
      db.calendarEvents,
      CalendarEventsCompanion.insert(
        id: 'schedule',
        title: 'Schedule',
        startAt: _now,
        endAt: _now,
        createdAt: _now,
        updatedAt: _now,
        syncStatus: const drift.Value('pendingCreate'),
      ),
    );
    batch.insertAll(db.tasks, [
      TasksCompanion.insert(
        id: 'task',
        title: 'Task',
        scheduleId: const drift.Value('schedule'),
        createdAt: _now,
        updatedAt: _now,
        syncStatus: const drift.Value('pendingCreate'),
      ),
      TasksCompanion.insert(
        id: 'derived',
        title: 'Derived completion',
        parentTaskId: const drift.Value('task'),
        completed: const drift.Value(true),
        remoteVersion: const drift.Value(1),
        localRevision: const drift.Value(1),
        createdAt: _now,
        updatedAt: _now,
        syncStatus: const drift.Value('pendingUpdate'),
      ),
    ]);
    batch.insert(
      db.projects,
      ProjectsCompanion.insert(
        id: 'project',
        name: 'Project',
        createdAt: _now,
        updatedAt: _now,
        syncStatus: const drift.Value('pendingCreate'),
      ),
    );
    batch.insert(
      db.projectMilestones,
      ProjectMilestonesCompanion.insert(
        id: 'milestone',
        projectId: 'project',
        title: 'Milestone',
        createdAt: _now,
        updatedAt: _now,
        syncStatus: const drift.Value('pendingCreate'),
      ),
    );
  });
  await OutboxStore(db).enqueue(
    entityType: 'task',
    entityId: 'derived',
    operation: 'update',
    payloadJson: jsonEncode({
      'id': 'derived',
      'title': 'Derived completion',
      'parentTaskId': 'task',
      'completed': true,
      'completedAt': _now,
      '_derivedCompletionCauseId': 'task',
    }),
    baseVersion: 1,
    entityRevision: 1,
  );
}

// Drain queued futures without a wall-clock delay. Progress is controlled by
// explicit API barriers, never by assuming that a request finishes in N ms.
Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('public message policy helpers remain instance methods', () {
    final db = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(db.close);
    final dynamic engine = SyncEngine(database: db, config: AppConfig());
    expect(engine.isIgnorableMessageFetchStatus(404), isTrue);
    expect(engine.isIgnorableMessageCreateStatus(401), isFalse);
    expect(
      engine.remoteContainsMessage(<Map<String, dynamic>>[
        {'id': 'm'},
      ], 'm'),
      isTrue,
    );
  });

  for (final first in ['conversation.push', 'schedule.push']) {
    test('phase barriers hold when $first completes first', () async {
      final db = AppDatabase(executor: NativeDatabase.memory());
      final api = _PhaseApi();
      Future<SyncState>? run;
      addTearDown(() async {
        api.releaseAll();
        if (run != null) await run.timeout(const Duration(seconds: 10));
        await db.close();
      });
      await _seed(db);
      final engine = SyncEngine(
        database: db,
        config: AppConfig(),
        apiClient: api,
      );
      run = engine.syncOnce();
      // Both requests must start while neither is allowed to finish.
      await Future.wait([
        api.started('conversation.push'),
        api.started('schedule.push'),
      ]);
      expect(
        api.calls,
        unorderedEquals(['conversation.push', 'schedule.push']),
      );
      await api.finish(first);
      await _drain();
      expect(api.gates['task.push']!.started.isCompleted, isFalse);
      await api.finish(
        first == 'conversation.push' ? 'schedule.push' : 'conversation.push',
      );
      await api.started('task.push');
      expect(api.gates['conversation.pull']!.started.isCompleted, isFalse);
      expect(api.gates['derived.push']!.started.isCompleted, isFalse);
      await api.finish('task.push');
      await api.started('conversation.pull');
      expect(api.gates['message.push']!.started.isCompleted, isFalse);
      expect(api.gates['message.pull']!.started.isCompleted, isFalse);
      await api.finish('conversation.pull');
      await Future.wait([
        api.started('message.push'),
        api.started('message.pull'),
      ]);
      final firstMessage = first == 'conversation.push'
          ? 'message.push'
          : 'message.pull';
      await api.finish(firstMessage);
      await _drain();
      expect(api.gates['events.pull']!.started.isCompleted, isFalse);
      await api.finish(
        firstMessage == 'message.push' ? 'message.pull' : 'message.push',
      );
      await api.started('events.pull');
      expect(api.gates['derived.push']!.started.isCompleted, isFalse);
      await api.finish('events.pull');
      await api.started('derived.push');
      expect(api.gates['project.push']!.started.isCompleted, isFalse);
      await api.finish('derived.push');
      await api.started('project.push');
      expect(api.gates['milestone.push']!.started.isCompleted, isFalse);
      await api.finish('project.push');
      await api.started('milestone.push');
      var finished = false;
      unawaited(run.then((_) => finished = true));
      await _drain();
      expect(finished, isFalse);
      await api.finish('milestone.push');
      expect(await run, SyncState.idle);
      expect(api.taskPayloads['task']!['scheduleId'], 'schedule');
      expect(api.taskPayloads['derived'], isNot(contains('completed')));
      expect(
        api.taskPayloads['derived'],
        isNot(contains('_derivedCompletionCauseId')),
      );
      expect(api.messageConversations, ['default', 'chat']);
      expect(
        (await db.select(db.outboxMutations).get()).every(
          (row) => row.status == OutboxStatus.acknowledged,
        ),
        isTrue,
      );
    });
  }

  test(
    'includeChat false skips all chat phases and preserves queued chat',
    () async {
      final db = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(db.close);
      final api = _PhaseApi(blocked: false);
      await _seed(db);
      final engine = SyncEngine(
        database: db,
        config: AppConfig(),
        apiClient: api,
        includeChat: false,
      );
      expect(await engine.syncOnce(), SyncState.idle);
      expect(api.calls, [
        'schedule.push',
        'task.push',
        'events.pull',
        'derived.push',
        'project.push',
        'milestone.push',
      ]);
      expect(api.messageConversations, isEmpty);
      expect(
        (await db.select(db.conversations).getSingle()).syncStatus,
        'pendingCreate',
      );
      expect(
        (await db.select(db.messages).getSingle()).syncStatus,
        'pendingCreate',
      );
    },
  );
}
