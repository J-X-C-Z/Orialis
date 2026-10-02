import 'dart:convert';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/chat/data/chat_repository.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';
import 'package:orialis_mobile/features/projects/data/project_repository.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(executor: AppDatabase.inMemoryExecutor()));
  tearDown(() => db.close());
  test(
    'task reorder is transactional, survives edits and reset writes null to outbox',
    () async {
      final repo = EventRepository(database: db, config: AppConfig());
      await repo.createTask(title: 'A', due: '2026-09-01');
      await repo.createTask(title: 'B', due: '2026-09-02');
      final original = await repo.watchTasks().first;
      await repo.reorderTasks(original.reversed.map((t) => t.id).toList());
      final ordered = await repo.watchTasks().first;
      expect(ordered.map((t) => t.title), ['B', 'A']);
      await expectLater(
        repo.reorderTasks([original.first.id, 'missing']),
        throwsStateError,
      );
      expect((await repo.watchTasks().first).map((t) => t.title), ['B', 'A']);
      await repo.resetTaskOrder(original.map((t) => t.id).toList());
      expect((await repo.watchTasks().first).map((t) => t.title), ['A', 'B']);
      final mutations = await db.select(db.outboxMutations).get();
      expect(
        mutations.every(
          (m) => jsonDecode(m.payloadJson).containsKey('manualPosition'),
        ),
        isTrue,
      );
      expect(
        mutations.every(
          (m) => jsonDecode(m.payloadJson)['manualPosition'] == null,
        ),
        isTrue,
      );
    },
  );
  test(
    'project manual order and reset retain existing pending create mutations',
    () async {
      final repo = ProjectRepository(db);
      final a = await repo.createProject(name: 'A');
      final b = await repo.createProject(name: 'B');
      await repo.reorderProjects([b.id, a.id]);
      expect((await repo.watchProjects().first).map((p) => p.name), ['B', 'A']);
      expect(
        (await db.select(db.outboxMutations).get()).every(
          (m) => m.operation == 'create',
        ),
        isTrue,
      );
      await repo.resetProjectOrder();
      expect(
        (await repo.watchProjects().first).every(
          (p) => p.manualPosition == null,
        ),
        isTrue,
      );
    },
  );
  test(
    'only pinned conversations reorder and unpin clears manual order',
    () async {
      final repo = ChatRepository(database: db);
      final a = await repo.createConversation(title: 'A');
      final b = await repo.createConversation(title: 'B');
      await expectLater(
        repo.reorderPinnedConversations([a.id]),
        throwsStateError,
      );
      await repo.setPinned(a, true);
      await repo.setPinned(b, true);
      await repo.reorderPinnedConversations([a.id, b.id]);
      expect((await repo.watchConversations().first).map((c) => c.title), [
        'A',
        'B',
      ]);
      await repo.setPinned(a, false);
      final rows = await repo.watchConversations().first;
      expect(rows.first.id, b.id);
      expect(rows.last.manualPosition, isNull);
    },
  );
  test(
    'quotes preserve original content and remote quote relation; latest reads one',
    () async {
      final repo = ChatRepository(database: db);
      await repo.applyRemoteMessage({
        'conversationId': 'c',
        'id': 'source',
        'role': 'assistant',
        'content': 'Original',
        'createdAt': '2026-09-01T00:00:00Z',
        'version': 1,
      });
      final sent = await repo.sendMessage(
        conversationId: 'c',
        content: 'Explain',
        replyToMessageId: 'source',
        replyQuote: 'Original',
        replyRole: 'assistant',
      );
      expect(sent.content, 'Explain');
      expect(sent.replyToMessageId, 'source');
      expect((await repo.watchLatestMessage('c').first)?.id, sent.id);
      await repo.applyRemoteMessage({
        'conversationId': 'c',
        'id': 'remote',
        'role': 'user',
        'content': 'Remote reply',
        'createdAt': '2099-09-01T00:00:00Z',
        'version': 1,
        'replyToMessageId': 'source',
        'replyQuote': 'Original',
        'replyRole': 'assistant',
      });
      final last = await repo.watchLatestMessage('c').first;
      expect(last?.replyQuote, 'Original');
      expect(last?.replyToMessageId, 'source');
    },
  );
}
