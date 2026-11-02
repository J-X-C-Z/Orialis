import 'package:drift/native.dart';
import 'package:flutter/material.dart' show NavigationDestination;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';
import 'package:orialis_mobile/pages/events/events_page.dart';
import 'package:orialis_mobile/pages/shared/glass_segmented.dart';
import 'package:orialis_mobile/pages/shared/mobile_navigation.dart';

class _Config extends AppConfig {
  @override
  Future<String> deviceId() async => 'events-narrow-rail-test';
}

Future<AppDatabase> _show(
  WidgetTester tester,
  Size size, {
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final database = AppDatabase(executor: NativeDatabase.memory());
  final repository = EventRepository(database: database, config: _Config());
  for (final (i, flags) in [
    (0, (true, true)),
    (1, (false, true)),
    (2, (true, false)),
    (3, (false, false)),
  ]) {
    await repository.createTask(
      title: '象限事项 $i：需要保留文字与操作',
      important: flags.$1,
      urgent: flags.$2,
      due: '2030-11-02',
      dueTime: '12:30',
    );
  }
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => const EventsPage())],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        appConfigProvider.overrideWithValue(_Config()),
        desktopModeProvider.overrideWithValue(false),
      ],
      child: WidgetsApp.router(
        color: const Color(0xffeeeeee),
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: LuminaTheme(
            data: const LuminaThemeData(
              neumorphic: true,
              neumorphicGlass: true,
            ),
            child: OrialisMobileNavigationOverlay(
              destinations: [
                for (final label in ['今日', '事件', '聊天', '日历', '我的'])
                  NavigationDestination(
                    icon: const LuminaIcon(LuminaIcons.tasks),
                    label: label,
                  ),
              ],
              selectedIndex: 1,
              onDestinationSelected: (_) {},
              child: child!,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return database;
}

void main() {
  for (final size in [
    const Size(844, 390),
    const Size(800, 1280),
    const Size(1280, 800),
    const Size(390, 844),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'events controls fit a narrow vertical rail at $size / $scale',
        (tester) async {
          final database = await _show(tester, size, scale: scale);
          final wide = size.width >= 600;
          final modes = find.byKey(const ValueKey('events-mode-selector'));
          final filters = find.byKey(const ValueKey('events-filter-selector'));
          expect(
            tester.widget<OrialisGlassSegmented<int>>(modes).direction,
            wide ? Axis.vertical : Axis.horizontal,
          );
          if (wide) {
            final controls = find.byKey(const ValueKey('events-wide-controls'));
            expect(controls, findsOneWidget);
            expect(
              find.ancestor(
                of: controls,
                matching: find.byType(OrialisControlCard),
              ),
              findsNothing,
            );
            expect(
              find.byKey(const ValueKey('events-controls-card')),
              findsNothing,
            );
            for (final selector in [modes, filters]) {
              final control = tester.widget<OrialisGlassSegmented<dynamic>>(
                selector,
              );
              final labels = find.descendant(
                of: selector,
                matching: find.byType(Text),
              );
              expect(
                tester.widgetList<Text>(labels).map((text) => text.data),
                orderedEquals(
                  control.items.values.map(
                    (label) => label.characters.join('\n'),
                  ),
                ),
              );
              final slotHeights = <double>[];
              for (final label in labels.evaluate()) {
                final finder = find.byWidget(label.widget);
                final text = tester.widget<Text>(finder);
                final paragraph = tester.renderObject<RenderParagraph>(finder);
                expect(text.maxLines, isNull);
                expect(paragraph.didExceedMaxLines, isFalse);
                for (final box in paragraph.getBoxesForSelection(
                  TextSelection(baseOffset: 0, extentOffset: text.data!.length),
                )) {
                  expect(box.top, greaterThanOrEqualTo(-.1));
                  expect(
                    box.bottom,
                    lessThanOrEqualTo(paragraph.size.height + .1),
                  );
                  expect(box.left, greaterThanOrEqualTo(-.1));
                  expect(
                    box.right,
                    lessThanOrEqualTo(paragraph.size.width + .1),
                  );
                }
                final slot = find
                    .ancestor(
                      of: finder,
                      matching: find.byWidgetPredicate(
                        (widget) =>
                            widget is LuminaSurface && widget.onTap != null,
                      ),
                    )
                    .first;
                slotHeights.add(tester.getSize(slot).height);
              }
              expect(slotHeights, everyElement(closeTo(slotHeights.first, .1)));
            }
          } else {
            expect(
              find.byKey(const ValueKey('events-controls-card')),
              findsOneWidget,
            );
          }
          final bodyWidth = tester.getSize(find.byType(PageView)).width;
          expect(
            find.byKey(const ValueKey('adaptive-task-columns')),
            bodyWidth >= 560 * scale ? findsOneWidget : findsNothing,
          );
          final task = (await database.select(database.tasks).get()).firstWhere(
            (task) => task.title.startsWith('象限事项 0'),
          );
          final row = find.byKey(ValueKey(task.id));
          await Scrollable.ensureVisible(tester.element(row), alignment: .5);
          await tester.pumpAndSettle();
          final complete = find.descendant(
            of: row,
            matching: find.byType(LuminaCheck),
          );
          final more = find.descendant(
            of: row,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is LuminaIconButton &&
                  widget.tooltip == '管理 ${task.title}',
            ),
          );
          expect(complete.hitTestable(), findsOneWidget);
          expect(more.hitTestable(), findsOneWidget);
          expect(tester.getSize(more).width, greaterThanOrEqualTo(48));
          await tester.tap(complete);
          await tester.pumpAndSettle();
          expect(
            (await (database.select(
              database.tasks,
            )..where((t) => t.id.equals(task.id))).getSingle()).completed,
            isTrue,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await database.close();
        },
      );
    }
  }
}
