import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/chat/application/response_action_service.dart';
import 'package:orialis_mobile/features/chat/domain/response_action_schema.dart';
import 'package:orialis_mobile/features/chat/domain/response_ui.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _agenda = <String, dynamic>{
  'id': 'study',
  'label': '学习安排',
  'title': '复习',
  'startAt': '2026-10-26T09:00:00+08:00',
  'endAt': '2026-10-26T10:00:00+08:00',
  'location': '图书馆',
};
const _schedule = {..._agenda, 'kind': 'schedule'};
Map<String, dynamic> _block([List<dynamic>? items]) => {
  'type': 'agenda',
  'items': items ?? [_agenda],
};
Map<String, dynamic> _document() => {
  'version': 1,
  'fallback': '学习安排',
  'blocks': [_block()],
};

class _SwitchingSchedules extends EventRepository {
  _SwitchingSchedules({required super.database, required super.config});
  @override
  Future<void> createCalendarEvent({
    required String title,
    required DateTime startAt,
    required DateTime endAt,
    String? description,
    String? location,
    bool allDay = false,
    bool important = false,
    int? reminderMinutes,
  }) async {
    await super.createCalendarEvent(
      title: title,
      startAt: startAt,
      endAt: endAt,
    );
    await config.setSessionUsername('switched');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  test('agenda accepts 1..12 items with no kind and strict times', () {
    expect(actionResponseTypes, contains('agenda'));
    expect(ResponseUiDocument.parse(jsonEncode(_document())), isNotNull);
    expect(validateActionResponseBlock(_block()), isTrue);
    expect(
      validateActionResponseBlock(
        _block([
          for (var i = 0; i < 12; i++) {..._agenda, 'id': 'item$i'},
        ]),
      ),
      isTrue,
    );
    for (final items in <List<dynamic>>[
      [],
      [_agenda, _agenda],
      [_schedule],
      [
        {..._agenda, 'kind': null},
      ],
      [
        for (var i = 0; i < 13; i++) {..._agenda, 'id': 'item$i'},
      ],
      [
        {..._agenda, 'title': ''},
      ],
      [
        {..._agenda, 'location': 4},
      ],
      [
        {..._agenda, 'startAt': '2026-02-30T09:00:00Z'},
      ],
      [
        {..._agenda, 'startAt': '2026-10-26T09:00:00'},
      ],
      [
        {..._agenda, 'endAt': _agenda['startAt']},
      ],
    ]) {
      expect(
        validateActionResponseBlock(_block(items)),
        isFalse,
        reason: '$items',
      );
    }
  });
  test(
    'edits preserve instant and original receipt across concurrency and reopen',
    () async {
      final db = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(db.close);
      final events = EventRepository(database: db, config: AppConfig());
      final service = ResponseActionService(events);
      final edits = {
        'title': '编辑后的日程',
        'location': '教室',
        'notes': '带笔记',
        'startAt': '2026-10-27T11:30:00+08:00',
        'endAt': '2026-10-27T12:15:00+08:00',
      };
      final receipts = await Future.wait([
        service.create('message', _schedule, overrides: edits),
        service.create(
          'message',
          _schedule,
          overrides: {...edits, 'title': '第二次'},
        ),
      ]);
      expect(receipts.map((r) => r.entityId).toSet(), hasLength(1));
      final row = await db.select(db.calendarEvents).getSingle();
      expect(row.title, isIn(['编辑后的日程', '第二次']));
      expect(
        receipts.every((r) => r.savedSchedule?['title'] == row.title),
        isTrue,
      );
      expect(row.startAt, '2026-10-27T03:30:00.000Z');
      expect(row.endAt, '2026-10-27T04:15:00.000Z');
      expect(row.description, '带笔记');
      expect(row.location, '教室');
      expect(await db.select(db.outboxMutations).get(), hasLength(1));
      final reopened = ResponseActionService(events);
      expect((await reopened.lookup('message', _schedule))!.entityId, row.id);
      expect(
        (await reopened.create(
          'message',
          _schedule,
          overrides: {'title': '再次编辑'},
        )).entityId,
        row.id,
      );
      expect(await db.select(db.calendarEvents).get(), hasLength(1));
      await (db.update(db.calendarEvents)..where((r) => r.id.equals(row.id)))
          .write(const CalendarEventsCompanion(syncStatus: Value('synced')));
      expect((await service.lookup('message', _schedule))!.message, '已同步');
      await service.create('legacy', _schedule);
      final legacy = await service.lookup('legacy', _schedule);
      expect(
        (await service.create('legacy', _schedule, overrides: edits)).entityId,
        legacy!.entityId,
      );
      expect(await db.select(db.messages).get(), isEmpty);
    },
  );
  test('invalid and forbidden overrides write nothing', () async {
    final db = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(db.close);
    final service = ResponseActionService(
      EventRepository(database: db, config: AppConfig()),
    );
    for (final edits in <Map<String, dynamic>>[
      {'id': 'changed'},
      {'kind': 'task'},
      {'label': 'changed'},
      {'due': '2026-10-27'},
      {'title': ''},
      {'startAt': '2026-10-26T24:00:00Z'},
      {'endAt': '2026-10-26T00:00:00Z'},
      {'location': 4},
    ]) {
      await expectLater(
        service.create('message', _schedule, overrides: edits),
        throwsArgumentError,
      );
    }
    expect(await db.select(db.calendarEvents).get(), isEmpty);
    expect(await db.select(db.outboxMutations).get(), isEmpty);
    expect(await db.select(db.syncMetadata).get(), isEmpty);
  });
  test(
    'identity change during schedule creation rolls back edits and receipt',
    () async {
      final db = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(db.close);
      final service = ResponseActionService(
        _SwitchingSchedules(database: db, config: AppConfig()),
      );
      await expectLater(
        service.create('message', _schedule, overrides: {'title': 'edited'}),
        throwsStateError,
      );
      expect(await db.select(db.calendarEvents).get(), isEmpty);
      expect(await db.select(db.outboxMutations).get(), isEmpty);
      expect(await db.select(db.syncMetadata).get(), isEmpty);
    },
  );
}
