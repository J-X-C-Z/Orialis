import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';
import 'package:orialis_mobile/features/chat/domain/agent_event_state.dart';
import 'package:orialis_mobile/features/chat/presentation/agent_event_cards.dart';
import 'package:orialis_mobile/features/chat/presentation/chat_activity_panel.dart';

Widget _host(
  AgentEventStore store, {
  Future<void> Function()? refresh,
  bool reducedMotion = false,
  double scale = 1,
}) => MaterialApp(
  home: LuminaTheme(
    child: MediaQuery(
      data: MediaQueryData(
        disableAnimations: reducedMotion,
        textScaler: TextScaler.linear(scale),
      ),
      child: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 240,
            child: AgentEventsPanel(
              store: store,
              onAction: (_, _, _) async {},
              onRefresh: refresh,
            ),
          ),
        ),
      ),
    ),
  ),
);

void _event(
  AgentEventStore store,
  String kind, [
  Map<String, dynamic> data = const {},
]) => store.apply(
  MobileEnvelope(type: 'event', payload: {'kind': kind, ...data}),
);

void main() {
  testWidgets(
    'explicit snapshot status overrides stale streams without duplicate session cards',
    (tester) async {
      final store = AgentEventStore();
      _event(store, 'agent.start', {'streamId': 'stale'});
      await tester.pumpWidget(_host(store, refresh: () async {}));
      for (final (reported, displayed) in [
        ('idle', '空闲'),
        ('ready', '空闲'),
        ('unknown', '暂无实时状态'),
      ]) {
        _event(store, 'session.status', {
          'requestId': 'refresh',
          'sessionId': 'session',
          'status': reported,
          'message': 'Actual public summary',
        });
        await tester.pumpAndSettle();
        expect(find.text(displayed), findsOneWidget);
        expect(find.text('正在处理'), findsNothing);
        expect(find.text('会话状态'), findsNothing);
      }
    },
  );
  testWidgets(
    'shows real activity before any text, and stream output has no surface',
    (tester) async {
      final store = AgentEventStore();
      await tester.pumpWidget(_host(store, refresh: () async {}));
      expect(find.text('暂无实时状态'), findsOneWidget);
      _event(store, 'agent.start', {'streamId': 's'});
      await tester.pumpAndSettle();
      expect(find.text('正在处理'), findsOneWidget);
      _event(store, 'agent.status', {
        'status': 'thinking',
        'detail': '正在检索公开资料',
      });
      await tester.pumpAndSettle();
      expect(find.text('思考中'), findsOneWidget);
      expect(find.text('正在检索公开资料'), findsNothing);
      await tester.tap(find.text('运行状态'));
      await tester.pumpAndSettle();
      expect(find.text('正在检索公开资料'), findsOneWidget);
      _event(store, 'stream.delta', {
        'streamId': 's',
        'delta': 'A real reply',
        'sequence': 0,
      });
      await tester.pumpAndSettle();
      expect(find.text('A real reply', findRichText: true), findsOneWidget);
      final reply = find.text('A real reply', findRichText: true);
      expect(
        find.ancestor(of: reply, matching: find.byType(LuminaSurface)),
        findsNothing,
      );
      expect(
        find.ancestor(of: reply, matching: find.byType(LuminaChatBubble)),
        findsNothing,
      );
    },
  );

  testWidgets(
    'refresh reports loading, errors and success only from callback completion',
    (tester) async {
      final store = AgentEventStore();
      var operation = Completer<void>();
      var calls = 0;
      Future<void> refresh() {
        calls++;
        return operation.future;
      }

      await tester.pumpWidget(_host(store, refresh: refresh));
      await tester.tap(find.text('刷新'));
      await tester.pump();
      expect(find.text('刷新中'), findsOneWidget);
      expect(find.textContaining('已刷新'), findsNothing);
      await tester.tap(find.text('刷新中'));
      expect(calls, 1);
      operation.completeError(StateError('transport unavailable'));
      await tester.pumpAndSettle();
      expect(find.text('刷新失败，请重试'), findsOneWidget);
      expect(find.textContaining('已刷新'), findsNothing);
      operation = Completer<void>();
      await tester.tap(find.text('刷新'));
      await tester.pump();
      operation.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('已刷新'), findsOneWidget);
      expect(find.text('刷新失败，请重试'), findsNothing);
    },
  );

  testWidgets(
    'old conversation refresh cannot mark a new conversation refreshed',
    (tester) async {
      final first = AgentEventStore();
      final operation = Completer<void>();
      await tester.pumpWidget(_host(first, refresh: () => operation.future));
      await tester.tap(find.text('刷新'));
      await tester.pump();
      await tester.pumpWidget(_host(AgentEventStore(), refresh: () async {}));
      operation.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('已刷新'), findsNothing);
      expect(find.text('刷新'), findsOneWidget);
    },
  );

  for (final reduced in [false, true]) {
    testWidgets(
      'tool progress fits narrow large text and interrupts expansion (reduced=$reduced)',
      (tester) async {
        final store = AgentEventStore();
        _event(store, 'tool.start', {
          'toolId': 'read',
          'name': 'Read source and check the actual status',
          'detail': 'Public tool summary',
        });
        await tester.pumpWidget(
          _host(store, refresh: () async {}, reducedMotion: reduced, scale: 2),
        );
        expect(find.text('1 项运行中 · 0 项失败'), findsOneWidget);
        expect(find.text('Public tool summary'), findsNothing);
        await tester.tap(find.text('工具活动 · 1'));
        await tester.pump(const Duration(milliseconds: 35));
        await tester.tap(find.text('工具活动 · 1'));
        await tester.pump(const Duration(milliseconds: 35));
        await tester.tap(find.text('工具活动 · 1'));
        await tester.pumpAndSettle();
        expect(find.text('Public tool summary'), findsOneWidget);
        _event(store, 'tool.end', {
          'toolId': 'read',
          'status': 'failed',
          'detail': 'Network failure',
        });
        await tester.pumpAndSettle();
        expect(find.text('0 项运行中 · 1 项失败'), findsOneWidget);
        expect(find.text('Network failure'), findsOneWidget);
        final animations = tester.widgetList<AnimatedSize>(
          find.descendant(
            of: find.byType(ChatActivityPanel),
            matching: find.byType(AnimatedSize),
          ),
        );
        if (reduced) {
          expect(animations, isEmpty);
        } else {
          expect(animations.single.duration, LuminaMotion.fast);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
