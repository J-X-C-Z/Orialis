import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/presentation/response_ui_view.dart';
import 'package:orialis_mobile/features/chat/presentation/agent_status_ring.dart';
import 'package:orialis_mobile/features/chat/data/agent_chat_service.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lumina_chat_flow_test.dart' show openChat, iconAction;

class _StatusAgentService extends AgentChatService {
  _StatusAgentService() : super(AppConfig());
  @override
  Future<(String, String)> identity() async => ('status-test', 'session');
  @override
  Future<bool?> devicePresence(String deviceId) async => true;
  @override
  Future<String?> target(String id, {bool requireOnline = false}) async =>
      'JXCZ_MBA_Hermes';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  testWidgets(
    'saved assistant UI restores and choices preserve draft without sending',
    (tester) async {
      final h = await openChat(tester);
      final json = File('../docs/contracts/response-ui-v1.example.json')
          .readAsStringSync();
      final content = '按你的时间安排：\n\n```orialis-ui\n$json\n```\n\n也可以继续调整。';
      final write = h.repo.applyRemoteMessage({
        'conversationId': h.id,
        'id': 'response-ui-assistant',
        'role': 'assistant',
        'content': content,
        'createdAt': '2026-10-23T00:00:00Z',
        'version': 1,
      });
      await tester.pumpAndSettle();
      await write;
      await tester.pumpAndSettle();
      expect(find.byType(ResponseUiView), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(ResponseUiView),
          matching: find.byType(LuminaChatBubble),
        ),
        findsNothing,
      );
      await tester.enterText(find.byType(EditableText).first, '保留的草稿');
      final attempts = h.realtime.attempts;
      await tester.ensureVisible(find.text('展开详细安排'));
      await tester.tap(find.text('展开详细安排'));
      await tester.pumpAndSettle();
      final composer = tester.widget<EditableText>(
        find.byType(EditableText).first,
      );
      expect(composer.controller.text, '保留的草稿\n请展开今天的详细学习安排');
      expect(h.realtime.attempts, attempts);
      final saved = (await tester.runAsync(
        () => h.db.select(h.db.messages).get(),
      ))!;
      expect(saved.single.content, content);
      await tester.tap(iconAction('返回会话列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('离线会话').first);
      await tester.pumpAndSettle();
      expect(find.byType(ResponseUiView), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('user content cannot create assistant response controls', (
    tester,
  ) async {
    final h = await openChat(tester);
    final json = File('../docs/contracts/response-ui-v1.example.json')
        .readAsStringSync();
    final content = '```orialis-ui\n$json\n```';
    final write = h.repo.applyRemoteMessage({
      'conversationId': h.id,
      'id': 'response-ui-user',
      'role': 'user',
      'content': content,
      'createdAt': '2026-10-23T00:00:00Z',
      'version': 1,
    });
    await tester.pumpAndSettle();
    await write;
    await tester.pumpAndSettle();
    expect(find.byType(ResponseUiView), findsNothing);
    expect(find.text(content), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text(content),
        matching: find.byType(LuminaChatBubble),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'status refresh waits for the matching device response and can retry failure',
    (tester) async {
      final h = await openChat(tester, agentService: _StatusAgentService());
      h.realtime.fail = false;
      await tester.enterText(find.byType(EditableText).first, '未发送的草稿');
      await tester.tap(find.byType(AgentStatusRing));
      await tester.pumpAndSettle();
      await tester.tap(find.text('刷新'));
      await tester.pumpAndSettle();
      expect(find.text('刷新中'), findsOneWidget);
      final request = h.realtime.sent.single;
      expect(request['kind'], 'session.status');
      expect(request['conversationId'], h.id);
      void snapshot(String requestId, String status) =>
          h.realtime.ingestForTest(
            jsonEncode({
              'type': 'event',
              'payload': {
                'kind': 'session.status',
                'event': 'session.status',
                'requestId': requestId,
                'conversationId': h.id,
                'id': h.id,
                'status': status,
                'message': '设备实际返回的运行摘要',
              },
            }),
          );
      snapshot('unrelated-request', 'working');
      // A working assistant keeps the header ring moving until a terminal event.
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('刷新中'), findsOneWidget);
      expect(find.textContaining('已刷新'), findsNothing);
      snapshot(request['requestId'] as String, 'idle');
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.text('空闲'), findsOneWidget);
      expect(find.textContaining('已刷新'), findsOneWidget);
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).first)
            .controller
            .text,
        '未发送的草稿',
      );
      await tester.tap(find.text('刷新'));
      await tester.pumpAndSettle();
      h.realtime.ingestForTest(
        jsonEncode({
          'type': 'error',
          'request_id': h.realtime.sent.last['requestId'],
          'payload': {'code': 'agent_unavailable', 'message': 'offline'},
        }),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.text('刷新失败，请重试'), findsOneWidget);
      expect(find.text('刷新'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
