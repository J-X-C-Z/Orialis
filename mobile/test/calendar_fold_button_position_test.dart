import 'package:drift/native.dart';
import 'package:flutter/material.dart' show NavigationDestination;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/pages/calendar/calendar_page.dart';
import 'package:orialis_mobile/pages/shared/mobile_navigation.dart';
import 'package:orialis_mobile/pages/shared/navigation_glass.dart';

class _Config extends AppConfig {
  @override
  Future<String> deviceId() async => 'calendar-fold-position-test';
}

void main() {
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(1280, 800),
  ]) {
    testWidgets(
      'week fold floats inside content and clears navigation at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final db = AppDatabase(executor: NativeDatabase.memory());
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) =>
                  CalendarPage(initialDate: DateTime(2026, 11, 2)),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              appConfigProvider.overrideWithValue(_Config()),
              desktopModeProvider.overrideWithValue(false),
            ],
            child: WidgetsApp.router(
              color: const Color(0xff000000),
              routerConfig: router,
              builder: (context, child) => LuminaTheme(
                data: const LuminaThemeData(
                  neumorphic: true,
                  neumorphicGlass: true,
                ),
                child: OrialisMobileNavigationOverlay(
                  destinations: [
                    for (final label in ['今日', '事件', '聊天', '日历', '我的'])
                      NavigationDestination(
                        icon: const LuminaIcon(LuminaIcons.calendar),
                        label: label,
                      ),
                  ],
                  selectedIndex: 3,
                  onDestinationSelected: (_) {},
                  child: child!,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final fold = find.byKey(const ValueKey('calendar-fold-hours'));
        expect(fold, findsNothing);
        final selector = find.byKey(const ValueKey('calendar-view-selector'));
        await tester.tap(
          find.descendant(of: selector, matching: find.text('周')),
        );
        await tester.pumpAndSettle();
        final timeline = find.byKey(const ValueKey('calendar-week-timeline'));
        final navigation = find.byType(OrialisNavigationGlassFrame);
        final foldRect = tester.getRect(fold);
        final contentRect = tester.getRect(timeline);
        expect(foldRect.center.dx, greaterThan(contentRect.center.dx));
        expect(foldRect.center.dy, greaterThan(contentRect.center.dy));
        expect(foldRect.overlaps(tester.getRect(navigation)), isFalse);
        expect(contentRect.contains(foldRect.center), isTrue);
        expect(fold.hitTestable(), findsOneWidget);
        expect(tester.getSize(fold), const Size(48, 48));
        final column = find.byKey(
          const ValueKey('calendar-week-day-2026-11-03'),
        );
        final fullHeight = tester.getSize(column).height;
        await tester.tap(fold);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 90));
        expect(
          tester.getSize(column).height,
          allOf(lessThan(fullHeight), greaterThan(28)),
        );
        expect(tester.getRect(fold), foldRect);
        await tester.pumpAndSettle();
        expect(tester.widget<LuminaIconButton>(fold).tooltip, '展开空闲时段');
        await tester.tap(fold);
        await tester.pumpAndSettle();
        final hours = tester
            .widget<SingleChildScrollView>(
              find.byKey(const PageStorageKey('calendar-week-hours')),
            )
            .controller!;
        hours.jumpTo(hours.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(
          tester
              .getRect(find.byKey(const ValueKey('calendar-week-time-24')))
              .bottom,
          lessThan(foldRect.top),
        );
        await tester.tap(
          find.descendant(of: selector, matching: find.text('月')),
        );
        await tester.pumpAndSettle();
        expect(fold, findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await db.close();
      },
    );
  }
}
