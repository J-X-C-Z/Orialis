import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/features/chat/data/chat_repository.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';
import 'package:orialis_mobile/features/projects/data/project_repository.dart';

const server = String.fromEnvironment('ORIALIS_TEST_SERVER');

class _Config extends AppConfig {
  _Config(this.token);
  final String token;
  final id = const Uuid().v7();
  @override
  Future<String> serverUrl() async => server;
  @override
  Future<String> deviceId() async => id;
  @override
  Future<String?> sessionToken() async => token;
}

void main() {
  test(
    'two devices preserve manual order, reset and canonical message quotes',
    () async {
      expect([
        '127.0.0.1',
        'localhost',
        '::1',
      ], contains(Uri.parse(server).host));
      final registration = Dio(BaseOptions(baseUrl: server));
      final user = await registration.post(
        '/api/v1/auth/register',
        data: {
          'username': 'order-${const Uuid().v7().substring(0, 18)}',
          'password': 'local-test-only-password',
        },
      );
      registration.close();
      final token = user.data['accessToken'] as String;
      final first = AppDatabase(executor: AppDatabase.inMemoryExecutor());
      final second = AppDatabase(executor: AppDatabase.inMemoryExecutor());
      addTearDown(first.close);
      addTearDown(second.close);
      final ca = _Config(token), cb = _Config(token);
      final aa = OrialisApiClient(baseUrl: server, deviceId: ca.id, config: ca);
      final ab = OrialisApiClient(baseUrl: server, deviceId: cb.id, config: cb);
      final ea = SyncEngine(database: first, config: ca, apiClient: aa);
      final eb = SyncEngine(database: second, config: cb, apiClient: ab);
      final tasks = EventRepository(database: first, config: ca);
      final projects = ProjectRepository(first);
      final chats = ChatRepository(database: first);
      await tasks.createTask(title: 'First', due: '2026-09-01');
      await tasks.createTask(title: 'Second', due: '2026-09-02');
      final taskIds = (await tasks.watchTasks().first)
          .map((t) => t.id)
          .toList();
      final p1 = await projects.createProject(name: 'First');
      final p2 = await projects.createProject(name: 'Second');
      final c1 = await chats.createConversation(title: 'First');
      final c2 = await chats.createConversation(title: 'Second');
      await tasks.reorderTasks(taskIds.reversed.toList());
      await projects.reorderProjects([p2.id, p1.id]);
      await chats.setPinned(c1, true);
      await chats.setPinned(c2, true);
      await chats.reorderPinnedConversations([c1.id, c2.id]);
      final original = await chats.sendMessage(
        conversationId: c1.id,
        content: '原消息',
      );
      await chats.sendMessage(
        conversationId: c1.id,
        content: '请解释',
        replyToMessageId: original.id,
        replyQuote: '原消息',
        replyRole: 'user',
      );
      expect(await ea.syncOnce(), SyncState.idle, reason: 'initial upload');
      expect(
        await eb.syncOnce(),
        SyncState.idle,
        reason: 'second device snapshot',
      );
      final rb = EventRepository(database: second, config: cb);
      expect((await rb.watchTasks().first).map((t) => t.id), taskIds.reversed);
      expect(
        (await ProjectRepository(
          second,
        ).watchProjects().first).map((p) => p.id),
        [p2.id, p1.id],
      );
      final remoteChats = await ChatRepository(
        database: second,
      ).watchConversations().first;
      expect(remoteChats.take(2).map((c) => c.id), [c1.id, c2.id]);
      final remoteQuote = (await ChatRepository(
        database: second,
      ).watchMessages(c1.id).first).singleWhere((m) => m.content == '请解释');
      expect(remoteQuote.replyToMessageId, original.id);
      expect(remoteQuote.replyQuote, '原消息');
      expect(remoteQuote.replyRole, 'user');
      await tasks.resetTaskOrder(taskIds);
      await projects.resetProjectOrder();
      await chats.resetConversationOrder();
      expect(await ea.syncOnce(), SyncState.idle, reason: 'reset upload');
      expect(await eb.syncOnce(), SyncState.idle, reason: 'incremental reset');
      expect(
        (await rb.watchTasks().first).every((t) => t.manualPosition == null),
        isTrue,
      );
      expect(
        (await ProjectRepository(
          second,
        ).watchProjects().first).every((p) => p.manualPosition == null),
        isTrue,
      );
      expect(
        (await ChatRepository(
          database: second,
        ).watchConversations().first).every((c) => c.manualPosition == null),
        isTrue,
      );
    },
    skip: server.isEmpty
        ? 'Set ORIALIS_TEST_SERVER to isolated loopback server'
        : false,
  );
}
