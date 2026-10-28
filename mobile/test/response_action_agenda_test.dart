import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/chat/application/response_action_service.dart';
import 'package:orialis_mobile/features/chat/presentation/response_action_blocks.dart';
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
Map<String, dynamic> _block([List<dynamic>? items]) => {
  'type': 'agenda',
  'items': items ?? [_agenda],
};
Widget _host(
  Widget child, {
  ResponseActionService? service,
  double scale = 1,
}) => ProviderScope(
  overrides: [
    if (service != null) ...[
      responseActionServiceProvider.overrideWithValue(service),
      appConfigProvider.overrideWithValue(service.events.config),
    ],
  ],
  child: MaterialApp(
    builder: (context, child) => LuminaTheme(
      highPerformanceMode: true,
      child: MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
    ),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);
Widget _card() =>
    ResponseActionBlock(data: _block(), enabled: true, scope: 'message');
Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.pumpAndSettle();
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is LuminaTextField && w.label == label),
  matching: find.byType(EditableText),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  testWidgets(
    'cancel zero writes; edit confirm, restore receipt and live sync',
    (tester) async {
      final db = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(db.close);
      final service = ResponseActionService(
        EventRepository(database: db, config: AppConfig()),
      );
      await tester.pumpWidget(_host(_card(), service: service));
      await tester.pumpAndSettle();
      expect(find.textContaining('时长：1小时0分钟'), findsOneWidget);
      expect(find.textContaining('设备本地时区'), findsOneWidget);
      await _tap(tester, find.text('确认添加日程'));
      await tester.enterText(_field('标题'), '取消的标题');
      await _tap(tester, find.text('取消'));
      for (final query in [
        db.select(db.calendarEvents),
        db.select(db.outboxMutations),
        db.select(db.syncMetadata),
        db.select(db.messages),
      ]) {
        expect(await tester.runAsync(query.get), isEmpty);
      }
      await _tap(tester, find.text('确认添加日程'));
      await tester.enterText(_field('标题'), '编辑的标题');
      await _tap(tester, find.byKey(const ValueKey('schedule-end-date')));
      await _tap(tester, find.text('27'));
      final strings = LuminaLocalizations.of(
        tester.element(find.byType(LuminaDialog).last),
      );
      await _tap(tester, find.text(strings.confirm).last);
      await _tap(tester, find.byKey(const ValueKey('schedule-end-time')));
      await _tap(
        tester,
        find.byWidgetPredicate(
          (w) => w is LuminaIconButton && w.tooltip == strings.increaseHour,
        ),
      );
      await _tap(tester, find.text(strings.confirm).last);
      await tester.enterText(_field('地点'), '新地点');
      await tester.enterText(_field('备注'), '新备注');
      await _tap(tester, find.text('确认添加'));
      final row = (await tester.runAsync(
        () => db.select(db.calendarEvents).getSingle(),
      ))!;
      final initial = DateTime.parse(_agenda['endAt'] as String).toLocal();
      final expected = DateTime(
        initial.year,
        initial.month,
        27,
        (initial.hour + 1) % 24,
        initial.minute,
      ).toUtc();
      expect(DateTime.parse(row.endAt), expected);
      expect(row.startAt, '2026-10-26T01:00:00.000Z');
      expect(row.title, '编辑的标题');
      expect(row.location, '新地点');
      expect(row.description, '新备注');
      expect(find.text('已保存在本机，等待同步'), findsOneWidget);
      expect(find.textContaining('编辑的标题'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_host(_card(), service: service));
      await tester.pumpAndSettle();
      expect(find.text('确认添加日程'), findsNothing);
      expect(find.textContaining('编辑的标题'), findsOneWidget);
      expect(
        await tester.runAsync(() => db.select(db.outboxMutations).get()),
        hasLength(1),
      );
      await tester.runAsync(
        () => (db.update(db.calendarEvents)..where((r) => r.id.equals(row.id)))
            .write(const CalendarEventsCompanion(syncStatus: Value('synced'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('已同步'), findsOneWidget);
      expect(
        await tester.runAsync(() => db.select(db.messages).get()),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('identity change while editor open prevents write', (
    tester,
  ) async {
    final db = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(db.close);
    final config = AppConfig();
    final service = ResponseActionService(
      EventRepository(database: db, config: config),
    );
    await tester.pumpWidget(_host(_card(), service: service));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('确认添加日程'));
    await config.setSessionUsername('other');
    await _tap(tester, find.text('确认添加'));
    expect(find.text('登录已改变，请重新打开此消息'), findsOneWidget);
    expect(
      await tester.runAsync(() => db.select(db.calendarEvents).get()),
      isEmpty,
    );
    expect(
      await tester.runAsync(() => db.select(db.outboxMutations).get()),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
