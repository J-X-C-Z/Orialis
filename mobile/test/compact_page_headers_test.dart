import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';
import 'package:orialis_mobile/pages/calendar/calendar_page.dart';
import 'package:orialis_mobile/pages/events/events_page.dart';
import 'package:orialis_mobile/pages/shared/compact_header.dart';

class _Config extends AppConfig {
  @override
  Future<String> deviceId() async => 'compact-header-test';
}

Widget _host(AppDatabase database, Widget page, double scale, GlobalKey key) {
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => page)],
  );
  addTearDown(router.dispose);
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(database),
      appConfigProvider.overrideWithValue(_Config()),
      desktopModeProvider.overrideWithValue(false),
    ],
    child: WidgetsApp.router(
      routerConfig: router,
      color: const Color(0xffe9eef4),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: LuminaTheme(
          highPerformanceMode: true,
          data: const LuminaThemeData(neumorphic: true, neumorphicGlass: true),
          child: DefaultTextStyle(
            style: const LuminaTextTheme(LuminaColors(dark: false)).bodyMedium,
            child: RepaintBoundary(key: key, child: child!),
          ),
        ),
      ),
    ),
  );
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void _oneRow(WidgetTester tester, Finder first, Finder second) {
  final a = tester.getRect(first);
  final b = tester.getRect(second);
  expect(a.center.dy, closeTo(b.center.dy, 1));
  expect(a.height, greaterThanOrEqualTo(44));
  expect(b.height, greaterThanOrEqualTo(44));
  expect(find.byType(OrialisCompactHeader), findsOneWidget);
}

Future<void> _preview(WidgetTester tester, GlobalKey key, String name) async {
  final directory = Platform.environment['HEADER_PREVIEW_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File('$directory/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
  });
}

Future<void> _fonts(WidgetTester tester) async {
  final font = File('/System/Library/Fonts/STHeiti Light.ttc');
  if (Platform.environment['HEADER_PREVIEW_DIR'] == null || !font.existsSync())
    return;
  await tester.runAsync(() async {
    final bytes = ByteData.sublistView(await font.readAsBytes());
    for (final family in ['Ahem', 'sans-serif']) {
      await (FontLoader(family)..addFont(Future.value(bytes))).load();
    }
  });
}

void main() {
  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'calendar keeps one row and date navigation at $width / $scale',
        (tester) async {
          await _fonts(tester);
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final database = AppDatabase(executor: NativeDatabase.memory());
          final key = GlobalKey();
          await tester.pumpWidget(
            _host(
              database,
              CalendarPage(initialDate: DateTime(2026, 11, 1)),
              scale,
              key,
            ),
          );
          await tester.pumpAndSettle();
          final modes = find.byKey(const ValueKey('calendar-view-selector'));
          final date = find.byKey(const ValueKey('calendar-date-selector'));
          _oneRow(tester, modes, date);
          expect(find.byType(LuminaDateNavigator), findsNothing);
          if (width == 390 && scale == 1)
            await _preview(tester, key, 'calendar');
          await _tap(
            tester,
            find.byWidgetPredicate(
              (w) => w is LuminaIconButton && w.tooltip == '下一月',
            ),
          );
          expect(find.text('2026/12'), findsOneWidget);
          await _tap(
            tester,
            find.descendant(of: modes, matching: find.text('周')),
          );
          await _tap(
            tester,
            find.byWidgetPredicate(
              (w) => w is LuminaIconButton && w.tooltip == '下一周',
            ),
          );
          expect(find.text('12月8日'), findsOneWidget);
          await _tap(
            tester,
            find.descendant(of: modes, matching: find.text('日')),
          );
          await _tap(
            tester,
            find.byWidgetPredicate(
              (w) => w is LuminaIconButton && w.tooltip == '上一天',
            ),
          );
          expect(find.text('12月7日'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await database.close();
        },
      );

      testWidgets(
        'events keeps modes and working filters in one row at $width / $scale',
        (tester) async {
          await _fonts(tester);
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final database = AppDatabase(executor: NativeDatabase.memory());
          final repository = EventRepository(
            database: database,
            config: _Config(),
          );
          await repository.createTask(
            title: '准备实验',
            important: true,
            urgent: true,
          );
          await repository.createTask(
            title: '已完成报告',
            important: true,
            urgent: true,
          );
          await (database.update(database.tasks)
                ..where((t) => t.title.equals('已完成报告')))
              .write(const TasksCompanion(completed: Value(true)));
          final key = GlobalKey();
          await tester.pumpWidget(
            _host(database, const EventsPage(), scale, key),
          );
          await tester.pumpAndSettle();
          final header = find.byKey(const ValueKey('events-compact-header'));
          final modes = find.descendant(of: header, matching: find.text('四象限'));
          final filters = find.byKey(const ValueKey('events-filter-selector'));
          // Label and filter are vertically centered; the enclosing mode has a 44px tap target.
          expect(
            tester.getCenter(modes).dy,
            closeTo(tester.getCenter(filters).dy, 1),
          );
          expect(find.byType(OrialisCompactHeader), findsOneWidget);
          expect(find.text('准备实验'), findsOneWidget);
          if (width == 390 && scale == 1) await _preview(tester, key, 'events');
          await _tap(
            tester,
            find.descendant(of: filters, matching: find.text('已完成')),
          );
          expect(find.text('已完成报告'), findsOneWidget);
          expect(find.text('准备实验'), findsNothing);
          await _tap(
            tester,
            find.descendant(of: header, matching: find.text('项目')),
          );
          expect(
            find.byKey(const ValueKey('events-filter-selector')),
            findsNothing,
          );
          await _tap(
            tester,
            find.descendant(of: header, matching: find.text('四象限')),
          );
          expect(find.text('已完成报告'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await database.close();
        },
      );
    }
  }
}
