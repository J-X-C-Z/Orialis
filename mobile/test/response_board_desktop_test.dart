import 'dart:convert';

import 'package:flutter/rendering.dart' show EnginePhase;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/data/chat_repository.dart';
import 'package:orialis_mobile/features/chat/presentation/chat_message_search.dart';
import 'package:orialis_mobile/features/chat/presentation/response_ui_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lumina_chat_flow_test.dart' show openChat, iconAction;

Finder get _sidebar => find.byKey(const ValueKey('chat-conversation-sidebar'));
Finder get _detail => find.byKey(const ValueKey('chat-conversation-detail'));
Finder get _composer =>
    find.descendant(of: _detail, matching: find.byType(EditableText));
Finder _conversation(String id) => find.byKey(ValueKey('conversation-row-$id'));

Future<int> _settle(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 50),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 5),
);

Future<T> _finishDatabase<T>(
  WidgetTester tester,
  Future<T> operation,
  String stage,
) async {
  var completed = false;
  late T result;
  Object? failure;
  StackTrace? failureStack;
  // Drift work and its completion listener stay in the same fake zone.
  final observed = operation.then<void>(
    (value) {
      result = value;
      completed = true;
    },
    onError: (Object error, StackTrace stack) {
      failure = error;
      failureStack = stack;
      completed = true;
    },
  );
  await _settle(tester);
  // A timeout timer alone cannot advance while the test's fake clock is idle.
  for (var attempt = 0; !completed && attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (!completed) fail('Desktop database stage did not complete: $stage');
  await observed;
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  await _settle(tester);
  return result;
}

Future<void> _resize(WidgetTester tester, double width) async {
  // openChat sets 432px itself, so change the actual viewport after it returns.
  tester.view.physicalSize = Size(width, 1000);
  await _settle(tester);
}

Future<void> _saveMessage(
  WidgetTester tester,
  ChatRepository repository,
  String conversationId,
  String content,
) async {
  final write = repository.applyRemoteMessage({
    'id': 'desktop-message-$conversationId',
    'conversationId': conversationId,
    'role': 'assistant',
    'content': content,
    'createdAt': '2026-10-25T08:00:00Z',
    'version': 1,
  });
  await _finishDatabase(tester, write, 'save message for $conversationId');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets(
    'desktop shows real list, filters, and full-width response cards',
    (tester) async {
      final h = await openChat(tester);
      final card = {
        'version': 1,
        'fallback': '作者演示数据：章节覆盖为3/5。',
        'blocks': [
          {
            'type': 'progress',
            'items': [
              {'label': '章节覆盖（演示）', 'value': 3, 'max': 5},
            ],
          },
        ],
      };
      await _saveMessage(
        tester,
        h.repo,
        h.id,
        '桌面回答\n\n```orialis-ui\n${jsonEncode(card)}\n```',
      );
      await _resize(tester, 1400);
      expect(_sidebar, findsOneWidget);
      expect(_detail, findsOneWidget);
      expect(tester.getSize(_sidebar).width, 300);
      expect(
        tester.getRect(_sidebar).right,
        lessThan(tester.getRect(_detail).left),
      );
      expect(find.byKey(const ValueKey('conversation-search')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('conversation-filters')),
        findsOneWidget,
      );
      expect(_conversation(h.id), findsOneWidget);
      expect(find.text('桌面回答', findRichText: true), findsOneWidget);
      final response = find.descendant(
        of: _detail,
        matching: find.byType(ResponseUiView),
      );
      expect(response, findsOneWidget);
      expect(tester.getSize(response).width, greaterThan(600));

      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('conversation-search')),
          matching: find.byType(EditableText),
        ),
        '不存在的会话',
      );
      await _settle(tester);
      expect(_conversation(h.id), findsNothing);
      expect(find.text('桌面回答', findRichText: true), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('conversation-search')),
          matching: find.byType(EditableText),
        ),
        '',
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('conversation-filters')));
      await _settle(tester);
      expect(find.text('筛选会话'), findsOneWidget);
      await tester.tap(find.widgetWithText(LuminaButton, '完成'));
      await _settle(tester);

      await _resize(tester, 1900);
      expect(tester.getSize(_detail).width, 1120);
      expect(tester.getSize(response).width, greaterThan(900));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
    },
  );

  testWidgets('desktop switches real conversations and preserves both drafts', (
    tester,
  ) async {
    final h = await openChat(tester);
    final creating = h.repo.createConversation(title: '第二个真实会话');
    final other = await _finishDatabase(
      tester,
      creating,
      'create second conversation',
    );
    await _saveMessage(tester, h.repo, h.id, '第一会话的真实内容');
    await _saveMessage(tester, h.repo, other.id, '第二会话的真实内容');
    await _resize(tester, 1400);
    await tester.enterText(_composer, '第一份未发送草稿');
    await tester.tap(_conversation(other.id));
    await _settle(tester);
    expect(
      find.descendant(of: _detail, matching: find.text('第二个真实会话')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _detail,
        matching: find.text('第二会话的真实内容', findRichText: true),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _detail,
        matching: find.text('第一会话的真实内容', findRichText: true),
      ),
      findsNothing,
    );
    expect(tester.widget<EditableText>(_composer).controller.text, isEmpty);
    await tester.enterText(_composer, '第二份未发送草稿');
    await tester.tap(_conversation(h.id));
    await _settle(tester);
    expect(tester.widget<EditableText>(_composer).controller.text, '第一份未发送草稿');
    await tester.tap(_conversation(other.id));
    await _settle(tester);
    expect(tester.widget<EditableText>(_composer).controller.text, '第二份未发送草稿');

    await tester.tap(iconAction('返回会话列表'));
    await _settle(tester);
    expect(_sidebar, findsOneWidget);
    expect(_detail, findsNothing);
    expect(find.byKey(const ValueKey('chat-desktop-empty')), findsOneWidget);
    final entry = find.widgetWithText(LuminaButton, '与设备对话');
    expect(tester.widget<LuminaButton>(entry).onPressed, isNotNull);
    await tester.tap(_conversation(other.id));
    await _settle(tester);
    expect(tester.widget<EditableText>(_composer).controller.text, '第二份未发送草稿');
    final reading = h.db.select(h.db.messages).get();
    final rows = await _finishDatabase(
      tester,
      reading,
      'read saved drafts case messages',
    );
    expect(rows.where((m) => m.role == 'user'), isEmpty);
    expect(h.realtime.sent, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
  });

  for (final modifier in [
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.metaLeft,
  ]) {
    testWidgets(
      '${modifier.keyLabel}+F searches saved messages without sending draft',
      (tester) async {
        final h = await openChat(tester);
        await _saveMessage(tester, h.repo, h.id, '桌面搜索命中：专注时间45分钟。');
        await _resize(tester, 1400);
        await tester.enterText(_composer, '搜索期间保留的草稿');
        final sends = h.sync.attempts;
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(modifier);
        await _settle(tester);
        expect(find.byType(ChatMessageSearch), findsOneWidget);
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('chat-message-search-input')),
            matching: find.byType(EditableText),
          ),
          '专注',
        );
        await _settle(tester);
        expect(find.text('1 条结果'), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(ChatMessageSearch),
            matching: find.text('桌面搜索命中：专注时间45分钟。'),
          ),
        );
        await _settle(tester);
        expect(find.byType(ChatMessageSearch), findsNothing);
        expect(
          tester.widget<EditableText>(_composer).controller.text,
          '搜索期间保留的草稿',
        );
        expect(h.sync.attempts, sends);
        expect(h.realtime.sent, isEmpty);
        final messages = (await tester.runAsync(
          () => h.db.select(h.db.messages).get(),
        ))!;
        expect(messages.where((m) => m.role == 'user'), isEmpty);
        expect(_sidebar, findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
      },
    );
  }

  testWidgets(
    'resizing keeps the selected draft and restores narrow branch flow',
    (tester) async {
      final h = await openChat(tester);
      await _resize(tester, 1400);
      await tester.enterText(_composer, '跨宽度保留的草稿');
      await _resize(tester, 1049);
      expect(find.byKey(const ValueKey('chat-narrow-layout')), findsOneWidget);
      expect(_sidebar, findsNothing);
      await _resize(tester, 1050);
      expect(_sidebar, findsOneWidget);
      await _resize(tester, 432);
      expect(find.byKey(const ValueKey('chat-desktop-layout')), findsNothing);
      expect(find.byKey(const ValueKey('chat-narrow-layout')), findsOneWidget);
      expect(find.byKey(const ValueKey('conversation-search')), findsNothing);
      expect(
        tester.widget<EditableText>(_composer).controller.text,
        '跨宽度保留的草稿',
      );
      await tester.tap(iconAction('返回会话列表'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('conversation-search')), findsOneWidget);
      expect(iconAction('返回会话列表'), findsNothing);
      await tester.tap(_conversation(h.id));
      await _settle(tester);
      expect(
        tester.widget<EditableText>(_composer).controller.text,
        '跨宽度保留的草稿',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
    },
  );
}
