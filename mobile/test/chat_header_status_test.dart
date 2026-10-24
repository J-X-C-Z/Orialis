import 'dart:async';

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';
import 'package:orialis_mobile/features/chat/data/agent_chat_service.dart';
import 'package:orialis_mobile/features/chat/domain/agent_event_state.dart';
import 'package:orialis_mobile/features/chat/presentation/agent_status_ring.dart';
import 'package:orialis_mobile/features/chat/presentation/chat_header_status.dart';

class _Config extends AppConfig {
  final listeners = <Future<void> Function()>{};
  @override
  void addIdentityListener(Future<void> Function() listener) =>
      listeners.add(listener);
  @override
  void removeIdentityListener(Future<void> Function() listener) =>
      listeners.remove(listener);
  Future<void> revoke() async {
    for (final listener in listeners.toList()) {
      await listener();
    }
  }
}

class _Agents extends AgentChatService {
  _Agents(super.config);
  Future<bool?> Function(String) probe = (_) async => true;
  final queries = <String>[];
  (String, String) scope = ('https://server.invalid', 'session');
  @override
  Future<(String, String)> identity() async => scope;
  @override
  Future<bool?> devicePresence(String id) {
    queries.add(id);
    return probe(id);
  }
}

Widget _host(
  AgentEventStore store,
  _Agents agents, {
  String target = 'first',
  bool ticker = true,
  Future<void> Function()? onRefresh,
}) => MaterialApp(
  home: LuminaTheme(
    data: const LuminaThemeData(motionScale: 0),
    child: TickerMode(
      enabled: ticker,
      child: Center(
        child: ChatHeaderStatus(
          store: store,
          agents: agents,
          deviceId: target,
          onRefresh: onRefresh,
        ),
      ),
    ),
  ),
);

AgentRingStatus _shown(WidgetTester tester) =>
    tester.widget<AgentStatusRing>(find.byType(AgentStatusRing)).status;

void main() {
  test('historical failures, streams and tools are not current evidence', () {
    final store = AgentEventStore()
      ..runtimeRevision = 8
      ..agentStatus = 'failed';
    store.errors.add(const AgentError(code: 'old', message: 'old failure'));
    store.streams['old'] = AgentStream(id: 'old')..markError('old failure');
    store.tools['old'] = const ToolTimelineItem(
      id: 'old',
      name: 'old',
      status: 'running',
    );
    final status = projectChatHeaderStatus(
      store: store,
      baselineRevision: 8,
      presence: true,
    );
    expect(status.status, AgentRingStatus.online);
    expect(status.label, '设备在线 · 暂无实时状态');
    expect(
      projectChatHeaderStatus(
        store: store,
        baselineRevision: 8,
        presence: true,
        lastTurnFailed: true,
      ).status,
      AgentRingStatus.error,
    );
    expect(
      projectChatHeaderStatus(
        store: store,
        baselineRevision: 8,
        presence: true,
        sending: true,
        lastTurnFailed: true,
      ).status,
      AgentRingStatus.waiting,
    );
    store.dispose();
  });

  test(
    'fresh attributed stream and explicit terminal override old errors/tools',
    () {
      final store = AgentEventStore();
      store.errors.add(const AgentError(code: 'old', message: 'old failure'));
      store.apply(
        const MobileEnvelope(
          type: 'event',
          payload: {
            'kind': 'stream.delta',
            'streamId': 'new',
            'delta': 'hello',
          },
        ),
      );
      expect(
        projectChatHeaderStatus(
          store: store,
          baselineRevision: 0,
          presence: true,
          lastTurnFailed: true,
        ).status,
        AgentRingStatus.answering,
      );
      store.approvals['old'] = const ApprovalRequest(id: 'old', title: 'old');
      store.tools['old'] = const ToolTimelineItem(
        id: 'old',
        name: 'old',
        status: 'running',
      );
      for (final terminal in [
        'idle',
        'ready',
        'completed',
        'complete',
        'done',
        'cancelled',
        'stopped',
      ]) {
        store.agentStatus = terminal;
        expect(
          projectChatHeaderStatus(
            store: store,
            baselineRevision: 0,
            presence: true,
          ).status,
          AgentRingStatus.online,
        );
      }
      store.agentStatus = 'waiting';
      expect(
        projectChatHeaderStatus(
          store: store,
          baselineRevision: 0,
          presence: true,
        ).status,
        AgentRingStatus.waiting,
      );
      store.runtimeAttributed = false;
      expect(
        projectChatHeaderStatus(
          store: store,
          baselineRevision: 0,
          presence: true,
        ).status,
        AgentRingStatus.online,
      );
      store.dispose();
    },
  );

  test('explicit offline and failed refresh override runtime evidence', () {
    final store = AgentEventStore()
      ..runtimeRevision = 1
      ..agentStatus = 'running';
    expect(
      projectChatHeaderStatus(
        store: store,
        baselineRevision: 0,
        presence: false,
      ).status,
      AgentRingStatus.offline,
    );
    expect(
      projectChatHeaderStatus(
        store: store,
        baselineRevision: 0,
        presence: null,
        presenceFailed: true,
      ).status,
      AgentRingStatus.unknown,
    );
    store.dispose();
  });

  testWidgets('presence errors clear an earlier online result to unknown', (
    tester,
  ) async {
    final config = _Config();
    final agents = _Agents(config);
    final store = AgentEventStore();
    await tester.pumpWidget(_host(store, agents));
    await tester.pumpAndSettle();
    expect(_shown(tester), AgentRingStatus.online);
    agents.probe = (_) async => throw Exception('network');
    store.agentDevicesChanged++;
    store.notify();
    await tester.pumpAndSettle();
    expect(_shown(tester), AgentRingStatus.unknown);
    agents.probe = (_) async => false;
    store.agentDevicesChanged++;
    store.notify();
    await tester.pumpAndSettle();
    expect(_shown(tester), AgentRingStatus.offline);
    await tester.pumpWidget(const SizedBox.shrink());
    agents.dispose();
    store.dispose();
  });

  testWidgets(
    'target switch rejects old presence result and identity revoke clears synchronously',
    (tester) async {
      final config = _Config();
      final agents = _Agents(config);
      final store = AgentEventStore();
      final first = Completer<bool?>(), second = Completer<bool?>();
      agents.probe = (id) => id == 'first' ? first.future : second.future;
      await tester.pumpWidget(_host(store, agents));
      await tester.pump();
      await tester.pumpWidget(_host(store, agents, target: 'second'));
      await tester.pump();
      second.complete(true);
      await tester.pumpAndSettle();
      expect(_shown(tester), AgentRingStatus.online);
      first.complete(false);
      await tester.pumpAndSettle();
      expect(_shown(tester), AgentRingStatus.online);
      await config.revoke();
      await tester.pump();
      expect(_shown(tester), AgentRingStatus.unknown);
      await tester.pumpWidget(const SizedBox.shrink());
      agents.dispose();
      store.dispose();
    },
  );

  testWidgets(
    'hidden and background header stops polling until visible resumed',
    (tester) async {
      final agents = _Agents(_Config());
      final store = AgentEventStore();
      await tester.pumpWidget(_host(store, agents, ticker: false));
      await tester.pump(const Duration(seconds: 35));
      expect(agents.queries, isEmpty);
      await tester.pumpWidget(_host(store, agents));
      await tester.pump();
      expect(agents.queries, hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 35));
      expect(agents.queries, hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(agents.queries, hasLength(2));
      await tester.pumpWidget(const SizedBox.shrink());
      agents.dispose();
      store.dispose();
    },
  );

  testWidgets(
    'details show device name and refresh presence before runtime callback',
    (tester) async {
      final agents = _Agents(_Config());
      final store = AgentEventStore();
      final calls = <String>[];
      agents.probe = (_) async {
        calls.add('presence');
        return true;
      };
      await tester.pumpWidget(
        _host(
          store,
          agents,
          onRefresh: () async {
            calls.add('runtime');
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('first'), findsNothing);
      await tester.tap(find.byType(AgentStatusRing));
      await tester.pumpAndSettle();
      expect(find.text('first'), findsOneWidget);
      // The modal may disable its source route's ticker while remaining visible.
      await tester.pumpWidget(
        _host(
          store,
          agents,
          ticker: false,
          onRefresh: () async {
            calls.add('runtime');
          },
        ),
      );
      await tester.pumpAndSettle();
      calls.clear();
      await tester.tap(find.text('刷新'));
      await tester.pumpAndSettle();
      expect(calls, ['presence', 'runtime']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      agents.dispose();
      store.dispose();
    },
  );
}
