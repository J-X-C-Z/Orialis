import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/app/design/design_components.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';
import 'package:orialis_mobile/core/sync/sync_coordinator.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/features/chat/data/agent_chat_service.dart';
import 'package:orialis_mobile/features/chat/data/chat_repository.dart';
import 'package:orialis_mobile/pages/chat/chat_page.dart';

class _OfflineConfig extends AppConfig {
  @override
  Future<String?> sessionToken() async => null;
  @override
  Future<String?> sessionUsername() async => null;
  @override
  Future<String> deviceId() async => 'device-chat-widget';
}

class _Agents extends AgentChatService {
  _Agents() : super(_OfflineConfig());
  final created = <String>[];
  final bindings = <String, String>{};
  bool fail = false;
  @override
  Future<List<ChatAgentDevice>> devices() async => const [
    ChatAgentDevice(id: 'JXCZ_MBA_Hermes', platform: 'macos', online: true),
    ChatAgentDevice(id: 'JXCZ_AOZORA_Hermes', platform: 'linux', online: false),
  ];
  @override
  Future<String?> target(String conversationId) async => bindings[conversationId];
  @override
  Future<Map<String, dynamic>> createConversation(ChatAgentDevice device) async {
    if (fail) throw StateError('binding unavailable');
    created.add(device.id);
    final id = 'remote-${created.length}';
    bindings[id] = device.id;
    return {
      'id': id,
      'title': device.label,
      'type': 'normal',
      'createdAt': '2026-10-03T00:00:00Z',
      'updatedAt': '2026-10-03T00:00:00Z',
      'version': 1,
    };
  }
}

class _OfflineSync extends SyncCoordinator {
  _OfflineSync(MobileRealtimeClient realtime)
      : super(realtime: realtime, sync: () async => SyncState.offline);
  @override
  Future<void> start() async {}
  @override
  Future<SyncState> requestSync() async => SyncState.offline;
}

Finder _action(String label) => find.byWidgetPredicate(
  (widget) => widget is LuminaIconButton && widget.tooltip == label,
);

Future<void> _send(WidgetTester tester) async {
  await tester.tap(_action('发送'));
  await tester.pumpAndSettle();
}

String _draft(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText).first).controller.text;

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

Future<({ChatRepository repo, _Agents agents, String originalId})> _open(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(432, 960);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = AppDatabase(executor: NativeDatabase.memory());
  final repo = ChatRepository(database: db);
  final original = (await tester.runAsync(
    () => repo.createConversation(title: '原会话'),
  ))!;
  final agents = _Agents();
  final realtime = MobileRealtimeClient(config: _OfflineConfig());
  final sync = _OfflineSync(realtime);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      appConfigProvider.overrideWithValue(_OfflineConfig()),
      agentChatServiceProvider.overrideWithValue(agents),
      realtimeClientProvider.overrideWithValue(realtime),
      syncCoordinatorProvider.overrideWithValue(sync),
    ],
    child: const OrialisApp(),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('聊天').last);
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await sync.dispose();
    await realtime.dispose();
    await db.close();
  });
  return (repo: repo, agents: agents, originalId: original.id);
}

void main() {
  testWidgets('device entry creates a separate Mac conversation and reopens its binding', (tester) async {
    final h = await _open(tester);
    await tester.tap(_action('与设备对话'));
    await tester.pumpAndSettle();
    expect(find.text('Mac 电脑'), findsOneWidget);
    expect(find.text('Aozora 服务器'), findsOneWidget);
    expect(find.text('JXCZ_MBA_Hermes · 在线'), findsOneWidget);
    expect(find.text('JXCZ_AOZORA_Hermes · 离线'), findsOneWidget);
    await tester.tap(find.text('Mac 电脑'));
    await tester.pumpAndSettle();
    expect(h.agents.created, ['JXCZ_MBA_Hermes']);
    expect(find.text('Mac 电脑 · Mac 电脑'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).first, '只发给 Mac');
    await _send(tester);
    final macMessages = await tester.runAsync(() => h.repo.watchMessages('remote-1').first);
    expect(macMessages!.single.content, '只发给 Mac');
    expect(await tester.runAsync(() => h.repo.watchMessages(h.originalId).first), isEmpty);
    await tester.tap(_action('返回会话列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('原会话').first);
    await tester.pumpAndSettle();
    expect(find.text('只发给 Mac'), findsNothing);
    expect(_action('选择聊天设备'), findsOneWidget);
    await tester.tap(_action('返回会话列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mac 电脑').first);
    await tester.pumpAndSettle();
    expect(find.text('只发给 Mac'), findsOneWidget);
    expect(_action('Mac 电脑'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('offline Aozora and cancelling chooser preserve current conversation and draft', (tester) async {
    final h = await _open(tester);
    await tester.tap(find.text('原会话').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, '保留的草稿');
    await tester.tap(_action('选择聊天设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aozora 服务器'));
    await tester.pumpAndSettle();
    expect(h.agents.created, isEmpty);
    expect(find.text('JXCZ_AOZORA_Hermes · 离线'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('原会话'), findsOneWidget);
    expect(_draft(tester), '保留的草稿');
    expect(await tester.runAsync(() => h.repo.watchConversations().first), hasLength(1));
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('binding failure leaves original draft usable and imports no conversation', (tester) async {
    final h = await _open(tester);
    h.agents.fail = true;
    await tester.tap(find.text('原会话').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, '绑定失败仍保留');
    await tester.tap(_action('选择聊天设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mac 电脑'));
    await tester.pumpAndSettle();
    expect(find.text('原会话'), findsOneWidget);
    expect(_draft(tester), '绑定失败仍保留');
    expect(await tester.runAsync(() => h.repo.watchConversations().first), hasLength(1));
    await _send(tester);
    final messages = await tester.runAsync(() => h.repo.watchMessages(h.originalId).first);
    expect(messages!.single.content, '绑定失败仍保留');
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });
}
