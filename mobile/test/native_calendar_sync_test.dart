import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';
import 'package:orialis_mobile/features/calendar_sync/calendar_sync_controller.dart';

class _Config extends AppConfig {
  @override
  Future<String> deviceId() async => 'calendar-test-device';
}

class _Controller extends CalendarSyncController {
  _Controller({required super.database, required super.repository})
    : super(scope: 'test-account');
  @override
  bool get supported => true;
}

Map<String, dynamic> nativeEvent(String id, String title) => {
  'id': id,
  'title': title,
  'description': '',
  'location': '',
  'startAt': DateTime.utc(2026, 10, 31, 9).millisecondsSinceEpoch,
  'endAt': DateTime.utc(2026, 10, 31, 10).millisecondsSinceEpoch,
  'allDay': false,
  'reminderMinutes': 10,
  'recurring': false,
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('top.jxcz.orialis/calendar_sync');
  late AppDatabase database;
  late EventRepository repository;
  late _Controller controller;
  late Map<String, Map<String, dynamic>> native;
  late List<MethodCall> calls;
  bool deny = false, nullSnapshot = false;
  Future<List<CalendarEvent>> local() => repository.watchCalendarEvents().first;
  Future<void> settle() async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.busy, false);
  }

  Future<void> sync() async {
    await controller.sync();
    await settle();
  }

  Future<void> addLocal(String id, String title) =>
      repository.createCalendarEvent(
        eventId: id,
        title: title,
        startAt: DateTime.utc(2026, 10, 31, 9),
        endAt: DateTime.utc(2026, 10, 31, 10),
        reminderMinutes: 10,
      );
  Future<void> rename(CalendarEvent event, String title) =>
      repository.updateSchedule(
        event,
        title: title,
        startAt: DateTime.parse(event.startAt),
        endAt: DateTime.parse(event.endAt),
        description: event.description,
        location: event.location,
        reminderMinutes: event.reminderMinutes,
        reminderMinutesProvided: true,
      );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = AppDatabase(executor: NativeDatabase.memory());
    repository = EventRepository(database: database, config: _Config());
    controller = _Controller(database: database, repository: repository);
    native = {};
    calls = [];
    deny = false;
    nullSnapshot = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'requestPermission') return !deny;
          if (deny) throw PlatformException(code: 'permission_denied');
          final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
          switch (call.method) {
            case 'calendars':
              return [
                {'id': '1', 'name': 'Test calendar'},
                {'id': '2', 'name': 'Other calendar'},
              ];
            case 'events':
              return nullSnapshot
                  ? null
                  : native.values
                        .where(
                          (e) => (e['calendarId'] ?? '1') == args['calendarId'],
                        )
                        .map((e) => Map<String, dynamic>.from(e))
                        .toList();
            case 'put':
              final matching = native.values
                  .where(
                    (n) =>
                        n['key'] == args['key'] &&
                        (n['calendarId'] ?? '1') == args['calendarId'],
                  )
                  .firstOrNull;
              final id =
                  args['id'] as String? ??
                  matching?['id'] as String? ??
                  '${100 + native.length}';
              native[id] = {...args, 'id': id, 'recurring': false};
              return id;
            case 'delete':
              native.remove(args['id']);
              return null;
          }
          throw MissingPluginException(call.method);
        });
    await controller.start();
  });
  tearDown(() async {
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await database.close();
  });
  test(
    'imports and exports once and maps updates in both directions',
    () async {
      native['10'] = nativeEvent('10', 'Native event');
      await addLocal('00000000-0000-4000-8000-000000000001', 'Orialis event');
      await controller.connect('1');
      await settle();
      await sync();
      expect((await local()).map((e) => e.title).toSet(), {
        'Native event',
        'Orialis event',
      });
      expect(native, hasLength(2));
      final puts = calls.where((c) => c.method == 'put').length;
      await sync();
      expect(calls.where((c) => c.method == 'put').length, puts);
      native['10']!['title'] = 'Native edit';
      await sync();
      expect((await local()).any((e) => e.title == 'Native edit'), true);
      await rename(
        (await local()).singleWhere((e) => e.title == 'Orialis event'),
        'Orialis edit',
      );
      await settle();
      await sync();
      expect(native.values.any((e) => e['title'] == 'Orialis edit'), true);
      expect(native, hasLength(2));
    },
  );
  test('deleting on either side does not resurrect events', () async {
    native['10'] = nativeEvent('10', 'Delete native');
    native['11'] = nativeEvent('11', 'Delete local');
    await controller.connect('1');
    await settle();
    native.remove('10');
    await sync();
    expect((await local()).map((e) => e.title), ['Delete local']);
    await repository.deleteCalendarEvent((await local()).single);
    await settle();
    await sync();
    await sync();
    expect(await local(), isEmpty);
    expect(native, isEmpty);
  });
  test('simultaneous edits preserve native conflict copy', () async {
    native['10'] = nativeEvent('10', 'Original');
    await controller.connect('1');
    await settle();
    final original = (await local()).single;
    native['10']!['title'] = 'Native revision';
    await rename(original, 'Orialis revision');
    await settle();
    await sync();
    expect((await local()).map((e) => e.title).toSet(), {
      'Orialis revision',
      'Native revision（同步冲突副本）',
    });
    await sync();
    expect(await local(), hasLength(2));
    expect(native, hasLength(2));
  });
  test(
    'permission errors and incomplete snapshots never imply deletion',
    () async {
      native['10'] = nativeEvent('10', 'Keep me');
      await controller.connect('1');
      await settle();
      deny = true;
      await sync();
      expect(controller.error, isNotNull);
      expect(await local(), hasLength(1));
      deny = false;
      nullSnapshot = true;
      await sync();
      expect(controller.error, isNotNull);
      expect(await local(), hasLength(1));
      expect(native, hasLength(1));
      expect(calls.where((c) => c.method == 'delete'), isEmpty);
    },
  );
  test('disconnect and reconnect preserve imported event mapping', () async {
    native['10'] = nativeEvent('10', 'Existing system event');
    await controller.connect('1');
    await settle();
    expect(await local(), hasLength(1));
    await controller.disconnect();
    expect(controller.enabled, false);
    await controller.connect('1');
    await settle();
    await sync();
    expect(native, hasLength(1));
    expect(await local(), hasLength(1));
    expect(calls.where((c) => c.method == 'put'), isEmpty);
  });

  test(
    'switch away and back preserves each calendars original links',
    () async {
      native['10'] = nativeEvent('10', 'Existing system event');
      await controller.connect('1');
      await settle();
      await controller.connect('2');
      await settle();
      expect(native.values.where((n) => n['calendarId'] == '2'), hasLength(1));
      await controller.connect('1');
      await settle();
      await sync();
      expect(
        native.values.where((n) => (n['calendarId'] ?? '1') == '1'),
        hasLength(1),
      );
      expect(await local(), hasLength(1));
      expect(native, hasLength(2));
    },
  );

  test('three way merge distinguishes deletion, update and conflict', () {
    expect(calendarMerge('before', null, 'before'), CalendarMerge.deleteNative);
    expect(calendarMerge('before', 'before', null), CalendarMerge.deleteLocal);
    expect(calendarMerge('before', 'local', 'native'), CalendarMerge.conflict);
    expect(calendarMerge('before', 'same', 'same'), CalendarMerge.unchanged);
  });
}
