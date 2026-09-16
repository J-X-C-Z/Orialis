import 'package:flutter_test/flutter_test.dart';

import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';
import 'package:orialis_mobile/features/chat/domain/agent_event_state.dart';
import 'package:orialis_mobile/features/chat/presentation/safe_markdown.dart';

void main() {
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
