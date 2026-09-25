import 'package:flutter_test/flutter_test.dart';

import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';
import 'package:orialis_mobile/features/chat/domain/agent_event_state.dart';
import 'package:orialis_mobile/features/chat/presentation/safe_markdown.dart';

void main() {
  test('cloud events never imply a plugin receipt', () {
    final store = AgentEventStore();
    store.apply(
      const MobileEnvelope(
        type: 'message',
        payload: {'id': 'm1', 'syncStatus': 'synced'},
      ),
    );
    store.apply(
      _event('delivery.notification', {'messageId': 'm1', 'ok': true}),
    );
    store.apply(_event('message.ack', {'messageId': 'm1', 'status': 'sent'}));
    expect(store.receivedMessageIds, isEmpty);
    store.apply(
      _event('message.ack', {'message_id': 'm1', 'status': 'received'}),
    );
    expect(store.receivedMessageIds, {'m1'});
    store.apply(
      const MobileEnvelope(
        type: 'message.ack',
        payload: {'message_id': 'm2', 'status': 'received'},
      ),
    );
    expect(store.receivedMessageIds, {'m1', 'm2'});
  });
  test(
    'stream deltas are ordered and duplicate sequence numbers are ignored',
    () {
      final store = AgentEventStore();

      store.apply(
        _event('stream.delta', {
          'streamId': 's1',
          'sequence': 1,
          'delta': 'world',
        }),
      );
      store.apply(
        _event('stream.delta', {
          'streamId': 's1',
          'sequence': 0,
          'delta': 'hello ',
        }),
      );
      store.apply(
        _event('stream.delta', {
          'streamId': 's1',
          'sequence': 1,
          'delta': 'WRONG',
        }),
      );
      store.apply(_event('stream.complete', {'streamId': 's1'}));

      expect(store.streams['s1']!.text, 'hello world');
      expect(store.streams['s1']!.displayStatus, '完成');
    },
  );

  test(
    'stream completion keeps a visible gap state until all deltas arrive',
    () {
      final store = AgentEventStore();
      store.apply(
        _event('stream.delta', {'streamId': 's1', 'sequence': 0, 'delta': 'a'}),
      );
      store.apply(
        _event('stream.delta', {'streamId': 's1', 'sequence': 2, 'delta': 'c'}),
      );
      store.apply(_event('stream.complete', {'streamId': 's1'}));

      expect(store.streams['s1']!.hasGap, isTrue);
      expect(store.streams['s1']!.displayStatus, '等待缺失片段');
      store.apply(
        _event('stream.delta', {'streamId': 's1', 'sequence': 1, 'delta': 'b'}),
      );
      expect(store.streams['s1']!.text, 'abc');
      expect(store.streams['s1']!.displayStatus, '完成');
    },
  );

  test(
    'approval and clarification actions are represented and deduplicated',
    () {
      final store = AgentEventStore();
      store.apply(
        _event('approval.request', {'approvalId': 'a1', 'title': '发送邮件'}),
      );
      store.apply(
        _event('clarify.request', {
          'clarificationId': 'c1',
          'question': '选择项目',
          'options': ['Orialis', '其他'],
        }),
      );

      expect(store.approvals['a1']!.title, '发送邮件');
      expect(store.clarifications['c1']!.options, ['Orialis', '其他']);
      expect(store.actions.claim('a1'), isTrue);
      expect(store.actions.claim('a1'), isFalse);
      store.actions.release('a1');
      expect(store.actions.claim('a1'), isTrue);
    },
  );

  test('unknown events use the safe compatibility fallback', () {
    final store = AgentEventStore();
    store.apply(_event('future.event', {'value': '<script>ignored</script>'}));

    expect(store.fallbacks.single.kind, 'future.event');
    expect(store.errors, isEmpty);
  });

  test('agent_gateway_event wrapper is unwrapped and aliases map', () {
    final store = AgentEventStore();
    store.apply(
      const MobileEnvelope(type: 'event', payload: {
        'kind': 'agent_gateway_event',
        'event': {
          'type': 'tool.started',
          'event_id': 'evt-1',
          'seq': 1,
          'session_id': 's1',
          'tool_call_id': 't1',
          'tool_name': 'search',
          'conversation_id': 'c1',
        },
      }),
    );
    store.apply(
      const MobileEnvelope(type: 'event', payload: {
        'kind': 'agent_gateway_event',
        'event': {
          'type': 'tool.completed',
          'event_id': 'evt-2',
          'seq': 2,
          'session_id': 's1',
          'tool_call_id': 't1',
          'output': 'done',
        },
      }),
    );
    store.apply(
      const MobileEnvelope(type: 'event', payload: {
        'kind': 'agent_gateway_event',
        'event': {
          'type': 'approval.resolve',
          'event_id': 'evt-3',
          'seq': 3,
          'session_id': 's1',
          'request_id': 'a1',
          'decision': 'once',
        },
      }),
    );

    expect(store.tools['t1']!.name, 'search');
    expect(store.tools['t1']!.status, 'completed');
    expect(store.tools['t1']!.detail, 'done');
    expect(store.fallbacks, isEmpty);
  });

  test('wrapped approval request and clarify resolve use gateway field names', () {
    final store = AgentEventStore();
    store.apply(
      const MobileEnvelope(type: 'event', payload: {
        'kind': 'agent_gateway_event',
        'event': {
          'type': 'approval.request',
          'event_id': 'evt-1',
          'seq': 1,
          'session_id': 's1',
          'request_id': 'a1',
          'action': '发送邮件',
          'details': {'note': 'to team'},
        },
      }),
    );
    store.apply(
      const MobileEnvelope(type: 'event', payload: {
        'kind': 'agent_gateway_event',
        'event': {
          'type': 'clarify.request',
          'event_id': 'evt-2',
          'seq': 2,
          'session_id': 's1',
          'request_id': 'c1',
          'question': '选择项目',
          'choices': ['Orialis', '其他'],
        },
      }),
    );

    expect(store.approvals['a1']!.title, '发送邮件');
    expect(store.clarifications['c1']!.options, ['Orialis', '其他']);

    store.apply(
      const MobileEnvelope(type: 'event', payload: {
        'kind': 'agent_gateway_event',
        'event': {
          'type': 'clarify.resolve',
          'event_id': 'evt-3',
          'seq': 3,
          'session_id': 's1',
          'request_id': 'c1',
          'answer': 'Orialis',
        },
      }),
    );
    expect(store.clarifications, isEmpty);
  });

  test('delivery frames become delivery notices and session lifecycle updates', () {
    final store = AgentEventStore();
    store.apply(
      const MobileEnvelope(type: 'event', payload: {
        'kind': 'agent_gateway_event',
        'event': {
          'type': 'proactive.delivery',
          'delivery_id': 'd1',
          'conversation_id': 'c1',
          'content': '定时提醒：喝水',
        },
      }),
    );
    store.apply(
      const MobileEnvelope(type: 'event', payload: {
        'kind': 'agent_gateway_event',
        'event': {
          'type': 'session.error',
          'event_id': 'evt-9',
          'seq': 9,
          'session_id': 's9',
          'code': 'boom',
          'message': '失败',
        },
      }),
    );
    store.apply(
      const MobileEnvelope(type: 'event', payload: {
        'kind': 'agent_gateway_event',
        'event': {
          'type': 'artifact.completed',
          'event_id': 'evt-4',
          'seq': 4,
          'session_id': 's1',
          'artifact': {
            'id': 'art-1',
            'kind': 'document',
            'name': 'report.pdf',
            'mime_type': 'application/pdf',
            'uri': 'https://example.test/report.pdf',
          },
        },
      }),
    );

    expect(store.deliveryNotices.single.message, '定时提醒：喝水');
    expect(store.sessions['s9']!.status, 'ended');
    expect(store.artifacts['art-1']!.name, 'report.pdf');
    expect(store.artifacts['art-1']!.url, 'https://example.test/report.pdf');
    expect(store.fallbacks, isEmpty);
  });

  test('session control results keep command output and recovery kinds', () {
    final store = AgentEventStore();
    store.apply(
      const MobileEnvelope(type: 'event', payload: {
        'kind': 'session.status',
        'id': 'c1',
        'event': 'session.reset',
        'command': '/reset',
        'status': 'completed',
        'message': 'Started a fresh session.',
      }),
    );
    store.apply(
      const MobileEnvelope(type: 'event', payload: {
        'kind': 'session.retry',
        'id': 'c1',
        'event': 'session.retry',
        'command': '/retry',
        'status': 'completed',
        'message': 'Retrying last message.',
      }),
    );

    expect(store.sessions['c1']!.command, '/retry');
    expect(store.sessions['c1']!.message, 'Retrying last message.');
    expect(store.sessions['c1']!.event, 'session.retry');
    expect(store.fallbacks, isEmpty);
  });

  test('resolveAgentEnvelope unwraps nested conversation and kind', () {
    final resolved = resolveAgentEnvelope(
      const MobileEnvelope(type: 'event', payload: {
        'kind': 'agent_gateway_event',
        'event': {
          'type': 'agent.started',
          'event_id': 'evt-1',
          'seq': 1,
          'session_id': 's1',
          'run_id': 'r1',
          'conversation_id': 'c9',
        },
      }),
    );
    expect(resolved.kind, 'agent.start');
    expect(resolved.conversationId, 'c9');
  });

  test('markdown parser recognizes headings, code, lists, and tables', () {
    final blocks = MarkdownBlock.parse('''# 标题

- 一
- 二

| 名称 | 状态 |
| --- | --- |
| A | 完成 |

```dart
final answer = 42;
```''');

    expect(blocks.map((block) => block.type), [
      MarkdownBlockType.heading,
      MarkdownBlockType.bullets,
      MarkdownBlockType.table,
      MarkdownBlockType.code,
    ]);
    expect(blocks.last.language, 'dart');
  });
}

MobileEnvelope _event(String kind, Map<String, dynamic> payload) =>
    MobileEnvelope(type: 'event', payload: {'kind': kind, ...payload});
