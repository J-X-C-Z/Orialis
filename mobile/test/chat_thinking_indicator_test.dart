import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';
import 'package:orialis_mobile/features/chat/domain/agent_event_state.dart';
import 'package:orialis_mobile/features/chat/presentation/agent_event_cards.dart';
import 'package:orialis_mobile/features/chat/presentation/chat_thinking_indicator.dart';

Widget _host(AgentEventStore store, {bool reduced = false}) => MaterialApp(
  home: LuminaTheme(
    child: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(
        body: AgentEventsPanel(
          store: store,
          showActivity: false,
          showThinking: true,
          onAction: (_, _, _) async {},
        ),
      ),
    ),
  ),
);

void _event(AgentEventStore store, String kind, Map<String, dynamic> data) =>
    store.apply(
      MobileEnvelope(type: 'event', payload: {'kind': kind, ...data}),
    );

void main() {
  testWidgets('one shimmer line updates and disappears at terminal status', (
    tester,
  ) async {
    final store = AgentEventStore();
    addTearDown(store.dispose);
    _event(store, 'agent.start', {'streamId': 's'});
    await tester.pumpWidget(_host(store));
    expect(find.text('正在思考'), findsOneWidget);
    expect(find.byType(ChatThinkingIndicator), findsOneWidget);
    final mask = tester.widget<ShaderMask>(find.byType(ShaderMask));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.widget<ShaderMask>(find.byType(ShaderMask)),
      isNot(same(mask)),
    );

    for (final minutes in [1, 2, 3]) {
      _event(store, 'agent.status', {
        'status': 'working',
        'message': '⏳ Working — $minutes min — terminal',
      });
      await tester.pump();
      expect(find.byType(ChatThinkingIndicator), findsOneWidget);
      expect(find.text('正在思考 · $minutes 分钟'), findsOneWidget);
      expect(find.textContaining('⏳ Working'), findsNothing);
    }
    for (final status in [
      'completed',
      'failed',
      'cancelled',
      'idle',
      'unknown',
    ]) {
      _event(store, 'agent.status', {'status': status});
      await tester.pumpAndSettle();
      expect(find.byType(ChatThinkingIndicator), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reduced motion is dim static text and internal events stay hidden',
    (tester) async {
      final store = AgentEventStore();
      addTearDown(store.dispose);
      _event(store, 'agent.start', {'streamId': 's'});
      await tester.pumpWidget(_host(store, reduced: true));
      await tester.pumpAndSettle();
      expect(find.byType(ShaderMask), findsNothing);
      expect(
        tester.widget<Text>(find.text('正在思考')).style!.color!.a,
        closeTo(.45, .01),
      );

      _event(store, 'stream.delta', {
        'streamId': 's',
        'delta': '💾 Self-improvement review: Memory updated',
        'sequence': 0,
      });
      _event(store, 'review.summary', {'message': 'Memory updated'});
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Self-improvement', findRichText: true),
        findsNothing,
      );
      expect(find.textContaining('兼容提示'), findsNothing);
      _event(store, 'agent.complete', {'streamId': 's'});
      await tester.pumpAndSettle();
      expect(find.byType(ChatThinkingIndicator), findsNothing);
    },
  );
}
