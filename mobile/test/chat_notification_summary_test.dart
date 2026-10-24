import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:orialis_mobile/features/system_integration/chat_notification_summary.dart';

void main() {
  test(
    'extracts the response topic and two useful points without formatting',
    () {
      final result = summarizeChatNotification(
        content: '# 消息提醒优化\n\n已经改好了。\n\n- **标题**：展示会话主题\n- **正文**：只保留简短提要\n- 第三个细节不放进通知\n\n```sh\nsecret command\n```',
        userPrompt: '帮我优化一下消息提醒',
        conversationTitle: 'Mac 电脑',
      );
      expect(result.title, '消息提醒优化');
      expect(result.body, '标题：展示会话主题； 正文：只保留简短提要');
      expect(result.body, isNot(contains('secret')));
    },
  );

  test(
    'uses the question as context instead of generic headings or device names',
    () {
      final result = summarizeChatNotification(
        content:
            '# 已完成\n\n[通知标题](https://example.test)已经更新。自己发送的消息不再弹窗。剩余详情请查看应用。',
        userPrompt: '请帮我优化消息提醒，自己的消息不要弹窗',
        conversationTitle: '新消息',
      );
      expect(result.title, '优化消息提醒');
      expect(result.body, '通知标题已经更新。 自己发送的消息不再弹窗。');
      expect(result.body, isNot(contains('https://')));
    },
  );

  test('handles structured responses, code-only replies and empty attachment captions', () {
    final structured = summarizeChatNotification(
      content: '```orialis-ui\n{"version":1,"fallback":"明天上午先复习数学，下午完成物理作业。","blocks":[{"type":"checklist","items":[{"label":"复习数学","checked":false}]}]}\n```',
      userPrompt: '请安排明天的学习计划',
    );
    expect(structured.title, '安排明天的学习计划');
    expect(structured.body, contains('明天上午先复习数学'));
    expect(structured.body, isNot(contains('"version"')));
    expect(
      summarizeChatNotification(content: '```dart\nprint("hello");\n```').body,
      '助手发来一段代码，点击查看详情',
    );
    expect(
      summarizeChatNotification(content: '', hasAttachments: true).body,
      '收到附件，点击查看详情',
    );
  });

  test('keeps titles and previews short without breaking emoji graphemes', () {
    final result = summarizeChatNotification(
      content: List.filled(80, '👩🏽‍💻完成一项优化').join(''),
      userPrompt: List.filled(30, '消息提醒优化').join(),
    );
    expect(result.title.characters.length, lessThanOrEqualTo(26));
    expect(result.body.characters.length, lessThanOrEqualTo(100));
    expect(result.title, endsWith('…'));
    expect(result.body, endsWith('…'));
    expect(result.body, isNot(contains('\uFFFD')));
  });
}
