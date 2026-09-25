import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:uuid/uuid.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';
import 'package:orialis_mobile/features/events/data/schedule_repository.dart';
import 'package:orialis_mobile/features/events/data/task_repository.dart';

const _server = String.fromEnvironment('ORIALIS_TEST_SERVER');

class _LiveConfig extends AppConfig {
  _LiveConfig(this.url) : _deviceId = 'subevent-live-${const Uuid().v7()}';

  final String url;
  final String _deviceId;
  String? _token;

  @override
  Future<String> serverUrl() async => url;

  @override
  Future<String> deviceId() async => _deviceId;

  @override
  Future<String?> sessionToken() async => _token;

  @override
  Future<void> setSessionToken(String token) async {
    _token = token;
  }

  @override
  Future<void> clearSessionToken() async {
    _token = null;
  }
}

bool _isLoopback(String host) {
  final normalized = host.toLowerCase();
  if (normalized == 'localhost' ||
      normalized == '::1' ||
      normalized == '[::1]') {
    return true;
  }
  final octets = normalized.split('.');
  return octets.length == 4 &&
      octets.first == '127' &&
      octets.every((part) {
        final value = int.tryParse(part);
        return value != null && value >= 0 && value <= 255;
      });
}

void main() {
  test(
    'live server syncs task cascades, tombstones, and schedule attachments',
    () async {
      final uri = Uri.tryParse(_server);
      expect(uri, isNotNull, reason: 'ORIALIS_TEST_SERVER must be a URL');
      expect(
        _isLoopback(uri!.host),
        isTrue,
        reason: 'live sync tests may only target a localhost server',
      );
      expect(uri.hasAuthority, isTrue);

      final config = _LiveConfig(_server);
      final database = AppDatabase(executor: AppDatabase.inMemoryExecutor());
      final api = OrialisApiClient(
        baseUrl: _server,
        deviceId: await config.deviceId(),
        config: config,
      );
      try {
        await api.health();
        final username =
            'live-${const Uuid().v7().replaceAll('-', '').substring(0, 20)}';
        final registrationDio = Dio(
          BaseOptions(
            baseUrl: _server,
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 45),
          ),
        );
        final registration = await registrationDio.post<Map<String, dynamic>>(
          '/api/v1/auth/register',
          data: {'username': username, 'password': 'integration-test-password'},
        );
        final session = SessionResponse.fromJson(registration.data!);
        await config.setSessionToken(session.accessToken);
        registrationDio.close(force: true);
        expect(session.userId, isNotEmpty);
        expect(await config.sessionToken(), session.accessToken);

        final events = EventRepository(database: database, config: config);
        final tasks = TaskRepository(delegate: events);
        final schedules = ScheduleRepository(delegate: events);
        final engine = SyncEngine(
          database: database,
          config: config,
          apiClient: api,
        );

        Future<void> syncIdle(String step) async {
          expect(await engine.syncOnce(), SyncState.idle, reason: step);
        }

        Future<Task> localTask(String id) => (database.select(
          database.tasks,
        )..where((row) => row.id.equals(id))).getSingle();

        await tasks.create(title: 'Live parent');
        final parent = (await database.select(database.tasks).getSingle());
        await tasks.create(title: 'Live child A', parentTaskId: parent.id);
        await tasks.create(title: 'Live child B', parentTaskId: parent.id);
        final children =
            await (database.select(database.tasks)
                  ..where((row) => row.parentTaskId.equals(parent.id))
                  ..orderBy([(row) => OrderingTerm(expression: row.title)]))
                .get();
        expect(children, hasLength(2));
        final childA = children[0];
        final childB = children[1];
        await syncIdle('create parent and two children');

        await tasks.complete(await localTask(parent.id), true);
        await syncIdle('complete parent and cascade to children');
        var storedParent = await localTask(parent.id);
        var storedChildA = await localTask(childA.id);
        var storedChildB = await localTask(childB.id);
        expect(storedParent.completed, isTrue);
        expect(storedChildA.completed, isTrue);
        expect(storedChildB.completed, isTrue);

        await tasks.complete(storedChildA, false);
        await syncIdle('reopen a child and its parent');
        storedParent = await localTask(parent.id);
        storedChildA = await localTask(childA.id);
        storedChildB = await localTask(childB.id);
        expect(storedParent.completed, isFalse);
        expect(storedChildA.completed, isFalse);
        expect(storedChildB.completed, isTrue);

        await tasks.complete(storedChildA, true);
        await syncIdle('complete the remaining child and auto-complete parent');
        expect((await localTask(parent.id)).completed, isTrue);
        expect((await localTask(childA.id)).completed, isTrue);
        expect((await localTask(childB.id)).completed, isTrue);

        final parentAndChildren = [parent.id, childA.id, childB.id];
        await tasks.delete(await localTask(parent.id));
        await syncIdle('delete parent and cascade child tombstones');
        for (final id in parentAndChildren) {
          expect((await localTask(id)).deletedAt, isNotNull, reason: id);
        }

        await schedules.create(
          title: 'Important live schedule',
          startAt: DateTime.now().toUtc().add(const Duration(days: 1)),
          endAt: DateTime.now().toUtc().add(const Duration(days: 1, hours: 1)),
          important: true,
        );
        final schedule = await database
            .select(database.calendarEvents)
            .getSingle();
        await tasks.create(title: 'Schedule child', scheduleId: schedule.id);
        final scheduleChild = await (database.select(
          database.tasks,
        )..where((row) => row.scheduleId.equals(schedule.id))).getSingle();
        await syncIdle('create important schedule and attached task');

        final remoteBeforeScheduleDelete = await api.syncSnapshot();
        final remoteSchedules =
            (remoteBeforeScheduleDelete['calendarEvents'] as List<dynamic>)
                .cast<Map<String, dynamic>>();
        final remoteTasks =
            (remoteBeforeScheduleDelete['tasks'] as List<dynamic>)
                .cast<Map<String, dynamic>>();
        expect(
          remoteSchedules.singleWhere(
            (row) => row['id'] == schedule.id,
          )['important'],
          isTrue,
        );
        expect(
          remoteTasks.singleWhere(
            (row) => row['id'] == scheduleChild.id,
          )['scheduleId'],
          schedule.id,
        );

        await schedules.delete(schedule);
        await syncIdle('delete schedule and cascade attached task tombstone');
        expect(
          (await (database.select(
            database.calendarEvents,
          )..where((row) => row.id.equals(schedule.id))).getSingle()).deletedAt,
          isNotNull,
        );
        expect((await localTask(scheduleChild.id)).deletedAt, isNotNull);

        final remoteAfterDelete = await api.syncSnapshot();
        expect(
          (remoteAfterDelete['calendarEvents'] as List<dynamic>).where(
            (row) => row['id'] == schedule.id,
          ),
          isEmpty,
        );
        expect(
          (remoteAfterDelete['tasks'] as List<dynamic>).where(
            (row) =>
                parentAndChildren.contains(row['id']) ||
                row['id'] == scheduleChild.id,
          ),
          isEmpty,
        );
        final syncEvents = await api.syncEvents(after: 0);
        final tombstones = (syncEvents['events'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .where((event) => event['tombstone'] == true)
            .map((event) => '${event['entityType']}:${event['entityId']}')
            .toSet();
        expect(
          tombstones,
          containsAll([
            for (final id in parentAndChildren) 'task:$id',
            'calendar_event:${schedule.id}',
            'task:${scheduleChild.id}',
          ]),
        );
      } finally {
        try {
          await api.logout();
        } catch (_) {
          await config.clearSessionToken();
        }
        await database.close();
      }
    },
    skip: _server.isEmpty ? 'Set ORIALIS_TEST_SERVER to a localhost URL' : null,
  );
}
