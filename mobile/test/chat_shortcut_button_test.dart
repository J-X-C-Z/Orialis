import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/app/app.dart' show chatRepositoryProvider;
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/chat/data/agent_chat_service.dart';
import 'package:orialis_mobile/features/chat/data/chat_repository.dart';
import 'package:orialis_mobile/features/chat/presentation/chat_shortcut_button.dart';
import 'package:orialis_mobile/features/events/presentation/quick_event_button.dart';
import 'package:orialis_mobile/pages/chat/chat_page.dart'
    show agentChatServiceProvider;

class _Agents extends AgentChatService {
  _Agents() : super(AppConfig());
  bool offline = false;
  int creates = 0;
  Completer<void>? gate;
  @override
  Future<(String, String)> identity() async =>
      ('https://test.invalid', 'token');
  @override
  Future<ChatAgentDevice> defaultDevice() async {
    if (offline) throw StateError('Aozora 离线，请稍后重试');
    return ChatAgentDevice(id: azureDeviceId, platform: 'linux', online: true);
  }

  @override
  Future<Map<String, dynamic>> createConversation(
    ChatAgentDevice device,
  ) async {
    expect(device.id, azureDeviceId);
    creates++;
    await gate?.future;
    return {
      'id': 'new-aozora',
      'title': 'Aozora',
      'type': 'normal',
      'createdAt': '2026-10-30T00:00:00Z',
      'updatedAt': '2026-10-30T00:00:00Z',
      'version': 1,
    };
  }
}

void main() {
  testWidgets('tap adds event; hold opens default chat rather than tooltip', (
    tester,
  ) async {
    var taps = 0, holds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LuminaTheme(
          data: const LuminaThemeData(motionScale: 0),
          child: Center(
            child: ChatShortcutButton(
              tooltip: '快捷添加',
              onPressed: () => taps++,
              onDefaultChat: () => holds++,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(ChatShortcutButton));
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(ChatShortcutButton));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(holds, 1);
  });

  Future<(_Agents, GoRouter)> host(WidgetTester tester) async {
    final agents = _Agents();
    final database = AppDatabase(executor: NativeDatabase.memory());
    final repository = ChatRepository(database: database);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Center(child: QuickEventButton()),
        ),
        GoRoute(
          path: '/chat',
          builder: (_, state) =>
              Text('opened ${state.uri.queryParameters['conversationId']}'),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          agentChatServiceProvider.overrideWithValue(agents),
          chatRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (_, child) => LuminaTheme(
            data: const LuminaThemeData(motionScale: 0),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      agents.dispose();
      await database.close();
    });
    return (agents, router);
  }

  testWidgets('hold opens bound chat; repeated hold creates once', (
    tester,
  ) async {
    final (agents, router) = await host(tester);
    agents.gate = Completer<void>();
    await tester.longPress(find.byType(ChatShortcutButton));
    await tester.pump();
    await tester.longPress(find.byType(ChatShortcutButton));
    expect(agents.creates, 1);
    agents.gate!.complete();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/chat');
    expect(find.text('opened new-aozora'), findsOneWidget);
    expect(find.byType(QuickEventEditor), findsNothing);
  });

  testWidgets('offline default does not create or switch devices', (
    tester,
  ) async {
    final (agents, router) = await host(tester);
    agents.offline = true;
    await tester.longPress(find.byType(ChatShortcutButton));
    await tester.pumpAndSettle();
    expect(agents.creates, 0);
    expect(router.routeInformationProvider.value.uri.path, '/');
    expect(find.text('Aozora 离线，请稍后重试'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}
