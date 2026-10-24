import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';
import 'package:orialis_mobile/features/chat/domain/agent_event_state.dart';
import 'package:orialis_mobile/features/chat/domain/chat_transcript.dart';

Message _message(String id, String content) => Message(
  conversationId: 'chat',
  id: id,
  role: 'assistant',
  content: content,
  createdAt: '2026-10-25T00:00:00Z',
  attachmentsJson: '[]',
  syncStatus: 'synced',
  remoteVersion: 1,
);

MobileEnvelope _event(String kind, Map<String, dynamic> payload) =>
    MobileEnvelope(type: 'event', payload: {'kind': kind, ...payload});

void main() {
  test('brief Chinese acknowledgement is a visible transcript message', () {
    expect(isVisibleChatMessage(_message('ack', '收到，我先处理一下。')), isTrue);
  });

  test('message receipt leaves the run active until final completion', () {
    final store = AgentEventStore();
    addTearDown(store.dispose);

    store.apply(_event('agent.start', {'streamId': 'run-1'}));
    expect(store.agentStatus, 'running');

    // Persisted assistant messages are transcript content; their receipt does
    // not mean the Hermes processing lifecycle has ended.
    expect(isVisibleChatMessage(_message('ack', '收到，我先处理一下。')), isTrue);
    store.apply(
      const MobileEnvelope(
        type: 'message.ack',
        payload: {'message_id': 'ack', 'status': 'received'},
      ),
    );
    expect(store.agentStatus, 'running');

    expect(isVisibleChatMessage(_message('final', '这是完整处理结果。')), isTrue);
    store.apply(
      _event('agent.complete', {
        'streamId': 'run-1',
        'content': '这是完整处理结果。',
        'messageId': 'final',
      }),
    );

    expect(store.agentStatus, 'completed');
    expect(store.streams['run-1']?.text, '这是完整处理结果。');
  });
}
