import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/data/recent_hermes_models.dart';
import 'package:orialis_mobile/features/chat/domain/hermes_shortcuts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lumina_chat_flow_test.dart' show openChat, iconAction;

void main() {
  testWidgets(
    'swipe reply keeps quote on saved message and supports original jump',
    (tester) async {
      final h = await openChat(tester);
      final write = h.repo.applyRemoteMessage({
        'conversationId': h.id,
        'id': 'quote-source',
        'role': 'assistant',
        'content': '先处理重要且紧急的任务。',
        'createdAt': '2026-09-26T00:00:00Z',
        'version': 1,
      });
      await tester.pumpAndSettle();
      await write;
      await tester.pumpAndSettle();
      await tester.drag(
        find.text('先处理重要且紧急的任务。', findRichText: true).first,
        const Offset(90, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('回复 Hermes'), findsOneWidget);
      await tester.enterText(find.byType(EditableText).first, '举个例子');
      await tester.tap(iconAction('发送'));
      await tester.pumpAndSettle();
      final messages = (await tester.runAsync(
        () => h.db.select(h.db.messages).get(),
      ))!;
      final reply = messages.singleWhere((item) => item.content == '举个例子');
      expect(reply.replyToMessageId, 'quote-source');
      expect(reply.replyRole, 'assistant');
      expect(reply.replyQuote, '先处理重要且紧急的任务。');
      expect(find.text('回复 Hermes'), findsNothing);
      await tester.tap(find.byType(LuminaQuotePreview).first);
      await tester.pumpAndSettle();
      expect(find.text('先处理重要且紧急的任务。', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'plus menu opens command level and model settings without sending draft',
    (tester) async {
      final h = await openChat(tester);
      h.realtime.fail = false;
      await tester.enterText(find.byType(EditableText).first, '保留的草稿');
      await tester.tap(iconAction('附件与快捷指令'));
      await tester.pumpAndSettle();
      expect(find.text('拍照'), findsOneWidget);
      expect(find.text('选择照片'), findsOneWidget);
      expect(find.text('选择文件'), findsOneWidget);
      expect(find.text('查看状态'), findsNothing);
      await tester.tap(find.text('指令'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看状态'));
      await tester.pumpAndSettle();
      expect(h.realtime.sent.last['command'], '/status');
      expect(h.realtime.sent.last['kind'], 'hermes.command');
      await tester.tap(iconAction('附件与快捷指令'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('指令'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('切换模型'));
      await tester.pumpAndSettle();
      expect(find.text('模型与思考强度'), findsOneWidget);
      expect(find.text('更多强度'), findsOneWidget);
      expect(h.realtime.sent.length, 1);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is EditableText && w.controller.text == '保留的草稿',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('long press shows actions over a message and replies', (
    tester,
  ) async {
    final h = await openChat(tester);
    final write = h.repo.applyRemoteMessage({
      'conversationId': h.id,
      'id': 'long-press-source',
      'role': 'assistant',
      'content': '长按这条消息',
      'createdAt': '2026-09-26T00:00:00Z',
      'version': 1,
    });
    await tester.pumpAndSettle();
    await write;
    await tester.pumpAndSettle();
    await tester.longPress(find.text('长按这条消息', findRichText: true).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('message-action-panel')), findsOneWidget);
    final panel = tester.widget<LuminaSurface>(
      find.byKey(const ValueKey('message-action-panel')),
    );
    expect(panel.glass, isFalse);
    expect(panel.liquidGlass, isFalse);
    expect(find.text('复制'), findsOneWidget);
    await tester.tap(find.text('引用'));
    await tester.pumpAndSettle();
    expect(find.text('回复 Hermes'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'reset cancellation sends nothing and system back returns to conversations',
    (tester) async {
      final h = await openChat(tester);
      h.realtime.fail = false;
      await tester.tap(iconAction('附件与快捷指令'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('指令'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('重置上下文').first);
      await tester.tap(find.text('重置上下文').first);
      await tester.pumpAndSettle();
      expect(find.text('重置 Hermes 上下文？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(h.realtime.sent, isEmpty);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(iconAction('返回会话列表'), findsNothing);
      expect(find.text('离线会话'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('model and reasoning update only after Hermes confirms', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final h = await openChat(tester);
    h.realtime.fail = false;
    await tester.tap(iconAction('附件与快捷指令'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('指令'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('切换模型'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, 'openai/gpt-4.1');
    await tester.tap(find.widgetWithText(LuminaButton, '切换模型').last);
    await tester.pump();
    expect(h.realtime.sent.last['command'], '/model openai/gpt-4.1');
    expect(find.text('已切换到 openai/gpt-4.1'), findsNothing);
    final modelId = h.realtime.sent.last['requestId'] as String;
    h.realtime.ingestForTest(
      jsonEncode({
        'type': 'event',
        'payload': {
          'kind': 'hermes.command.result',
          'id': modelId,
          'command': '/model openai/gpt-4.1',
          'status': 'completed',
          'content': 'Model switched to `openai/gpt-4.1`',
        },
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('已切换到 openai/gpt-4.1'), findsOneWidget);
    expect(find.text('最近使用'), findsOneWidget);
    await tester.tap(find.text('高'));
    await tester.pump();
    expect(h.realtime.sent.last['command'], '/reasoning high');
    final reasoningId = h.realtime.sent.last['requestId'] as String;
    h.realtime.ingestForTest(
      jsonEncode({
        'type': 'event',
        'payload': {
          'kind': 'hermes.command.result',
          'id': reasoningId,
          'command': '/reasoning high',
          'status': 'completed',
          'content': 'Reasoning effort set to `high` (session only)',
        },
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('当前会话已更新思考强度'), findsOneWidget);
    final models = await tester.runAsync(() => RecentHermesModels().load());
    expect(models, contains('openai/gpt-4.1'));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('keyboard raises latest message and preserves history reading', (
    tester,
  ) async {
    final h = await openChat(tester);
    addTearDown(tester.view.reset);
    final seed = () async {
      for (var i = 0; i < 35; i++) {
        await h.repo.applyRemoteMessage({
          'conversationId': h.id,
          'id': 'ime-$i',
          'role': 'assistant',
          'content': '键盘消息 $i',
          'createdAt': DateTime.utc(2026, 9, 26, 0, i).toIso8601String(),
          'version': 1,
        });
      }
    }();
    await tester.pumpAndSettle();
    await seed;
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    expect(position.extentAfter, lessThan(1));
    final inputTop = tester.getTopLeft(find.byType(LuminaTextField).last).dy;
    for (final inset in [40.0, 80.0, 160.0, 240.0, 300.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
    }
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byType(LuminaTextField).last).dy,
      lessThan(inputTop - 200),
    );
    expect(position.extentAfter, lessThan(1));
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    final historyPosition = position.pixels;
    expect(position.extentAfter, greaterThan(72));
    for (final inset in [240.0, 160.0, 80.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
    }
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(historyPosition, 1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'chat composer reopens the dismissed keyboard without losing the draft',
    (tester) async {
      await openChat(tester);
      final composer = find.byType(EditableText).last;
      await tester.tap(composer);
      await tester.pumpAndSettle();
      await tester.enterText(composer, '还没发送的草稿');
      final focus = tester.widget<EditableText>(composer).focusNode;
      tester.testTextInput.hide();
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(composer);
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.widget<EditableText>(composer).controller.text, '还没发送的草稿');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  test('shortcuts exclude CLI-only commands and global model mutation', () {
    final commands = hermesShortcuts.map((item) => item.command.trim()).toSet();
    expect(
      commands,
      containsAll([
        '/status',
        '/model',
        '/compress',
        '/resume',
        '/title',
        '/help',
      ]),
    );
    expect(
      commands.intersection({
        '/clear',
        '/config',
        '/tools',
        '/cron',
        '/plugins',
      }),
      isEmpty,
    );
    expect(
      hermesShortcuts.any((item) => item.command.contains('--global')),
      isFalse,
    );
  });
}
