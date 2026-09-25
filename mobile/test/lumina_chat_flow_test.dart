import 'dart:convert';
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
import 'package:orialis_mobile/features/chat/data/chat_repository.dart';
import 'package:orialis_mobile/features/chat/presentation/agent_event_cards.dart';
import 'package:orialis_mobile/features/chat/presentation/safe_markdown.dart';

class _Config extends AppConfig {
  @override
  Future<String?> sessionToken() async => null;
  @override
  Future<String?> sessionUsername() async => null;
  @override
  Future<String> deviceId() async => 'offline-chat-test';
}

class _Realtime extends MobileRealtimeClient {
  _Realtime() : super(config: _Config());
  int attempts = 0;
  bool fail = true;
  final List<Map<String, dynamic>> sent = [];
  @override
  Future<void> sendEvent({
    required String kind,
    Map<String, dynamic> payload = const {},
    String? requestId,
  }) async {
    attempts++;
    if (fail) throw StateError('offline');
    sent.add({'kind': kind, 'requestId': requestId, ...payload});
  }
}

class _Sync extends SyncCoordinator {
  _Sync({required super.realtime, required super.chatRepository})
    : super(sync: () async => SyncState.offline);
  int attempts = 0;
  @override
  Future<void> start() async {}
  @override
  Future<SyncState> requestSync() async {
    attempts++;
    return SyncState.offline;
  }
}

Finder iconAction(String label) =>
    find.byWidgetPredicate((w) => w is LuminaIconButton && w.tooltip == label);

Future<
  ({
    AppDatabase db,
    ChatRepository repo,
    _Realtime realtime,
    _Sync sync,
    String id,
  })
>
openChat(WidgetTester tester, {bool largeDark = false}) async {
  tester.view.physicalSize = const Size(432, 960);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (largeDark) {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  final db = AppDatabase(executor: NativeDatabase.memory());
  final repo = ChatRepository(database: db);
  final conversation = (await tester.runAsync(
    () => repo.createConversation(title: '离线会话'),
  ))!;
  final realtime = _Realtime();
  final sync = _Sync(realtime: realtime, chatRepository: repo);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appConfigProvider.overrideWithValue(_Config()),
        realtimeClientProvider.overrideWithValue(realtime),
        syncCoordinatorProvider.overrideWithValue(sync),
      ],
      child: const OrialisApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('聊天').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('离线会话').first);
  await tester.pumpAndSettle();
  expect(iconAction('返回会话列表'), findsOneWidget);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await realtime.dispose();
    await sync.dispose();
    await db.close();
  });
  return (
    db: db,
    repo: repo,
    realtime: realtime,
    sync: sync,
    id: conversation.id,
  );
}

void main() {
  testWidgets(
    'detail hides navigation, opens latest and preserves history position',
    (tester) async {
      final h = await openChat(tester);
      expect(find.text('今日'), findsNothing);
      Future<void> addMessage(int i) => h.repo.applyRemoteMessage({
        'conversationId': h.id,
        'id': 'scroll-$i',
        'role': 'user',
        'content': '消息 $i：用于验证进入会话和历史阅读的位置。',
        'createdAt': DateTime.utc(2026, 9, 24, 0, i).toIso8601String(),
        'version': 1,
      });
      final seeded = () async {
        for (var i = 0; i < 35; i++) {
          await addMessage(i);
        }
      }();
      await tester.pumpAndSettle();
      await seeded;
      await tester.pumpAndSettle();
      final scrollable = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable.first).position;
      expect(position.extentAfter, lessThan(1));
      expect(find.textContaining('↑'), findsWidgets);
      expect(find.textContaining('✓'), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, 450));
      await tester.pumpAndSettle();
      final before = position.pixels;
      final incoming = addMessage(35);
      await tester.pumpAndSettle();
      await incoming;
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(before, 1));
      expect(find.text('新消息 ↓'), findsOneWidget);
      await tester.tap(find.text('新消息 ↓'));
      await tester.pumpAndSettle();
      expect(position.extentAfter, lessThan(1));
      await tester.tap(iconAction('返回会话列表'));
      await tester.pumpAndSettle();
      expect(find.text('今日'), findsOneWidget);
      await tester.tap(find.text('离线会话').first);
      await tester.pumpAndSettle();
      final reopened = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      expect(reopened.extentAfter, lessThan(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'offline conversation send, retry and system back preserve one local message',
    (tester) async {
      final h = await openChat(tester);
      await tester.enterText(find.byType(EditableText).first, '离线消息不会丢失');
      await tester.tap(iconAction('发送'));
      await tester.pumpAndSettle();
      expect(
        (await tester.runAsync(
          () => h.repo.watchMessages(h.id).first,
        ))!.single.content,
        '离线消息不会丢失',
      );
      final before = h.sync.attempts;
      await tester.tap(find.text('待发送 · 重试'));
      await tester.pumpAndSettle();
      expect(h.sync.attempts, before + 1);
      expect(
        await tester.runAsync(() => h.repo.watchMessages(h.id).first),
        hasLength(1),
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(iconAction('返回会话列表'), findsNothing);
      expect(find.text('离线消息不会丢失'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'attachment permission refusal returns to the same conversation',
    (tester) async {
      await openChat(tester);
      await tester.tap(iconAction('添加照片或文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('拍照'));
      await tester.pumpAndSettle();
      expect(find.text('允许访问相机？'), findsOneWidget);
      await tester.tap(find.text('暂不允许'));
      await tester.pumpAndSettle();
      expect(find.text('允许访问相机？'), findsNothing);
      expect(iconAction('发送'), findsOneWidget);
      expect(find.byType(EditableText), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'approval failure restores choices and successful retry closes sheet',
    (tester) async {
      final h = await openChat(tester);
      h.realtime.ingestForTest(
        jsonEncode({
          'type': 'event',
          'payload': {
            'kind': 'approval.request',
            'conversationId': h.id,
            'id': 'approval-1',
            'title': '同步这次修改到服务器？',
          },
        }),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AgentApprovalSheet), findsOneWidget);
      await tester.tap(find.text('这一次'));
      await tester.pumpAndSettle();
      expect(find.text('暂时无法发送，请重试。'), findsOneWidget);
      expect(h.realtime.attempts, 1);
      h.realtime.fail = false;
      await tester.tap(find.text('这一次'));
      await tester.pumpAndSettle();
      expect(h.realtime.attempts, 2);
      expect(h.realtime.sent.single['decision'], 'once');
      expect(h.realtime.sent.single['conversationId'], h.id);
      expect(find.byType(AgentApprovalSheet), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'dark large text supports long messages and header-only markdown table',
    (tester) async {
      final h = await openChat(tester, largeDark: true);
      await tester.enterText(
        find.byType(EditableText).first,
        List.filled(8, '这是一条需要换行的长消息。').join(),
      );
      await tester.tap(iconAction('发送'));
      await tester.pumpAndSettle();
      expect(
        await tester.runAsync(() => h.repo.watchMessages(h.id).first),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      expect(MarkdownBlock.parse('| 标题 |\n| --- |'), hasLength(1));
      await tester.tap(iconAction('添加照片或文件'));
      await tester.pumpAndSettle();
      expect(find.text('选择文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
