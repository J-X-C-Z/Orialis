import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/system_integration/system_snapshot.dart';
import 'package:orialis_mobile/features/system_integration/system_integration_controller.dart';

Task task(
  String id, {
  String? due = '2026-10-02',
  String? time = '12:00',
  int? minutes = 10,
  bool completed = false,
  String? deleted,
}) => Task(
  id: id,
  title: id,
  due: due,
  dueTime: time,
  reminderMinutes: minutes,
  completed: completed,
  deletedAt: deleted,
  version: 1,
  remoteVersion: 0,
  localRevision: 0,
  createdAt: '',
  updatedAt: '',
  syncStatus: 'synced',
);
CalendarEvent event(String id, String start) => CalendarEvent(
  id: id,
  title: id,
  startAt: start,
  endAt: start,
  allDay: false,
  important: false,
  reminderMinutes: 10,
  version: 1,
  remoteVersion: 0,
  localRevision: 0,
  createdAt: '',
  updatedAt: '',
  syncStatus: 'synced',
);

class FakeConfig extends AppConfig {
  String? token = 'token';
  String? user = 'alice';
  @override
  Future<String?> sessionToken() async => token;
  @override
  Future<String?> sessionUsername() async => user;
  @override
  Future<String> serverUrl() async => 'https://example.test/';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final switchBeforeEnable in [false, true]) {
    test(
      switchBeforeEnable
          ? 'account switch before first opt in cannot claim prior account rows'
          : 'first opt in cannot claim existing shared database rows',
      () async {
        SharedPreferences.setMockInitialValues({});
        final db = AppDatabase(executor: AppDatabase.inMemoryExecutor());
        final config = FakeConfig();
        const channel = MethodChannel('test/system-first-scope');
        final published = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'updateSnapshot') published.add(call);
              return null;
            });
        if (!switchBeforeEnable) {
          await db
              .into(db.tasks)
              .insert(task('private-alice').toCompanion(false));
        }
        final controller = SystemIntegrationController(
          database: db,
          config: config,
          channel: channel,
          supported: true,
        );
        await controller.start();
        if (switchBeforeEnable) {
          await db
              .into(db.tasks)
              .insert(task('private-alice').toCompanion(false));
          config.user = 'bob';
          await controller.refresh();
        }
        await controller.setEnabled(true);
        expect(controller.identityCompatible, isFalse);
        expect(published, isEmpty);
        expect(
          (await db.select(db.syncMetadata).get()).single.value,
          'identity-unverified',
        );
        await controller.dispose();
        await db.close();
      },
    );
  }
  test(
    'chat and schedule notices use scoped native adapter after opt in',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase(executor: AppDatabase.inMemoryExecutor());
      const channel = MethodChannel('test/system-notifications');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return true;
          });
      final controller = SystemIntegrationController(
        database: db,
        config: FakeConfig(),
        channel: channel,
        supported: true,
      );
      await controller.start();
      expect(await controller.previewChatMessage(), isFalse);
      await controller.setEnabled(true);
      expect(await controller.previewChatMessage(), isTrue);
      expect(
        await controller.notifyScheduleUpdate({
          'eventId': 'event-1',
          'notificationId': 'delivery-1',
          'action': 'updated',
        }),
        isTrue,
      );
      final chat = calls.singleWhere(
        (call) => call.method == 'testChatMessage',
      );
      expect((chat.arguments as Map)['conversationId'], 'default');
      expect((chat.arguments as Map)['scope'], isNotEmpty);
      expect((chat.arguments as Map).containsKey('token'), isFalse);
      expect(
        calls.any((call) => call.method == 'notifyScheduleUpdate'),
        isTrue,
      );
      await controller.dispose();
      await db.close();
    },
  );
  test(
    'native refreshes serialize even while newer snapshots arrive',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase(executor: AppDatabase.inMemoryExecutor());
      const channel = MethodChannel('test/system-serial');
      Completer<void>? gate;
      var active = 0;
      var maximum = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'updateSnapshot') {
              active++;
              if (active > maximum) maximum = active;
              await gate?.future;
              active--;
            }
            return null;
          });
      final controller = SystemIntegrationController(
        database: db,
        config: FakeConfig(),
        channel: channel,
        supported: true,
      );
      await controller.start();
      await controller.setEnabled(true);
      gate = Completer<void>();
      final first = controller.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final second = controller.refresh();
      gate.complete();
      await Future.wait([first, second]);
      expect(maximum, 1);
      await controller.dispose();
      await db.close();
    },
  );
  test('filters completed deleted expired negative and date-only tasks', () {
    final s = buildSystemSnapshot(
      scope: 'x',
      now: DateTime(2026, 10, 2, 11),
      tasks: [
        task('ok'),
        task('done', completed: true),
        task('deleted', deleted: 'x'),
        task('date', time: null),
        task('past', due: '2026-10-01', time: '10:00'),
        task('negative', minutes: -1),
      ],
      events: [],
    );
    final reminders = s['reminders'] as List;
    expect(reminders.length, 1);
    expect(
      reminders.single['fireAtMillis'],
      DateTime(2026, 10, 2, 11, 50).millisecondsSinceEpoch,
    );
    expect(taskDeadline(task('bad', due: '2026-02-30')), isNull);
    expect(taskDeadline(task('bad', time: '25:00')), isNull);
  });
  test('ISO offsets retain correct instant and schedule routes encode IDs', () {
    final s = buildSystemSnapshot(
      scope: 'x',
      now: DateTime.utc(2026, 10, 2, 1),
      tasks: [],
      events: [event('a/b ?', '2026-10-02T12:00:00+08:00')],
    );
    final reminder = (s['reminders'] as List).single;
    expect(
      reminder['fireAtMillis'],
      DateTime.utc(2026, 10, 2, 3, 50).millisecondsSinceEpoch,
    );
    expect(reminder['route'], contains('a%2Fb%20%3F'));
  });
  test('sorts deterministically and rolls widget date at midnight', () {
    final s = buildSystemSnapshot(
      scope: 'x',
      now: DateTime(2026, 10, 2),
      tasks: [task('b'), task('a')],
      events: [],
    );
    expect((s['reminders'] as List).map((r) => r['key']), ['task:a', 'task:b']);
    final next = buildSystemSnapshot(
      scope: 'x',
      now: DateTime(2026, 10, 3),
      tasks: [task('a')],
      events: [],
    );
    expect((next['widget'] as Map)['date'], '2026-10-03');
    expect((next['widget'] as Map)['lines'], isEmpty);
  });
  test(
    'requires opt in and clears after logout or a different identity',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase(executor: AppDatabase.inMemoryExecutor());
      final config = FakeConfig();
      const channel = MethodChannel('test/system');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      final controller = SystemIntegrationController(
        database: db,
        config: config,
        channel: channel,
        supported: true,
      );
      await controller.start();
      expect(calls.where((c) => c.method == 'updateSnapshot'), isEmpty);
      await controller.setEnabled(true);
      expect(controller.identityCompatible, isTrue);
      expect(calls.last.method, 'updateSnapshot');
      calls.clear();
      config.token = null;
      await controller.refresh();
      expect(calls.last.method, 'clear');
      config.token = 'new-token';
      config.user = 'bob';
      await controller.setEnabled(true);
      expect(controller.identityCompatible, isFalse);
      expect(calls.where((c) => c.method == 'updateSnapshot'), isEmpty);
      await controller.dispose();
      await db.close();
    },
  );
  test(
    'cold anonymous shortcut works before opt in but not a detail route',
    () async {
      SharedPreferences.setMockInitialValues({});
      for (final route in ['/calendar', '/calendar/schedule/private']) {
        final db = AppDatabase(executor: AppDatabase.inMemoryExecutor());
        final config = FakeConfig()..token = null;
        final opened = <String>[];
        final channel = MethodChannel('test/shortcut/$route');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              channel,
              (call) async => call.method == 'initialRoute'
                  ? {'route': route, 'scope': ''}
                  : null,
            );
        final controller = SystemIntegrationController(
          database: db,
          config: config,
          channel: channel,
          supported: true,
          onRoute: opened.add,
        );
        await Future.wait([controller.start(), controller.start()]);
        expect(opened, route == '/calendar' ? ['/calendar'] : isEmpty);
        await controller.dispose();
        await db.close();
      }
    },
  );
  test('invalid native snapshot clears previously projected data', () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase(executor: AppDatabase.inMemoryExecutor());
    const channel = MethodChannel('test/invalid');
    final calls = <String>[];
    var reject = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (reject && call.method == 'updateSnapshot') {
            throw PlatformException(code: 'invalid_snapshot');
          }
          return null;
        });
    final controller = SystemIntegrationController(
      database: db,
      config: FakeConfig(),
      channel: channel,
      supported: true,
    );
    await controller.start();
    await controller.setEnabled(true);
    calls.clear();
    reject = true;
    await controller.refresh();
    expect(calls, ['updateSnapshot', 'clear']);
    await controller.dispose();
    await db.close();
  });
  test(
    'A to B to A permanently distrusts shared database projection',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase(executor: AppDatabase.inMemoryExecutor());
      final config = FakeConfig();
      const channel = MethodChannel('test/tainted');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return null;
          });
      final controller = SystemIntegrationController(
        database: db,
        config: config,
        channel: channel,
        supported: true,
      );
      await controller.start();
      await controller.setEnabled(true);
      expect(controller.identityCompatible, isTrue);
      config.user = 'bob';
      await controller.refresh();
      expect(
        (await db.select(db.syncMetadata).get()).single.value,
        'identity-unverified',
      );
      calls.clear();
      config.user = 'alice';
      await controller.setEnabled(false);
      await controller.setEnabled(true);
      expect(controller.identityCompatible, isFalse);
      expect(calls.where((c) => c == 'updateSnapshot'), isEmpty);
      expect(
        (await db.select(db.syncMetadata).get()).single.value,
        'identity-unverified',
      );
      await controller.dispose();
      await db.close();
    },
  );
  test('recently fired rows survive resume unchanged for 24 hours', () {
    final tasks = [task('recent')];
    final events = [
      event('recent', DateTime(2026, 10, 2, 12).toIso8601String()),
    ];
    Map<String, Object?> snapshot(
      DateTime now, {
      List<Task>? changedTasks,
      List<CalendarEvent>? changedEvents,
    }) => buildSystemSnapshot(
      scope: 'x',
      now: now,
      tasks: changedTasks ?? tasks,
      events: changedEvents ?? events,
    );
    final before = snapshot(DateTime(2026, 10, 2, 11, 49));
    final after = snapshot(DateTime(2026, 10, 2, 12, 1));
    expect(after['reminders'], before['reminders']);
    expect(
      (snapshot(DateTime(2026, 10, 3, 11, 50))['reminders'] as List).length,
      2,
    );
    expect(snapshot(DateTime(2026, 10, 3, 11, 51))['reminders'], isEmpty);
    final completed = snapshot(
      DateTime(2026, 10, 2, 12, 1),
      changedTasks: [task('recent', completed: true)],
    );
    expect((completed['reminders'] as List).map((row) => row['key']), [
      'schedule:recent',
    ]);
    final deleted = snapshot(
      DateTime(2026, 10, 2, 12, 1),
      changedTasks: [task('recent', deleted: 'x')],
      changedEvents: [],
    );
    expect(deleted['reminders'], isEmpty);
    final edited = snapshot(
      DateTime(2026, 10, 2, 12, 1),
      changedTasks: [task('recent', time: '13:00')],
    );
    expect(edited['reminders'], isNot(equals(before['reminders'])));
  });
}
