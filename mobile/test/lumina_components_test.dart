import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/app/design/design_components.dart';

Widget harness(
  Widget child, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool reduced = false,
  bool opaque = false,
  bool highPerformance = true,
  EdgeInsets insets = EdgeInsets.zero,
}) => WidgetsApp(
  color: const Color(0xff000000),
  builder: (context, _) => MediaQuery(
    data: MediaQueryData(
      size: const Size(400, 800),
      textScaler: TextScaler.linear(scale),
      disableAnimations: reduced,
      viewInsets: insets,
    ),
    child: LuminaTheme(
      brightness: brightness,
      reduceTransparency: opaque,
      highPerformanceMode: highPerformance,
      child: DefaultTextStyle(
        style: LuminaTextTheme(
          LuminaColors(dark: brightness == Brightness.dark),
        ).bodyMedium,
        child: Navigator(
          onGenerateRoute: (_) =>
              PageRouteBuilder<void>(pageBuilder: (context, a, b) => child),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('recesses get one material host without double framing', (
    tester,
  ) async {
    final recess = LuminaSurface(
      key: GlobalKey(),
      depth: LuminaSurfaceDepth.recessed,
      child: const Text('Inset'),
    );
    await tester.pumpWidget(harness(Center(child: recess)));
    expect(
      tester
          .widgetList<LuminaSurface>(find.byType(LuminaSurface))
          .where((s) => s.depth == LuminaSurfaceDepth.raised),
      hasLength(1),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      harness(
        Center(
          child: LuminaSurface(depth: LuminaSurfaceDepth.raised, child: recess),
        ),
      ),
    );
    expect(
      tester
          .widgetList<LuminaSurface>(find.byType(LuminaSurface))
          .where((s) => s.depth == LuminaSurfaceDepth.raised),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('card shoulder follows title and supports large text', (
    tester,
  ) async {
    Future<double> measure(String title, {double scale = 1}) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        harness(
          Center(
            child: SizedBox(
              width: 350,
              child: LuminaCollapsibleCard(
                storageId: 'shoulder-test',
                title: title,
                child: const Text('Content'),
              ),
            ),
          ),
          scale: scale,
        ),
      );
      await tester.pumpAndSettle();
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .firstWhere((p) => p.runtimeType.toString() == '_LuminaMaterial');
      return (painter as dynamic).shoulderWidth as double;
    }

    final short = await measure('今日');
    final long = await measure('今日重要安排');
    expect(long, greaterThan(short));
    expect(await measure('今日', scale: 2), greaterThan(short));
    await measure('很长的标题应当换行并且不能撑破卡片边界', scale: 2);
    expect(tester.takeException(), isNull);
  });

  test('palette families provide matching light and dark material roles', () {
    expect(LuminaCardPalette.values.map((p) => p.tint).toSet(), hasLength(6));
    for (final palette in LuminaCardPalette.values) {
      for (final dark in [false, true]) {
        final colors = palette.colors(dark: dark);
        expect(colors.raisedSurface, isNot(colors.recessedSurface));
        expect(colors.accent, isNot(colors.raisedSurface));
        expect(colors.ink, isNot(colors.recessedSurface));
      }
    }
  });

  testWidgets('navigation scrub commits only on release', (tester) async {
    var index = 0;
    await tester.pumpWidget(
      harness(
        Center(
          child: SizedBox(
            width: 500,
            child: StatefulBuilder(
              builder: (context, setState) => LuminaSlidingSelection(
                index: index,
                count: 5,
                longTravel: true,
                onDragEnd: (value) => setState(() => index = value),
                child: const SizedBox(width: 500, height: 48),
              ),
            ),
          ),
        ),
      ),
    );
    final bounds = tester.getRect(find.byType(LuminaSlidingSelection));
    final gesture = await tester.startGesture(
      Offset(bounds.left + 50, bounds.center.dy),
    );
    await tester.pump(const Duration(milliseconds: 550));
    await gesture.moveTo(Offset(bounds.left + 450, bounds.center.dy));
    await tester.pump();
    expect(index, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(index, 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('main page headers share one height without clipping subtitles', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        Center(
          child: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const OrialisTopBar(key: ValueKey('today'), title: '今日'),
                const OrialisTopBar(
                  key: ValueKey('chat'),
                  title: '聊天',
                  subtitle: '想法在这里，慢慢成形。',
                ),
                OrialisTopBar(
                  key: const ValueKey('events'),
                  title: '事件',
                  actions: [
                    LuminaIconButton(
                      onPressed: () {},
                      icon: const LuminaIcon(LuminaIcons.add),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final heights = [
      for (final id in ['today', 'chat', 'events'])
        tester.getSize(find.byKey(ValueKey(id))).height,
    ];
    expect(heights[1], heights[0]);
    expect(heights[2], heights[0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long navigation travel takes longer than a neighboring step', (
    tester,
  ) async {
    var index = 0;
    late StateSetter update;
    await tester.pumpWidget(
      harness(
        Center(
          child: SizedBox(
            width: 500,
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return LuminaSlidingSelection(
                  index: index,
                  count: 5,
                  longTravel: true,
                  child: const SizedBox(width: 500, height: 48),
                );
              },
            ),
          ),
        ),
      ),
    );
    final lens = find.byType(RawMagnifier);
    final left = tester.getTopLeft(lens).dx;
    update(() => index = 4);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final longFraction = (tester.getTopLeft(lens).dx - left) / 400;
    await tester.pumpAndSettle();
    update(() => index = 3);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final shortFraction = (left + 400 - tester.getTopLeft(lens).dx) / 100;
    expect(longFraction, lessThan(shortFraction));
    expect(longFraction, greaterThan(0));
    expect(longFraction, lessThan(1));
    await tester.pumpAndSettle();
  });

  testWidgets('icon controls use a fixed circular 48 point target', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        Center(
          child: LuminaIconButton(
            onPressed: () {},
            icon: const LuminaIcon(LuminaIcons.add),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(LuminaIconButton)), const Size(48, 48));
    final surface = tester.widget<LuminaSurface>(find.byType(LuminaSurface));
    expect(surface.radius, AppControlSize.capsuleRadius);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(LuminaIconButton)),
    );
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getSize(find.byType(LuminaIconButton)), const Size(48, 48));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'selection slides continuously and retargets without teleporting',
    (tester) async {
      var index = 0;
      late StateSetter update;
      await tester.pumpWidget(
        harness(
          Center(
            child: SizedBox(
              width: 300,
              child: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return LuminaSlidingSelection(
                    index: index,
                    count: 3,
                    child: const SizedBox(height: 48, width: 300),
                  );
                },
              ),
            ),
          ),
        ),
      );
      final lens = find.byType(RawMagnifier);
      expect(tester.widget<RawMagnifier>(lens).magnificationScale, 1.08);
      final origin = tester.getTopLeft(lens).dx;
      update(() => index = 2);
      await tester.pump();
      expect(tester.getTopLeft(lens).dx, origin);
      await tester.pump(const Duration(milliseconds: 80));
      final halfway = tester.getTopLeft(lens).dx;
      expect(halfway, greaterThan(origin));
      expect(halfway, lessThan(origin + 200));
      update(() => index = 1);
      await tester.pump();
      expect(tester.getTopLeft(lens).dx, closeTo(halfway, .01));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(lens).dx, closeTo(origin + 100, .1));
    },
  );

  testWidgets('selection respects reduced motion', (tester) async {
    var index = 0;
    late StateSetter update;
    await tester.pumpWidget(
      harness(
        Center(
          child: SizedBox(
            width: 300,
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return LuminaSlidingSelection(
                  index: index,
                  count: 3,
                  child: const SizedBox(height: 48, width: 300),
                );
              },
            ),
          ),
        ),
        reduced: true,
      ),
    );
    final origin = tester.getTopLeft(find.byType(RawMagnifier)).dx;
    update(() => index = 2);
    await tester.pump();
    expect(tester.getTopLeft(find.byType(RawMagnifier)).dx, origin + 200);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('chat bubbles hug short text and constrain long content', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        Center(
          child: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const OrialisChatBubble(isUser: true, child: Text('短消息')),
                OrialisChatBubble(
                  isUser: false,
                  child: Text('这是一段很长的消息。' * 30),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final surfaces = find.descendant(
      of: find.byType(OrialisChatBubble),
      matching: find.byType(LuminaSurface),
    );
    expect(tester.getSize(surfaces.first).width, lessThan(180));
    expect(tester.getSize(surfaces.last).width, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });
  testWidgets('performance mode removes only live glass blur', (tester) async {
    Widget glass({required bool highPerformance}) => harness(
      Center(
        child: LuminaButton(onPressed: () {}, child: const Text('玻璃按钮')),
      ),
      highPerformance: highPerformance,
    );
    await tester.pumpWidget(glass(highPerformance: true));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('玻璃按钮'), findsOneWidget);
    await tester.pumpWidget(glass(highPerformance: false));
    // Ordinary glass controls stay tint-only; blur is chrome opt-in.
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('玻璃按钮'), findsOneWidget);
  });

  testWidgets('bottom navigation keeps its one live backdrop blur', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        Center(
          child: LuminaSurface(
            glass: true,
            backdrop: true,
            onTap: () {},
            child: const SizedBox(width: 200, height: 48),
          ),
        ),
        highPerformance: false,
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);

    // High-performance mode keeps the chrome blur; only body glass drops it.
    await tester.pumpWidget(
      harness(
        Center(
          child: LuminaSurface(
            glass: true,
            backdrop: true,
            onTap: () {},
            child: const SizedBox(width: 200, height: 48),
          ),
        ),
        highPerformance: true,
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('page entrance is light and respects reduced motion', (
    tester,
  ) async {
    final controller = AnimationController(
      vsync: tester,
      duration: LuminaMotion.page,
    );
    Future<void> render({bool reduced = false}) => tester.pumpWidget(
      harness(
        Builder(
          builder: (context) => luminaPageTransition(
            context,
            controller,
            const SizedBox(width: 80, height: 80),
          ),
        ),
        reduced: reduced,
      ),
    );
    await render();
    final fade = tester.widget<FadeTransition>(find.byType(FadeTransition));
    expect(fade.opacity.value, .96);
    controller.forward();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(fade.opacity.value, inExclusiveRange(.96, 1));
    await tester.pumpAndSettle();
    expect(fade.opacity.value, 1);
    await render(reduced: true);
    expect(find.byType(FadeTransition), findsNothing);
    expect(find.byType(SlideTransition), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('glass material fills its expanded control bounds', (
    tester,
  ) async {
    const contentKey = ValueKey('glass-content');
    await tester.pumpWidget(
      harness(
        Center(
          child: SizedBox(
            width: 300,
            height: 60,
            child: Row(
              children: [
                Expanded(
                  child: LuminaSurface(
                    glass: true,
                    padding: EdgeInsets.zero,
                    onTap: () {},
                    child: const SizedBox(
                      key: contentKey,
                      width: 20,
                      height: 44,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(contentKey)).width, 300);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'sheet motion reverses continuously and respects reduced motion',
    (tester) async {
      final controller = AnimationController(
        vsync: tester,
        duration: LuminaMotion.standard,
      );
      Future<void> render({bool reduced = false}) => tester.pumpWidget(
        harness(
          Builder(
            builder: (context) => luminaOverlayTransition(
              context,
              controller,
              const SizedBox(width: 80, height: 80),
              sheet: true,
            ),
          ),
          reduced: reduced,
        ),
      );
      await render();
      controller.forward();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      final slide = tester.widget<SlideTransition>(
        find.byType(SlideTransition),
      );
      final before = slide.position.value.dy;
      expect(before, inExclusiveRange(0, 1));
      controller.reverse();
      expect(slide.position.value.dy, before);
      await tester.pumpAndSettle();
      expect(slide.position.value.dy, 1);
      await render(reduced: true);
      expect(find.byType(SlideTransition), findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets('button pointer and keyboard activation respect disabled state', (
    tester,
  ) async {
    var count = 0;
    await tester.pumpWidget(
      harness(
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LuminaButton(onPressed: () => count++, child: const Text('运行')),
              const LuminaButton(onPressed: null, child: Text('不可用')),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('运行'));
    await tester.pumpAndSettle();
    expect(count, 1);
    await tester.tap(find.text('不可用'));
    await tester.pumpAndSettle();
    expect(count, 1);
    final focus = Focus.of(tester.element(find.text('运行')));
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(count, 2);
  });
  testWidgets(
    'text entry updates and disabled field cannot take pointer focus',
    (tester) async {
      final editable = TextEditingController(),
          disabled = TextEditingController();
      final disabledFocus = FocusNode();
      await tester.pumpWidget(
        harness(
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LuminaTextField(
                  controller: editable,
                  label: '名称',
                  maxLength: 5,
                ),
                LuminaTextField(
                  controller: disabled,
                  label: '锁定',
                  enabled: false,
                  focusNode: disabledFocus,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(EditableText).first, 'abcdef');
      await tester.pump();
      expect(editable.text, 'abcde');
      await tester.tap(find.byType(EditableText).last, warnIfMissed: false);
      await tester.pump();
      expect(disabledFocus.hasFocus, isFalse);
      await tester.pumpWidget(const SizedBox());
      editable.dispose();
      disabled.dispose();
      disabledFocus.dispose();
    },
  );
  testWidgets('checkbox and switch expose their new values after taps', (
    tester,
  ) async {
    var checked = false, switched = false;
    await tester.pumpWidget(
      harness(
        StatefulBuilder(
          builder: (context, set) => Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LuminaCheck(
                  value: checked,
                  onChanged: (v) => set(() => checked = v),
                ),
                LuminaSwitch(
                  value: switched,
                  onChanged: (v) => set(() => switched = v),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(LuminaCheck));
    await tester.pumpAndSettle();
    expect(checked, isTrue);
    await tester.tap(find.byType(LuminaSwitch));
    await tester.pumpAndSettle();
    expect(switched, isTrue);
  });
  testWidgets(
    'large text controls and dark surfaces remain readable without overflow',
    (tester) async {
      await tester.pumpWidget(
        harness(
          Center(
            child: SizedBox(
              width: 300,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LuminaButton(
                    onPressed: () {},
                    child: const Text('继续安排今天的工作'),
                  ),
                  const OrialisListRow(
                    title: '一项需要关注的任务',
                    subtitle: '保存并同步到所有设备',
                  ),
                ],
              ),
            ),
          ),
          brightness: Brightness.dark,
          scale: 2,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        LuminaTheme.of(
          tester.element(find.text('继续安排今天的工作')),
        ).textTheme.bodyMedium.color,
        const Color(0xFFECF1F4),
      );
    },
  );
  testWidgets(
    'reduced motion has no press scale and opaque mode removes backdrop',
    (tester) async {
      await tester.pumpWidget(
        harness(
          Center(
            child: LuminaButton(onPressed: () {}, child: const Text('按压')),
          ),
          reduced: true,
          opaque: true,
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('按压')),
      );
      await tester.pump();
      expect(find.byType(BackdropFilter), findsNothing);
      for (final transform in tester.widgetList<Transform>(
        find.byType(Transform),
      )) {
        expect(transform.transform.entry(0, 0), 1);
        expect(transform.transform.entry(1, 1), 1);
      }
      await gesture.up();
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'sheet clears keyboard, preserves opaque dark theme and dismisses',
    (tester) async {
      await tester.pumpWidget(
        harness(
          Builder(
            builder: (context) => Center(
              child: LuminaButton(
                onPressed: () => showLuminaSheet<void>(
                  context: context,
                  builder: (context) => const Text('面板内容'),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
          brightness: Brightness.dark,
          reduced: true,
          opaque: true,
          insets: const EdgeInsets.only(bottom: 280),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('面板内容'), findsOneWidget);
      expect(tester.getBottomLeft(find.text('面板内容')).dy, lessThan(520));
      final theme = LuminaTheme.of(tester.element(find.text('面板内容')));
      expect(theme.brightness, Brightness.dark);
      expect(theme.reduceTransparency, isTrue);
      Navigator.of(tester.element(find.text('面板内容'))).pop();
      await tester.pumpAndSettle();
      expect(find.text('面板内容'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('reduced and determinate progress stop animation tickers', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(const Center(child: LuminaProgress()), reduced: true),
    );
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      harness(const Center(child: LuminaProgress(value: .4))),
    );
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
  });
}
