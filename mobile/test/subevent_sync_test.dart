import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/core/sync/outbox_store.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';

const _now = '2026-09-24T00:00:00Z';

class _Config extends AppConfig {
  @override
  Future<String> serverUrl() async => 'http://localhost';

  @override
  Future<String> deviceId() async => 'test-device';

  @override
  Future<String?> sessionToken() async => null;
}

class _Api extends OrialisApiClient {
  _Api() : super(baseUrl: 'http://localhost', deviceId: 'test');

  final taskUploads = <Map<String, dynamic>>[];
  final scheduleUploads = <Map<String, dynamic>>[];
  final uploadOrder = <String>[];
  final taskUpdates = <Map<String, dynamic>>[];
  final advertisedCapabilities = <String>{
    'task_children',
    'schedule_importance',
  };
  int capabilityCalls = 0;
  bool capabilitiesUnavailable = false;

  @override
  Future<Set<String>> capabilities() async {
    capabilityCalls++;
    if (capabilitiesUnavailable) {
      final request = RequestOptions(path: '/api/v1/capabilities');
      throw DioException(
        requestOptions: request,
        response: Response<void>(requestOptions: request, statusCode: 404),
      );
    }
    return advertisedCapabilities;
  }

  @override
  Future<Map<String, dynamic>> createTask(
    Map<String, dynamic> payload,
    String mutationId,
  ) async {
    taskUploads.add(Map.of(payload));
    uploadOrder.add('task:${payload['id']}');
    return {'version': 1};
  }

  @override
  Future<Map<String, dynamic>> createSchedule(
    Map<String, dynamic> payload,
    String mutationId,
  ) async {
    scheduleUploads.add(Map.of(payload));
    uploadOrder.add('schedule:${payload['id']}');
    return {'version': 1};
  }

  @override
  Future<Map<String, dynamic>> updateTask(
    String id,
    Map<String, dynamic> payload,
    String mutationId,
  ) async {
    taskUpdates.add({'id': id, ...payload});
    return {'version': 3};
  }

  @override
  Future<List<Map<String, dynamic>>> listConversations() async => [];

  @override
  Future<List<Map<String, dynamic>>> listMessages(
    String conversationId,
  ) async => [];

  @override
  Future<Map<String, dynamic>> syncSnapshot() async => {
    'cursor': 0,
    'projects': [],
    'milestones': [],
    'tasks': [],
    'calendarEvents': [],
  };

  @override
  Future<Map<String, dynamic>> syncEvents({required int after}) async => {
    'events': [],
    'nextCursor': after,
  };
}

void main() {
  late AppDatabase database;
  late _Api api;
  late SyncEngine engine;

  setUp(() {
    database = AppDatabase(executor: NativeDatabase.memory());
    api = _Api();
    engine = SyncEngine(database: database, config: _Config(), apiClient: api);
  });

  tearDown(() => database.close());

  test('uploads parent before child and preserves task associations', () async {
    await database.batch((batch) {
      batch.insert(
        database.tasks,
        TasksCompanion.insert(
          id: 'parent',
          title: 'Parent',
          createdAt: _now,
          updatedAt: _now,
          syncStatus: const drift.Value('pendingCreate'),
        ),
      );
      batch.insert(
        database.tasks,
        TasksCompanion.insert(
          id: 'child',
          title: 'Child',
          parentTaskId: const drift.Value('parent'),
          createdAt: _now,
          updatedAt: _now,
          syncStatus: const drift.Value('pendingCreate'),
        ),
      );
    });

    expect(await engine.syncOnce(), SyncState.idle);
    expect(api.taskUploads.map((payload) => payload['id']), [
      'parent',
      'child',
    ]);
    expect(api.taskUploads.last['parentTaskId'], 'parent');
    expect(api.taskUploads.last['scheduleId'], isNull);
  });

  test(
    'schedule importance and task schedule association are uploaded',
    () async {
      await database
          .into(database.tasks)
          .insert(
            TasksCompanion.insert(
              id: 'scheduled-child',
              title: 'Scheduled child',
              scheduleId: const drift.Value('schedule-1'),
              createdAt: _now,
              updatedAt: _now,
              syncStatus: const drift.Value('pendingCreate'),
            ),
          );
      await database
          .into(database.calendarEvents)
          .insert(
            CalendarEventsCompanion.insert(
              id: 'schedule-1',
              title: 'Important schedule',
              startAt: _now,
              endAt: '2026-09-24T01:00:00Z',
              important: const drift.Value(true),
              createdAt: _now,
              updatedAt: _now,
              syncStatus: const drift.Value('pendingCreate'),
            ),
          );

      expect(await engine.syncOnce(), SyncState.idle);
      expect(api.taskUploads.single['scheduleId'], 'schedule-1');
      expect(api.scheduleUploads.single['important'], isTrue);
      expect(api.uploadOrder, ['schedule:schedule-1', 'task:scheduled-child']);
    },
  );

  test('legacy snapshots preserve association and importance fields', () async {
    await engine.applySnapshot({
      'cursor': 1,
      'projects': [],
      'milestones': [],
      'tasks': [
        {
          'id': 'task-1',
          'title': 'Child',
          'parent_task_id': 'parent-1',
          'schedule_id': null,
          'version': 1,
          'createdAt': _now,
          'updatedAt': _now,
        },
      ],
      'calendarEvents': [
        {
          'id': 'schedule-1',
          'title': 'Schedule',
          'startAt': _now,
          'endAt': '2026-09-24T01:00:00Z',
          'important': true,
          'version': 1,
          'createdAt': _now,
          'updatedAt': _now,
        },
      ],
    });
    await engine.applySnapshot({
      'cursor': 2,
      'projects': [],
      'milestones': [],
      'tasks': [
        {
          'id': 'task-1',
          'title': 'Child (legacy payload)',
          'version': 2,
          'createdAt': _now,
          'updatedAt': _now,
        },
      ],
      'calendarEvents': [
        {
          'id': 'schedule-1',
          'title': 'Schedule (legacy payload)',
          'startAt': _now,
          'endAt': '2026-09-24T01:00:00Z',
          'version': 2,
          'createdAt': _now,
          'updatedAt': _now,
        },
      ],
    });

    final task = await database.select(database.tasks).getSingle();
    final schedule = await database.select(database.calendarEvents).getSingle();
    expect(task.parentTaskId, 'parent-1');
    expect(task.scheduleId, isNull);
    expect(schedule.important, isTrue);
  });

  test('outbox association payload uses stable JSON wire keys', () async {
    await database
        .into(database.tasks)
        .insert(
          TasksCompanion.insert(
            id: 'child',
            title: 'Child',
            parentTaskId: const drift.Value('parent'),
            createdAt: _now,
            updatedAt: _now,
            syncStatus: const drift.Value('pendingCreate'),
          ),
        );
    expect(await engine.syncOnce(), SyncState.idle);
    final sent = api.taskUploads.single;
    expect(sent.containsKey('parentTaskId'), isTrue);
    expect(sent.containsKey('scheduleId'), isTrue);
    expect(jsonEncode(sent), isNot(contains('parent_task_id')));
  });

  test('older pending outbox rows regain local association fields', () async {
    final task = await database
        .into(database.tasks)
        .insertReturning(
          TasksCompanion.insert(
            id: 'offline-child',
            title: 'Offline child',
            scheduleId: const drift.Value('schedule-2'),
            createdAt: _now,
            updatedAt: _now,
            syncStatus: const drift.Value('pendingCreate'),
          ),
        );
    await OutboxStore(database).enqueue(
      entityType: 'task',
      entityId: task.id,
      operation: 'create',
      payloadJson: '{"id":"offline-child","title":"Offline child"}',
      baseVersion: null,
      entityRevision: task.localRevision,
    );

    expect(await engine.syncOnce(), SyncState.idle);
    expect(api.taskUploads.single['scheduleId'], 'schedule-2');
  });

  test('root-only sync does not fetch optional capabilities', () async {
    await database
        .into(database.tasks)
        .insert(
          TasksCompanion.insert(
            id: 'root',
            title: 'Root task',
            createdAt: _now,
            updatedAt: _now,
            syncStatus: const drift.Value('pendingCreate'),
          ),
        );
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'ordinary-schedule',
            title: 'Ordinary schedule',
            startAt: _now,
            endAt: '2026-09-24T01:00:00Z',
            createdAt: _now,
            updatedAt: _now,
            syncStatus: const drift.Value('pendingCreate'),
          ),
        );

    expect(await engine.syncOnce(), SyncState.idle);
    expect(api.capabilityCalls, 0);
  });

  test('missing task capability holds the whole task batch locally', () async {
    api.advertisedCapabilities.remove('task_children');
    await database.batch((batch) {
      batch.insert(
        database.tasks,
        TasksCompanion.insert(
          id: 'new-parent',
          title: 'Parent',
          createdAt: _now,
          updatedAt: _now,
          syncStatus: const drift.Value('pendingCreate'),
        ),
      );
      batch.insert(
        database.tasks,
        TasksCompanion.insert(
          id: 'new-child',
          title: 'Child',
          parentTaskId: const drift.Value('new-parent'),
          createdAt: _now,
          updatedAt: _now,
          syncStatus: const drift.Value('pendingCreate'),
        ),
      );
    });

    expect(await engine.syncOnce(), SyncState.error);
    expect(api.taskUploads, isEmpty);
    expect(api.capabilityCalls, 1);
    expect(
      (await database.select(database.tasks).get()).every(
        (task) => task.syncStatus == 'pendingCreate',
      ),
      isTrue,
    );
  });

  test(
    'unavailable capabilities endpoint does not send a child create',
    () async {
      api.capabilitiesUnavailable = true;
      await database
          .into(database.tasks)
          .insert(
            TasksCompanion.insert(
              id: 'child',
              title: 'Child',
              scheduleId: const drift.Value('schedule'),
              createdAt: _now,
              updatedAt: _now,
              syncStatus: const drift.Value('pendingCreate'),
            ),
          );

      expect(await engine.syncOnce(), SyncState.error);
      expect(api.taskUploads, isEmpty);
      expect(api.capabilityCalls, 1);
      expect(
        (await database.select(database.tasks).getSingle()).syncStatus,
        'pendingCreate',
      );
    },
  );

  test('task API emits the server serde camelCase field names', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <Map<String, dynamic>>[];
    final subscription = server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      requests.add({
        'path': request.uri.path,
        'body': body.isEmpty ? null : jsonDecode(body),
      });
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        request.uri.path == '/api/v1/capabilities'
            ? '{"capabilities":["task_children","schedule_importance"]}'
            : '{"id":"child","parentTaskId":"parent","scheduleId":null,"version":1}',
      );
      await request.response.close();
    });
    final client = OrialisApiClient(
      baseUrl: 'http://${server.address.host}:${server.port}',
      deviceId: 'test',
      config: _Config(),
    );
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
    });

    await client.createTask({
      'id': 'child',
      'parent_task_id': 'parent',
      'schedule_id': null,
    }, 'mutation');
    expect(await client.capabilities(), {
      'task_children',
      'schedule_importance',
    });
    final requestBody = requests.first['body'] as Map<String, dynamic>;
    expect(requestBody['parentTaskId'], 'parent');
    expect(requestBody['scheduleId'], isNull);
    expect(requestBody.containsKey('parent_task_id'), isFalse);
    expect(requestBody.containsKey('schedule_id'), isFalse);
  });

  test(
    'child completion event rebases a parent title edit without re-completing parent',
    () async {
      await engine.applySnapshot({
        'cursor': 10,
        'projects': [],
        'milestones': [],
        'tasks': [
          {
            'id': 'parent',
            'title': 'Original title',
            'completed': false,
            'version': 1,
            'createdAt': _now,
            'updatedAt': _now,
          },
          {
            'id': 'child',
            'title': 'Child',
            'parentTaskId': 'parent',
            'completed': false,
            'version': 1,
            'createdAt': _now,
            'updatedAt': _now,
          },
        ],
        'calendarEvents': [],
      });
      await (database.update(
        database.tasks,
      )..where((row) => row.id.equals('parent'))).write(
        const TasksCompanion(
          title: drift.Value('Edited title'),
          completed: drift.Value(true),
          syncStatus: drift.Value('pendingUpdate'),
          localRevision: drift.Value(1),
        ),
      );
      await OutboxStore(database).enqueue(
        entityType: 'task',
        entityId: 'parent',
        operation: 'update',
        payloadJson:
            '{"id":"parent","title":"Edited title","completed":true,"completedAt":null,"_derivedCompletionCauseId":"child"}',
        baseVersion: 1,
        entityRevision: 1,
      );

      await engine.applySyncEvents({
        'events': [
          {
            'cursor': 11,
            'entityType': 'task',
            'entityId': 'child',
            'entityVersion': 2,
            'operation': 'upsert',
            'tombstone': false,
            'payloadJson': jsonEncode({
              'id': 'child',
              'title': 'Child',
              'parentTaskId': 'parent',
              'completed': true,
              'completedAt': _now,
              'version': 2,
              'createdAt': _now,
              'updatedAt': _now,
            }),
          },
          {
            'cursor': 12,
            'entityType': 'task',
            'entityId': 'parent',
            'entityVersion': 2,
            'operation': 'upsert',
            'tombstone': false,
            'payloadJson': jsonEncode({
              'id': 'parent',
              'title': 'Original title',
              'completed': true,
              'completedAt': _now,
              'version': 2,
              'createdAt': _now,
              'updatedAt': _now,
            }),
          },
        ],
        'nextCursor': 12,
      });

      final reconciled = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals('parent'))).getSingle();
      final queued = await (database.select(
        database.outboxMutations,
      )..where((row) => row.entityId.equals('parent'))).getSingle();
      expect(reconciled.title, 'Edited title');
      expect(reconciled.completed, isTrue);
      expect(reconciled.remoteVersion, 2);
      expect(queued.baseVersion, 2);

      expect(await engine.syncOnce(), SyncState.idle);
      final outgoing = api.taskUpdates.single;
      expect(outgoing['title'], 'Edited title');
      expect(outgoing.containsKey('completed'), isFalse);
      expect(outgoing.containsKey('completedAt'), isFalse);
      expect(outgoing.containsKey('_derivedCompletionCauseId'), isFalse);
    },
  );

  test('derived completion marker is stripped from create requests', () async {
    final task = await database
        .into(database.tasks)
        .insertReturning(
          TasksCompanion.insert(
            id: 'derived-child',
            title: 'Child',
            parentTaskId: const drift.Value('parent'),
            completed: const drift.Value(true),
            createdAt: _now,
            updatedAt: _now,
            syncStatus: const drift.Value('pendingCreate'),
          ),
        );
    await OutboxStore(database).enqueue(
      entityType: 'task',
      entityId: task.id,
      operation: 'create',
      payloadJson:
          '{"id":"derived-child","title":"Child","parentTaskId":"parent","completed":true,"_derivedCompletionCauseId":"parent"}',
      baseVersion: null,
      entityRevision: task.localRevision,
    );

    expect(await engine.syncOnce(), SyncState.idle);
    final sent = api.taskUploads.single;
    expect(sent['completed'], isTrue);
    expect(sent['parentTaskId'], 'parent');
    expect(sent.containsKey('_derivedCompletionCauseId'), isFalse);
  });

  test(
    'remote schedule deletion cascades atomically to a pending child',
    () async {
      await engine.applySnapshot({
        'cursor': 10,
        'projects': [],
        'milestones': [],
        'tasks': [
          {
            'id': 'scheduled-child',
            'title': 'Child',
            'schedule_id': 'schedule-1',
            'version': 1,
            'createdAt': _now,
            'updatedAt': _now,
          },
        ],
        'calendarEvents': [
          {
            'id': 'schedule-1',
            'title': 'Schedule',
            'startAt': _now,
            'endAt': '2026-09-24T01:00:00Z',
            'version': 1,
            'createdAt': _now,
            'updatedAt': _now,
          },
        ],
      });
      await (database.update(
        database.tasks,
      )..where((row) => row.id.equals('scheduled-child'))).write(
        const TasksCompanion(syncStatus: drift.Value('pendingUpdate')),
      );
      await OutboxStore(database).enqueue(
        entityType: 'task',
        entityId: 'scheduled-child',
        operation: 'update',
        payloadJson: '{"id":"scheduled-child","title":"Local edit"}',
        baseVersion: 1,
        entityRevision: 0,
      );

      await engine.applySyncEvents({
        'events': [
          {
            'cursor': 11,
            'entityType': 'calendar_event',
            'entityId': 'schedule-1',
            'entityVersion': 2,
            'operation': 'delete',
            'tombstone': true,
            'payloadJson': null,
            'createdAt': '2026-09-24T02:00:00Z',
          },
          {
            'cursor': 12,
            'entityType': 'task',
            'entityId': 'scheduled-child',
            'entityVersion': 2,
            'operation': 'delete',
            'tombstone': true,
            'payloadJson': null,
            'createdAt': '2026-09-24T02:00:00Z',
          },
        ],
        'nextCursor': 12,
      });

      final child = await (database.select(
        database.tasks,
      )..where((row) => row.id.equals('scheduled-child'))).getSingle();
      final mutation = await (database.select(
        database.outboxMutations,
      )..where((row) => row.entityId.equals('scheduled-child'))).getSingle();
      expect(child.deletedAt, '2026-09-24T02:00:00Z');
      expect(child.remoteVersion, 2);
      expect(child.syncStatus, 'synced');
      expect(mutation.status, OutboxStatus.acknowledged);
    },
  );
}
