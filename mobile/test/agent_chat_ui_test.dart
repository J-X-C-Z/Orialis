import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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

class _Config extends AppConfig {
  @override
  Future<String?> sessionToken() async => null;
  @override
  Future<String?> sessionUsername() async => null;
  @override
  Future<String> deviceId() async => 'agent-chat-widget-test';
}

class _Service extends AgentChatService {
  _Service() : super(_Config());
  final created = <String>[];
  final renamed = <String>[];
  String macName = 'Mac 电脑';
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
  Future<List<ChatAgentDevice>> devices() async => [
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
}

Finder action(String label) => find.byWidgetPredicate(
  (widget) => widget is LuminaIconButton && widget.tooltip == label,
);

Future<_Service> _openChat(
  WidgetTester tester, {
  bool notificationMessages = false,
  bool slowUnknown = false,
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
      for (final id in ['notice-1', 'notice-2']) {
        await repository.applyRemoteMessage({
          'conversationId': 'existing-mac',
          'id': id,
          'role': 'assistant',
          'content': '通知消息 $id',
          'createdAt': '2026-10-04T00:00:00Z',
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

  testWidgets('notification reopens a conversation and changes message focus', (
    tester,
  ) async {
    await _openChat(tester, notificationMessages: true);
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
    expect(highlighted('notice-1'), findsOneWidget);
    router.go('/chat?conversationId=existing-mac&messageId=notice-2');
    await tester.pumpAndSettle();
    expect(highlighted('notice-2'), findsOneWidget);
    expect(highlighted('notice-1'), findsNothing);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
  });

  testWidgets('device entry disables offline Azure and opens online Mac', (
    tester,
  ) async {
    final service = await _openChat(tester);
    await tester.tap(action('Mac 电脑'));
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
    expect(action('Mac 电脑'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'device edit renames its card and new chat while keeping exact ID',
    (tester) async {
      final service = await _openChat(tester);
      await tester.tap(action('Mac 电脑'));
      await tester.pumpAndSettle();
      await tester.tap(action('修改设备名称').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).last, '工作 Mac');
      await tester.tap(find.widgetWithText(LuminaButton, '保存'));
      await tester.pumpAndSettle();
      expect(service.renamed, ['工作 Mac']);
      expect(find.text('工作 Mac'), findsOneWidget);
      await tester.tap(find.text('工作 Mac'));
      await tester.pumpAndSettle();
      expect(service.created, ['JXCZ_MBA_Hermes']);
      expect(action('工作 Mac'), findsOneWidget);
      expect(find.text('工作 Mac · 工作 Mac'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'empty device name keeps dialog open and cancellation changes nothing',
    (tester) async {
      final service = await _openChat(tester);
      await tester.tap(action('Mac 电脑'));
      await tester.pumpAndSettle();
      await tester.tap(action('修改设备名称').first);
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
      expect(find.text('计划整理 · Mac 电脑'), findsOneWidget);
      await tester.tap(action('返回会话列表'));
      await tester.pumpAndSettle();
      expect(find.text('计划整理'), findsOneWidget);
      await tester.tap(find.text('计划整理'));
      await tester.pumpAndSettle();
      expect(find.text('计划整理 · Mac 电脑'), findsOneWidget);
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
    await tester.tap(action('Mac 电脑'));
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
