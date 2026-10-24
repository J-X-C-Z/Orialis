import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';
import 'package:orialis_mobile/features/chat/data/agent_chat_service.dart';
import 'package:orialis_mobile/features/chat/presentation/agent_status_ring.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lumina_chat_flow_test.dart' show openChat;

class _OnlineAgentService extends AgentChatService {
  _OnlineAgentService() : super(AppConfig());

  @override
  Future<(String, String)> identity() async => ('flow-test', 'flow-session');

  @override
  Future<bool?> devicePresence(String deviceId) async => true;

  @override
  Future<String?> target(String id, {bool requireOnline = false}) async =>
      'JXCZ_MBA_Hermes';

  @override
  Future<List<ChatAgentDevice>> devices() async => const [
    ChatAgentDevice(id: 'JXCZ_MBA_Hermes', platform: 'macos', online: true),
  ];
}

Future<void> _pumpFrames(WidgetTester tester) async {
  // The header ring intentionally animates throughout an active response.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void _event(
  MobileRealtimeClient realtime,
  String conversationId,
  String kind, [
  Map<String, dynamic> payload = const {},
]) => realtime.ingestForTest(
  jsonEncode({
    'type': 'event',
    'payload': {'kind': kind, 'conversationId': conversationId, ...payload},
  }),
);

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('long streams follow the bottom and respect reading history', (
    tester,
  ) async {
    final h = await openChat(tester, agentService: _OnlineAgentService());
    await tester.runAsync(
      () => h.repo.applyRemoteMessage({
        'conversationId': h.id,
        'id': 'stream-prompt',
        'role': 'user',
        'content': '请详细说明。',
        'createdAt': '2026-10-23T00:00:00Z',
        'version': 1,
      }),
    );
    await _pumpFrames(tester);

    for (var sequence = 0; sequence < 8; sequence++) {
      _event(h.realtime, h.id, 'stream.delta', {
        'streamId': 'long-reply',
        'sequence': sequence,
        'delta': List.filled(6, '第 $sequence 段：这是一条逐步生成的长回复。\n\n').join(),
      });
      await _pumpFrames(tester);
      expect(_position(tester).extentAfter, lessThan(1));
    }

    await tester.drag(find.byType(ListView).first, const Offset(0, 450));
    await _pumpFrames(tester);
    final position = _position(tester);
    final before = position.pixels;
    expect(position.extentAfter, greaterThan(72));
    _event(h.realtime, h.id, 'stream.delta', {
      'streamId': 'long-reply',
      'sequence': 8,
      'delta': List.filled(6, '继续生成的内容。\n\n').join(),
    });
    await _pumpFrames(tester);
    expect(position.pixels, closeTo(before, 1));
    expect(find.text('新消息 ↓'), findsOneWidget);
    await tester.tap(find.text('新消息 ↓'));
    await _pumpFrames(tester);
    expect(position.extentAfter, lessThan(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpFrames(tester);
  });

  testWidgets('composer growth follows latest without a new message', (
    tester,
  ) async {
    final h = await openChat(tester, agentService: _OnlineAgentService());
    for (var i = 0; i < 16; i++) {
      final write = h.repo.applyRemoteMessage({
        'conversationId': h.id,
        'id': 'composer-$i',
        'role': 'assistant',
        'content': '用于验证输入框增高时的最新消息位置 $i',
        'createdAt': DateTime.utc(2026, 10, 23, 0, i).toIso8601String(),
        'version': 1,
      });
      await _pumpFrames(tester);
      await write;
      await _pumpFrames(tester);
    }
    final position = _position(tester);
    expect(position.extentAfter, lessThan(1));
    await tester.enterText(
      find.byType(EditableText).last,
      '第一行\n第二行\n第三行\n第四行',
    );
    await _pumpFrames(tester);
    expect(position.extentAfter, lessThan(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpFrames(tester);
  });

  testWidgets(
    'reported terminal and idle statuses supersede stale running tools',
    (tester) async {
      final h = await openChat(tester, agentService: _OnlineAgentService());
      for (final status in [
        'failed',
        'cancelled',
        'canceled',
        'stopped',
        'completed',
        'ended',
        'ready',
        'idle',
        'unknown',
      ]) {
        _event(h.realtime, h.id, 'tool.start', {
          'toolId': 'stale-tool',
          'name': '检查文件',
        });
        await _pumpFrames(tester);
        expect(
          tester.widget<AgentStatusRing>(find.byType(AgentStatusRing)).status,
          AgentRingStatus.answering,
        );
        _event(h.realtime, h.id, 'agent.status', {'status': status});
        await _pumpFrames(tester);
        expect(
          tester.widget<AgentStatusRing>(find.byType(AgentStatusRing)).status,
          status == 'failed' ? AgentRingStatus.error : AgentRingStatus.online,
          reason: 'An explicit $status must supersede stale tool activity',
        );
      }
      _event(h.realtime, h.id, 'stream.error', {
        'streamId': 'failed-stream',
        'message': '测试错误',
      });
      await _pumpFrames(tester);
      expect(
        tester.widget<AgentStatusRing>(find.byType(AgentStatusRing)).status,
        AgentRingStatus.error,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpFrames(tester);
    },
  );
}
