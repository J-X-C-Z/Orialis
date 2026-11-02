import 'package:flutter/material.dart' as m;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/pages/shared/adaptive_layout.dart';
import 'package:orialis_mobile/pages/shared/navigation_glass.dart';
import 'package:orialis_mobile/pages/shared/mobile_navigation.dart';
import 'package:orialis_mobile/pages/shell/orialis_shell.dart';

class _Page extends StatefulWidget {
  const _Page(this.index);
  final int index;
  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  int count = 0;
  @override
  Widget build(BuildContext context) {
    final layout = OrialisAdaptiveLayout.maybeOf(context)!;
    return SizedBox.expand(
      key: ValueKey('page-${widget.index}'),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('page ${widget.index}: $count'),
            Text('wide=${layout.wide},tablet=${layout.tablet}'),
            Text('bottom=${LuminaNavigationInset.of(context)}'),
            LuminaButton(
              onPressed: () => setState(() => count++),
              child: const Text('增加'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<GoRouter> _mount(
  WidgetTester tester,
  Size size, {
  double scale = 1,
  EdgeInsets padding = EdgeInsets.zero,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    initialLocation: '/page0',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => OrialisShell(navigationShell: shell),
        branches: List.generate(
          5,
          (index) => StatefulShellBranch(
            routes: [
              GoRoute(path: '/page$index', builder: (_, _) => _Page(index)),
            ],
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    WidgetsApp.router(
      color: const Color(0xff000000),
      routerConfig: router,
      localizationsDelegates: const [m.DefaultMaterialLocalizations.delegate],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale), padding: padding),
        child: LuminaTheme(
          data: const LuminaThemeData(neumorphic: true, neumorphicGlass: true),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  for (final size in [
    const Size(844, 390),
    const Size(1280, 800),
    const Size(800, 1280),
  ]) {
    testWidgets('wide mobile shell uses a frosted right rail at $size', (
      tester,
    ) async {
      await _mount(tester, size);
      final rail = find.byKey(const ValueKey('adaptive-navigation-rail'));
      expect(rail, findsOneWidget);
      final railRect = tester.getRect(rail);
      final pageRect = tester.getRect(find.byKey(const ValueKey('page-0')));
      expect(railRect.left, greaterThanOrEqualTo(pageRect.right));
      expect(find.text('bottom=0.0'), findsOneWidget);
      expect(
        find.descendant(
          of: rail,
          matching: find.byType(OrialisNavigationGlassFrame),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<SingleChildScrollView>(rail).scrollDirection,
        Axis.vertical,
      );
      expect(find.byType(OrialisNavigationSelection), findsOneWidget);
      expect(find.byType(OrialisNavigationGlassLens), findsOneWidget);
      final lens = find.byType(OrialisNavigationGlassLens);
      expect(
        tester.widget<OrialisNavigationGlassLens>(lens).shaderRefraction,
        isFalse,
      );
      expect(
        find.descendant(of: lens, matching: find.byType(ImageFiltered)),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('nav-glass-slider')), findsOneWidget);
      expect(
        find.text('wide=true,tablet=${size.shortestSide >= 600}'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('日历'));
      final target = find
          .ancestor(
            of: find.text('日历'),
            matching: find.byWidgetPredicate(
              (widget) => widget is LuminaSurface && widget.onTap != null,
            ),
          )
          .first;
      expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
      await tester.tap(find.text('日历'));
      await tester.pumpAndSettle();
      expect(find.text('page 3: 0'), findsOneWidget);
      expect(
        tester
            .widget<OrialisNavigationSelection>(
              find.byType(OrialisNavigationSelection),
            )
            .index,
        3,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'resizing through split-screen breakpoint preserves branches and page state',
    (tester) async {
      await _mount(tester, const Size(390, 844));
      expect(
        find.byKey(const ValueKey('adaptive-navigation-rail')),
        findsNothing,
      );
      await tester.tap(find.text('增加'));
      await tester.tap(find.text('日历'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('增加'));
      await tester.pumpAndSettle();
      final page = tester.element(find.byKey(const ValueKey('page-3')));
      for (final size in [
        const Size(844, 390),
        const Size(599, 800),
        const Size(600, 800),
        const Size(390, 844),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('adaptive-navigation-rail')),
          size.width >= 600 ? findsOneWidget : findsNothing,
        );
        expect(
          tester
              .widget<OrialisNavigationGlassLens>(
                find.byType(OrialisNavigationGlassLens),
              )
              .shaderRefraction,
          size.width < 600,
        );
        expect(find.text('page 3: 1'), findsOneWidget);
        expect(
          tester.element(find.byKey(const ValueKey('page-3'))),
          same(page),
        );
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('今日'));
      await tester.pumpAndSettle();
      expect(find.text('page 0: 1'), findsOneWidget);
    },
  );

  testWidgets(
    'vertical navigation keeps labels upright and drags the same glass lens',
    (tester) async {
      var ticks = 0;
      final previous = LuminaHaptics.effectHandler;
      LuminaHaptics.effectHandler = (effect) async {
        if (effect == 'selection') ticks++;
      };
      addTearDown(() => LuminaHaptics.effectHandler = previous);
      await _mount(tester, const Size(844, 390));
      expect(find.byType(m.NavigationRail), findsNothing);
      final today = find.text('今日');
      final calendar = find.text('日历');
      final transform = tester
          .renderObject<RenderBox>(today)
          .getTransformTo(null);
      expect(transform.storage[0], greaterThan(0));
      expect(transform.storage[5], greaterThan(0));
      expect(transform.storage[1], closeTo(0, 1e-8));
      expect(transform.storage[4], closeTo(0, 1e-8));
      expect(
        tester.getCenter(today).dy,
        lessThan(tester.getCenter(calendar).dy),
      );
      expect(
        tester.getCenter(today).dx,
        closeTo(tester.getCenter(calendar).dx, .1),
      );
      final lens = find.byKey(const ValueKey('nav-glass-slider'));
      final start = tester.getCenter(lens).dy;
      final gesture = await tester.startGesture(tester.getCenter(today));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(tester.getCenter(calendar));
      await tester.pump();
      expect(tester.getCenter(lens).dy, greaterThan(start));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('page 3: 0'), findsOneWidget);
      expect(ticks, 1);
      final selectedSlot = find
          .ancestor(
            of: calendar,
            matching: find.byWidgetPredicate(
              (widget) => widget is LuminaSurface && widget.onTap != null,
            ),
          )
          .first;
      expect(
        tester.getCenter(lens).dy,
        closeTo(tester.getCenter(selectedSlot).dy, 1),
      );
      final cancelled = await tester.startGesture(tester.getCenter(calendar));
      await tester.pump(const Duration(milliseconds: 600));
      await cancelled.moveTo(tester.getCenter(today));
      await cancelled.cancel();
      await tester.pumpAndSettle();
      expect(find.text('page 3: 0'), findsOneWidget);
      expect(ticks, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('right navigation consumes the right safe area exactly once', (
    tester,
  ) async {
    await _mount(
      tester,
      const Size(844, 390),
      padding: const EdgeInsets.only(left: 30, right: 40),
    );
    final page = find.byKey(const ValueKey('page-0'));
    final rail = find.byKey(const ValueKey('adaptive-navigation-rail'));
    expect(tester.getRect(page).right, closeTo(844 - 88 - 40, .1));
    expect(tester.getRect(rail).right, lessThanOrEqualTo(844 - 40));
    expect(MediaQuery.paddingOf(tester.element(page)).right, 0);
    expect(MediaQuery.paddingOf(tester.element(page)).left, 30);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rotated navigation slot and semantic centers select the same destination',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await _mount(tester, const Size(844, 390));
      const labels = ['今日', '事件', '聊天', '日历', '我的'];
      for (final index in [3, 1, 4, 2, 0]) {
        final label = labels[index];
        final text = find.text(label);
        await tester.ensureVisible(text);
        await tester.pumpAndSettle();
        final slot = find
            .ancestor(
              of: text,
              matching: find.byWidgetPredicate(
                (widget) => widget is LuminaSurface && widget.onTap != null,
              ),
            )
            .first;
        final semantic = find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.label == label,
        );
        var node = tester.getSemantics(semantic);
        var bounds = node.rect;
        while (true) {
          if (node.transform != null) {
            bounds = MatrixUtils.transformRect(node.transform!, bounds);
          }
          if (node.parent == null) break;
          node = node.parent!;
        }
        final center = tester.getCenter(slot);
        expect(bounds.center.dx, closeTo(center.dx, 1));
        expect(bounds.center.dy, closeTo(center.dy, 1));
        await tester.tapAt(bounds.center);
        await tester.pumpAndSettle();
        expect(find.text('page $index: 0'), findsOneWidget);
        await tester.tapAt(tester.getCenter(slot));
        await tester.pumpAndSettle();
        expect(find.text('page $index: 0'), findsOneWidget);
      }
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wide keyboard hides rail and consumes bottom inset once', (
    tester,
  ) async {
    await _mount(tester, const Size(844, 390));
    final page = find.byKey(const ValueKey('page-0'));
    final element = tester.element(page);
    final height = tester.getSize(page).height;
    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('adaptive-navigation-rail')),
      findsNothing,
    );
    expect(tester.getSize(page).height, height - 200);
    expect(tester.getRect(page).left, 0);
    expect(MediaQuery.viewInsetsOf(tester.element(page)).bottom, 0);
    expect(tester.element(page), same(element));
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('adaptive-navigation-rail')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('short landscape rail scrolls at double text size', (
    tester,
  ) async {
    await _mount(tester, const Size(844, 320), scale: 2);
    final rail = find.byKey(const ValueKey('adaptive-navigation-rail'));
    expect(rail, findsOneWidget);
    await tester.ensureVisible(find.text('我的'));
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OrialisNavigationSelection>(
            find.byType(OrialisNavigationSelection),
          )
          .index,
      4,
    );
    expect(find.text('page 4: 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
