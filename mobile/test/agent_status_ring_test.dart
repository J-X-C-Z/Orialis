import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/presentation/agent_status_ring.dart';

Widget _host(
  AgentRingStatus status, {
  VoidCallback? onPressed,
  bool reduced = false,
  bool themeReduced = false,
  bool ticker = true,
}) => MaterialApp(
  home: LuminaTheme(
    data: LuminaThemeData(motionScale: themeReduced ? 0 : 1),
    child: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: TickerMode(
        enabled: ticker,
        child: Center(
          child: AgentStatusRing(
            status: status,
            label: '助手状态：${status.name}，查看详情',
            onPressed: onPressed ?? () {},
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('each state remains a labelled 48px status button', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    for (final status in AgentRingStatus.values) {
      await tester.pumpWidget(_host(status, reduced: true));
      await tester.pump();
      final label = '助手状态：${status.name}，查看详情';
      final node = tester.getSemantics(find.byType(LuminaIconButton));
      expect(node.label, label);
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(find.byTooltip(label), findsOneWidget);
      expect(tester.getSize(find.byType(LuminaIconButton)), const Size(48, 48));
      expect(find.byKey(ValueKey(status)), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    semantics.dispose();
  });

  testWidgets('press opens status details once', (tester) async {
    var presses = 0;
    await tester.pumpWidget(
      _host(AgentRingStatus.online, onPressed: () => presses++),
    );
    await tester.tap(find.byType(LuminaIconButton));
    await tester.pump(const Duration(milliseconds: 500));
    expect(presses, 1);
  });

  testWidgets('quiet states schedule no continuous frames', (tester) async {
    for (final status in [
      AgentRingStatus.online,
      AgentRingStatus.offline,
      AgentRingStatus.error,
      AgentRingStatus.unknown,
    ]) {
      await tester.pumpWidget(_host(status));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
    }
  });

  for (final status in [AgentRingStatus.answering, AgentRingStatus.waiting]) {
    testWidgets('${status.name} animates and stops for system reduced motion', (
      tester,
    ) async {
      await tester.pumpWidget(_host(status));
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(_host(status, reduced: true));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
      expect(find.byKey(ValueKey(status)), findsOneWidget);
    });
  }

  testWidgets('theme motion preference also stops continuous animation', (
    tester,
  ) async {
    await tester.pumpWidget(_host(AgentRingStatus.waiting, themeReduced: true));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('hidden branch stops ticks and visible branch resumes', (
    tester,
  ) async {
    await tester.pumpWidget(_host(AgentRingStatus.answering));
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(_host(AgentRingStatus.answering, ticker: false));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(_host(AgentRingStatus.answering));
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
  });

  testWidgets('inactive app stops ticks and returning resumes', (tester) async {
    await tester.pumpWidget(_host(AgentRingStatus.waiting));
    await tester.pump(const Duration(milliseconds: 250));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
  });

  testWidgets(
    'finishing a reply stops the animation without disposing header',
    (tester) async {
      await tester.pumpWidget(_host(AgentRingStatus.answering));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpWidget(_host(AgentRingStatus.online));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
      expect(
        find.byKey(const ValueKey(AgentRingStatus.online)),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
