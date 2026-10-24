import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';
import 'package:orialis_mobile/features/chat/domain/agent_event_state.dart';
import 'package:orialis_mobile/features/chat/domain/session_summary.dart';

void main() {
  test(
    'runtime attribution and revision exclude unscoped evidence in header',
    () {
      final store = AgentEventStore();
      final initial = store.runtimeRevision;
      store.applySilent(
        const MobileEnvelope(
          type: 'event',
          payload: {'kind': 'agent.start', 'streamId': 'unscoped'},
        ),
        attributed: false,
      );
      expect(store.runtimeRevision, greaterThan(initial));
      expect(store.runtimeAttributed, isFalse);
      store.apply(
        const MobileEnvelope(
          type: 'event',
          payload: {
            'kind': 'approval.request',
            'id': 'approval',
            'title': 'Confirm',
          },
        ),
      );
      expect(store.runtimeAttributed, isTrue);
      expect(store.agentStatus, 'waiting');
      store.dispose();
    },
  );
  test(
    'device snapshot overrides stale streams until a new real event arrives',
    () {
      final store = AgentEventStore();
      void apply(String kind, Map<String, dynamic> payload) => store.apply(
        MobileEnvelope(type: 'event', payload: {'kind': kind, ...payload}),
      );
      apply('agent.start', {'streamId': 'old'});
      apply('session.status', {
        'requestId': 'refresh-1',
        'id': 'conversation',
        'event': 'session.status',
        'status': 'idle',
        'message': '设备空闲',
      });
      expect(store.hasStatusSnapshot, isTrue);
      expect(store.typing, isFalse);
      expect(store.agentStatusDetail, '设备空闲');
      expect(
        ChatSessionSummary.fromEvents(store).state,
        ChatSessionState.ready,
      );
      apply('agent.start', {'streamId': 'new'});
      expect(store.hasStatusSnapshot, isFalse);
      expect(store.agentStatusDetail, isNull);
      expect(
        ChatSessionSummary.fromEvents(store).state,
        ChatSessionState.running,
      );
      apply('stream.error', {'streamId': 'new', 'message': '连接中断'});
      expect(
        ChatSessionSummary.fromEvents(store).state,
        ChatSessionState.failed,
      );
      apply('session.status', {
        'requestId': 'refresh-2',
        'id': 'conversation',
        'event': 'session.status',
        'status': 'unknown',
        'message': '旧插件未报告运行状态',
      });
      expect(
        ChatSessionSummary.fromEvents(store).state,
        ChatSessionState.ready,
      );
      store.dispose();
    },
  );
  test(
    'old command acknowledgements cannot masquerade as runtime completion',
    () {
      final legacy = SessionInfo.fromPayload({
        'kind': 'session.status',
        'event': 'session.status',
        'status': 'completed',
        'message': '/status output',
      }, event: 'session.status');
      expect(legacy.statusSnapshot, isTrue);
      expect(legacy.status, 'unknown');
      final reset = SessionInfo.fromPayload({
        'kind': 'session.status',
        'event': 'session.reset',
        'requestId': 'reset-1',
        'status': 'completed',
      }, event: 'session.status');
      expect(reset.statusSnapshot, isFalse);
    },
  );
}
