import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/app/design/design_components.dart';

Widget harness(
  Widget child, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool reduced = false,
  bool opaque = false,
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
