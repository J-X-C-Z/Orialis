import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/attachments/attachment_bridge.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';
import 'package:orialis_mobile/core/sync/sync_coordinator.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/features/chat/data/agent_chat_service.dart';
import 'package:orialis_mobile/features/chat/data/chat_repository.dart';
import 'package:orialis_mobile/features/chat/data/chat_drafts.dart';
import 'package:orialis_mobile/features/chat/application/chat_share_coordinator.dart';
import 'package:orialis_mobile/pages/chat/chat_page.dart';
import 'package:orialis_mobile/features/chat/presentation/agent_status_ring.dart';
import 'package:orialis_mobile/features/chat/presentation/chat_activity_panel.dart';

class _Config extends AppConfig {
  @override
  Future<String?> sessionToken() async => null;
  @override
  Future<String?> sessionUsername() async => null;
  @override
  Future<String> deviceId() async => 'agent-chat-widget-test';
}

class _ShareConfig extends _Config {
  @override
  Future<String?> sessionToken() async => 'test-token';
  @override
  Future<String?> sessionUsername() async => 'alice';
}

class _Service extends AgentChatService {
  _Service() : super(_Config());
  final created = <String>[];
  final renamed = <String>[];
  String macName = 'Mac 电脑';
  Completer<void>? devicesGate;
  int deviceLoads = 0;
  Completer<void>? validationGate;
  Completer<void>? unknownGate;
  @override
  Future<String?> cachedTarget(String id) async =>
      id == "existing-mac" ? "JXCZ_MBA_Hermes" : null;
  int validations = 0;
  @override
  String? targetLabel(String? id) =>
      id == 'JXCZ_MBA_Hermes' ? macName : super.targetLabel(id);
  @override
  Future<void> renameDevice(String id, String name) async {
    expect(id, 'JXCZ_MBA_Hermes');
    renamed.add(name);
    macName = name;
  }

  @override
  Future<List<ChatAgentDevice>> devices() async {
    deviceLoads++;
    await devicesGate?.future;
    return [
      ChatAgentDevice(
        id: 'JXCZ_MBA_Hermes',
        platform: 'macos',
        online: true,
        displayLabel: macName,
      ),
      const ChatAgentDevice(
        id: 'JXCZ_AOZORA_Hermes',
        platform: 'linux',
        online: false,
        displayLabel: 'Azure 服务器',
      ),
    ];
  }

  @override
  Future<String?> target(
    String conversationId, {
    bool requireOnline = false,
  }) async {
    if (requireOnline) {
      validations++;
      await validationGate?.future;
    }
    if (conversationId != "existing-mac" && conversationId != "mac-chat") {
      await unknownGate?.future;
    }
    return conversationId == 'mac-chat' || conversationId == 'existing-mac'
        ? 'JXCZ_MBA_Hermes'
        : null;
  }

  @override
  Future<Map<String, dynamic>> createConversation(
    ChatAgentDevice device,
  ) async {
    created.add(device.id);
    return {
      'id': 'mac-chat',
      'title': device.label,
      'type': 'normal',
      'createdAt': '2026-10-03T00:00:00Z',
      'updatedAt': '2026-10-03T00:00:00Z',
      'version': 1,
    };
  }
}

class _Sync extends SyncCoordinator {
  _Sync({required super.realtime, required super.chatRepository})
    : super(sync: () async => SyncState.offline);
  @override
  Future<void> start() async {}
  @override
  Future<SyncState> requestSync() async => SyncState.offline;
  @override
  Future<void> flushMessage(String conversationId, String messageId) async {}
}

Finder action(String label) => find.byWidgetPredicate(
  (widget) => widget is LuminaIconButton && widget.tooltip == label,
);

Future<_Service> _openChat(
  WidgetTester tester, {
  bool notificationMessages = false,
  int notificationMessageCount = 2,
  bool slowUnknown = false,
  ChatShareCoordinator? shares,
}) async {
  tester.view.physicalSize = const Size(432, 960);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final database = AppDatabase(executor: NativeDatabase.memory());
  final repository = ChatRepository(database: database);
  await tester.runAsync(() async {
    await repository.importDeviceConversation({
      'id': 'existing-mac',
      'title': '原会话',
      'type': 'normal',
      'createdAt': '2026-10-03T00:00:00Z',
      'updatedAt': '2026-10-03T00:00:00Z',
      'version': 1,
    });
    await repository.createConversation(title: '旧测试会话');
    if (notificationMessages) {
      for (var index = 1; index <= notificationMessageCount; index++) {
        final id = 'notice-$index';
        await repository.applyRemoteMessage({
          'conversationId': 'existing-mac',
          'id': id,
          'role': 'assistant',
          'content': '通知消息 $id',
          'createdAt': DateTime.utc(2026, 10, 4, 0, 0, index).toIso8601String(),
          'version': 1,
        });
      }
    }
  });
  final service = _Service();
  if (slowUnknown) service.unknownGate = Completer<void>();
  final realtime = MobileRealtimeClient(config: _Config());
  final sync = _Sync(realtime: realtime, chatRepository: repository);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        appConfigProvider.overrideWithValue(_Config()),
        realtimeClientProvider.overrideWithValue(realtime),
        syncCoordinatorProvider.overrideWithValue(sync),
        agentChatServiceProvider.overrideWithValue(service),
        if (shares != null)
          chatShareCoordinatorProvider.overrideWithValue(shares),
      ],
      child: const OrialisApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('聊天').last);
  await tester.pumpAndSettle();
  expect(find.text('旧测试会话'), findsNothing);
  await tester.tap(find.text('原会话').first);
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await realtime.dispose();
    await sync.dispose();
    await database.close();
  });
  return service;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  testWidgets('conversation route opens chat without needing a message ID', (
    tester,
  ) async {
    await _openChat(tester);
    final router = GoRouter.of(tester.element(find.byType(ChatPage)));
    router.go('/today');
    await tester.pumpAndSettle();
    router.go('/chat?conversationId=existing-mac');
    await tester.pumpAndSettle();
    expect(find.byType(AgentStatusRing), findsOneWidget);
    expect(find.byType(EditableText), findsOneWidget);
    expect(find.text('与设备对话'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets('runtime control is in header and absent from transcript', (
    tester,
  ) async {
    await _openChat(tester);
    expect(find.byType(AgentStatusRing), findsOneWidget);
    expect(find.byType(ChatActivityPanel), findsNothing);
    expect(find.text('原会话 · Mac 电脑'), findsNothing);
    await tester.tap(find.byType(AgentStatusRing));
    await tester.pumpAndSettle();
    expect(find.text('助手状态'), findsOneWidget);
    expect(find.byType(ChatActivityPanel), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets(
    'external share selects an existing conversation, appends its draft and never sends automatically',
    (tester) async {
      const channel = MethodChannel('test/chat-share-ui');
      const id = '0c1b166e-7ea2-4877-b386-8c83f9e2d221';
      final shares = ChatShareCoordinator(
        config: _ShareConfig(),
        channel: channel,
      );
      Map<String, Object?>? pending;
      var completions = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'pending' || call.method == 'read') {
              return pending;
            }
            if (call.method == 'complete') {
              completions++;
              pending = null;
            }
            return null;
          });
      addTearDown(() {
        shares.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      await shares.start();
      final drafts = await ChatDrafts.open(_Config());
      await drafts.saveState(
        'existing-mac',
        const ChatDraftState(
          text: '原有草稿',
          attachments: [
            AttachmentRecord(
              localPath: '/private/old.png',
              name: '旧附件.png',
              mimeType: 'image/png',
              size: 4,
            ),
          ],
        ),
      );
      final service = await _openChat(
        tester,
        shares: shares,
        notificationMessages: true,
      );
      final router = GoRouter.of(tester.element(find.byType(ChatPage)));
      router.go('/chat?conversationId=existing-mac&messageId=notice-1');
      await tester.pumpAndSettle();
      final chatState = tester.state(find.byType(ChatPage));
      router.go('/today');
      await tester.pumpAndSettle();
      pending = {'id': id, 'text': '分享的 https://b23.tv/example', 'files': []};
      await shares.open(id);
      await tester.pumpAndSettle();
      expect(shares.pending?.id, id);
      expect(tester.widget<ChatPage>(find.byType(ChatPage)).shareId, id);
      expect(tester.state(find.byType(ChatPage)), same(chatState));
      expect(find.text('选择会话接收分享'), findsOneWidget);
      expect(completions, 0);
      expect(service.validations, 0);
      await tester.tap(find.text('原会话').first);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).last)
            .controller
            .text,
        '原有草稿\n分享的 https://b23.tv/example',
      );
      expect(completions, 1);
      expect(service.validations, 0);
      expect(find.text('旧附件.png'), findsOneWidget);
      final saved = await drafts.loadState('existing-mac');
      expect(saved.attachments.single.name, '旧附件.png');
      expect(saved.appliedShareIds, contains(id));
      expect(find.text('已加入草稿，确认后发送'), findsOneWidget);
      await shares.open(id);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).last)
            .controller
            .text,
        '原有草稿\n分享的 https://b23.tv/example',
      );
      expect(completions, 1);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('cached chat opens while an unknown binding remains pending', (
    tester,
  ) async {
    final service = await _openChat(tester, slowUnknown: true);
    expect(action('返回会话列表'), findsOneWidget);
    expect(service.unknownGate!.isCompleted, isFalse);
    service.unknownGate!.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('chat composer reopens hidden IME on text and padding taps', (
    tester,
  ) async {
    await _openChat(tester);
    final editor = find.byType(EditableText).last;
    await tester.tap(editor);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.enterText(editor, '保留草稿');
    for (var i = 0; i < 3; i++) {
      tester.testTextInput.hide();
      await tester.tapAt(
        tester.getTopLeft(find.byType(LuminaTextField).last) +
            const Offset(8, 24),
      );
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.widget<EditableText>(editor).controller.text, '保留草稿');
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'notification opens latest messages without highlighting on repeated taps',
    (tester) async {
      await _openChat(
        tester,
        notificationMessages: true,
        notificationMessageCount: 80,
      );
      await tester.tap(action('返回会话列表'));
      await tester.pumpAndSettle();
      final router = GoRouter.of(tester.element(find.byType(ChatPage)));
      Finder highlighted(String id) => find.byWidgetPredicate((widget) {
        if (widget.runtimeType.toString() != '_MessageBubble') return false;
        final dynamic bubble = widget;
        return bubble.message.id == id && bubble.highlighted == true;
      });
      router.go('/chat?conversationId=existing-mac&messageId=notice-1');
      await tester.pumpAndSettle();
      expect(action('返回会话列表'), findsOneWidget);
      expect(highlighted('notice-1'), findsNothing);
      final transcript = find.byKey(const ValueKey('existing-mac'));
      ScrollPosition position() => tester
          .state<ScrollableState>(
            find
                .descendant(of: transcript, matching: find.byType(Scrollable))
                .first,
          )
          .position;
      expect(position().maxScrollExtent, greaterThan(0));
      expect(position().extentAfter, lessThan(2));
      expect(find.text('通知消息 notice-80', findRichText: true), findsOneWidget);
      await tester.drag(transcript, const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(position().extentAfter, greaterThan(100));
      router.go('/chat?conversationId=existing-mac&messageId=notice-2');
      await tester.pumpAndSettle();
      expect(highlighted('notice-2'), findsNothing);
      expect(position().extentAfter, lessThan(2));
      expect(find.text('通知消息 notice-80', findRichText: true), findsOneWidget);
      expect(
        find.byWidgetPredicate((widget) {
          if (widget.runtimeType.toString() != '_MessageBubble') return false;
          final dynamic bubble = widget;
          return bubble.highlighted == true;
        }),
        findsNothing,
      );
      expect(highlighted('notice-1'), findsNothing);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('one device entry opens sheet before slow registry responds', (
    tester,
  ) async {
    final service = await _openChat(tester);
    await tester.tap(action('返回会话列表'));
    await tester.pumpAndSettle();
    expect(action('与设备对话'), findsOneWidget);
    expect(action('新建会话'), findsNothing);
    service.devicesGate = Completer<void>();
    await tester.tap(action('与设备对话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('与设备对话'), findsOneWidget);
    expect(find.text('正在读取设备状态…'), findsOneWidget);
    expect(service.deviceLoads, 1);
    service.devicesGate!.complete();
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chat-device-JXCZ_MBA_Hermes')),
        matching: find.text('Mac 电脑'),
      ),
      findsOneWidget,
    );
    final mac = find.byKey(const ValueKey('chat-device-JXCZ_MBA_Hermes'));
    final azure = find.byKey(const ValueKey('chat-device-JXCZ_AOZORA_Hermes'));
    expect(
      tester.getTopLeft(azure).dy - tester.getBottomLeft(mac).dy,
      greaterThanOrEqualTo(16),
    );
    final rings = tester
        .widgetList<AgentStatusRing>(find.byType(AgentStatusRing))
        .toList();
    expect(rings.any((ring) => ring.status == AgentRingStatus.online), isTrue);
    expect(rings.any((ring) => ring.status == AgentRingStatus.offline), isTrue);
    await tester.tap(action('Mac 电脑 · 在线'));
    await tester.pumpAndSettle();
    expect(service.renamed, isEmpty);
    expect(service.created, isEmpty);
    expect(find.widgetWithText(LuminaButton, '保存'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('device entry disables offline Azure and opens online Mac', (
    tester,
  ) async {
    final service = await _openChat(tester);
    await tester.tap(action('更多会话操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建设备对话'));
    await tester.pumpAndSettle();
    expect(find.text('Mac 电脑'), findsOneWidget);
    expect(find.text('Azure 服务器'), findsOneWidget);
    await tester.tap(find.text('Azure 服务器'));
    await tester.pumpAndSettle();
    expect(service.created, isEmpty);
    expect(find.text('与设备对话'), findsOneWidget);
    await tester.tap(find.text('Mac 电脑'));
    await tester.pumpAndSettle();
    expect(service.created, ['JXCZ_MBA_Hermes']);
    expect(find.byType(AgentStatusRing), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'device edit renames its card and new chat while keeping exact ID',
    (tester) async {
      final service = await _openChat(tester);
      await tester.tap(action('更多会话操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建设备对话'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Mac 电脑'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).last, '工作 Mac');
      await tester.tap(find.widgetWithText(LuminaButton, '保存'));
      await tester.pumpAndSettle();
      expect(service.renamed, ['工作 Mac']);
      expect(service.deviceLoads, 1);
      expect(find.text('工作 Mac'), findsOneWidget);
      await tester.tap(find.text('工作 Mac'));
      await tester.pumpAndSettle();
      expect(service.created, ['JXCZ_MBA_Hermes']);
      expect(find.byType(AgentStatusRing), findsOneWidget);
      expect(find.text('工作 Mac'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'empty device name keeps dialog open and cancellation changes nothing',
    (tester) async {
      final service = await _openChat(tester);
      await tester.tap(action('更多会话操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建设备对话'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Mac 电脑'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).last, '   ');
      await tester.tap(find.widgetWithText(LuminaButton, '保存'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(LuminaButton, '取消'), findsOneWidget);
      expect(find.widgetWithText(LuminaButton, '保存'), findsOneWidget);
      expect(service.renamed, isEmpty);
      await tester.tap(find.widgetWithText(LuminaButton, '取消'));
      await tester.pumpAndSettle();
      expect(find.text('Mac 电脑'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'conversation name is available from its header and persists on reopening',
    (tester) async {
      await _openChat(tester);
      await tester.tap(action('更多会话操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改会话名称'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).last, '计划整理');
      await tester.tap(find.widgetWithText(LuminaButton, '保存'));
      await tester.pumpAndSettle();
      expect(find.text('计划整理'), findsOneWidget);
      await tester.tap(action('返回会话列表'));
      await tester.pumpAndSettle();
      expect(find.text('计划整理'), findsOneWidget);
      await tester.tap(find.text('计划整理'));
      await tester.pumpAndSettle();
      expect(find.text('计划整理'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'repeated send taps while verifying the target send one message',
    (tester) async {
      final service = await _openChat(tester);
      service.validationGate = Completer<void>();
      await tester.enterText(find.byType(EditableText).last, '只发送一次');
      await tester.tap(action('发送'));
      await tester.pump();
      await tester.tap(action('发送'), warnIfMissed: false);
      await tester.pump();
      expect(service.validations, 1);
      service.validationGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('只发送一次'), findsOneWidget);
      expect(service.validations, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets('choosing a device cannot silently discard an existing draft', (
    tester,
  ) async {
    final service = await _openChat(tester);
    await tester.enterText(find.byType(EditableText).last, '尚未发送的草稿');
    await tester.tap(action('更多会话操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建设备对话'));
    await tester.pumpAndSettle();
    // The UI may block switching or ask for confirmation. Neither can silently
    // remove the draft before the user has approved discarding it.
    if (find.text('Mac 电脑').evaluate().isNotEmpty) {
      await tester.tap(find.text('Mac 电脑'));
      await tester.pumpAndSettle();
    }
    expect(find.text('尚未发送的草稿'), findsOneWidget);
    expect(service.created, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
