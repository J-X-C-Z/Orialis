import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/attachments/attachment_bridge.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';
import 'package:orialis_mobile/features/chat/data/chat_repository.dart';

class _Config extends AppConfig {
  @override
  Future<String?> sessionToken() async => 'attachment-test-session';
}

void main() {
  late HttpServer server;
  late Directory root;
  late AppDatabase database;
  late ChatRepository repository;
  late SyncEngine sync;
  late String baseUrl;
  late List<String> uploadBodies;
  late List<String?> uploadKeys;
  late List<Map<String, dynamic>> messageBodies;
  late List<String?> messageKeys;
  late bool failUpload;
  late bool failMessage;
  const conversationId = 'aozora-chat';

  setUp(() async {
    failUpload = false;
    failMessage = false;
    uploadBodies = [];
    uploadKeys = [];
    messageBodies = [];
    messageKeys = [];
    root = await Directory.systemTemp.createTemp('orialis-attachment-sync-');
    database = AppDatabase(executor: AppDatabase.inMemoryExecutor());
    repository = ChatRepository(database: database);
    await repository.importDeviceConversation({
      'id': conversationId,
      'title': 'Azure 服务器',
      'type': 'normal',
      'createdAt': '2026-10-03T00:00:00Z',
      'updatedAt': '2026-10-03T00:00:00Z',
      'version': 1,
    });
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      expect(
        request.headers.value('Authorization'),
        'Session attachment-test-session',
      );
      expect(request.headers.value('X-Orialis-Device-Id'), 'test-phone');
      final body = await utf8.decoder.bind(request).join();
      Object response = {'items': []};
      if (request.uri.path == '/api/v1/conversations') response = [];
      if (request.method == 'POST' &&
          request.uri.path ==
              '/api/v1/conversations/$conversationId/attachments') {
        expect(request.headers.contentType?.mimeType, 'multipart/form-data');
        uploadBodies.add(body);
        uploadKeys.add(request.headers.value('Idempotency-Key'));
        if (failUpload) {
          request.response.statusCode = 503;
          response = {'error': 'temporarily unavailable'};
        } else {
          response = {
            'items': [
              {
                'id': 'att-server-1',
                'name': 'notes.txt',
                'mimeType': 'text/plain',
                'size': utf8.encode('附件内容').length,
                'downloadUrl':
                    '$baseUrl/api/v1/attachments/att-server-1/download',
              },
            ],
          };
        }
      } else if (request.method == 'POST' &&
          request.uri.path ==
              '/api/v1/conversations/$conversationId/messages') {
        final message = jsonDecode(body) as Map<String, dynamic>;
        messageBodies.add(message);
        messageKeys.add(request.headers.value('Idempotency-Key'));
        if (failMessage) request.response.statusCode = 503;
        response = {'id': message['id'], 'version': 1};
      } else if (request.uri.path == '/api/v1/sync/snapshot') {
        response = {
          'cursor': 0,
          'tasks': [],
          'calendarEvents': [],
          'projects': [],
          'milestones': [],
        };
      } else if (request.uri.path == '/api/v1/sync/events') {
        response = {'nextCursor': 0, 'events': [], 'hasMore': false};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
    sync = SyncEngine(
      database: database,
      config: _Config(),
      apiClient: OrialisApiClient(
        baseUrl: baseUrl,
        deviceId: 'test-phone',
        config: _Config(),
      ),
    );
  });

  tearDown(() async {
    await server.close(force: true);
    await database.close();
    await root.delete(recursive: true);
  });

  Future<Message> enqueueAttachmentOnly() async {
    final source = File('${root.path}/notes.txt')..writeAsStringSync('附件内容');
    final bridge = AttachmentBridge(
      directoryProvider: () async => Directory('${root.path}/private'),
    );
    final attachment = await bridge.importFile(source.path);
    await source.delete(); // Picker cache can disappear before sync.
    return repository.sendMessage(
      conversationId: conversationId,
      content: '',
      attachmentsJson: AttachmentBridge.encode([attachment]),
    );
  }

  test(
    'attachment-only Aozora message uploads private bytes before sending canonical IDs',
    () async {
      final message = await enqueueAttachmentOnly();
      expect(await sync.syncOnce(), SyncState.idle);
      expect(uploadBodies.single, contains('附件内容'));
      expect(uploadBodies.single, contains('filename="notes.txt"'));
      expect(
        uploadBodies.single.toLowerCase(),
        contains('content-type: text/plain'),
      );
      expect(uploadKeys.single, '${message.id}:attachment:0');
      expect(messageBodies.single['content'], '');
      expect(messageBodies.single['attachments'], [
        {'id': 'att-server-1'},
      ]);
      expect(jsonEncode(messageBodies.single), isNot(contains(root.path)));
      final saved =
          (await repository.watchMessages(conversationId).first).single;
      expect(saved.syncStatus, 'synced');
      expect(
        AttachmentBridge.decode(saved.attachmentsJson).single.isUploaded,
        isTrue,
      );
    },
  );

  test(
    'failed upload retains bytes and retries with the same attachment identity',
    () async {
      final message = await enqueueAttachmentOnly();
      failUpload = true;
      expect(await sync.syncOnce(), SyncState.error);
      expect(messageBodies, isEmpty);
      final pending =
          (await repository.watchMessages(conversationId).first).single;
      final attachment = AttachmentBridge.decode(
        pending.attachmentsJson,
      ).single;
      expect(attachment.status, AttachmentStatus.failed);
      expect(attachment.attempts, 1);
      expect(await File(attachment.localPath).readAsString(), '附件内容');
      failUpload = false;
      expect(await sync.syncOnce(), SyncState.idle);
      expect(uploadKeys, [
        '${message.id}:attachment:0',
        '${message.id}:attachment:0',
      ]);
      expect(messageBodies, hasLength(1));
    },
  );

  test(
    'message retry reuses uploaded ID without uploading or duplicating the local message',
    () async {
      final message = await enqueueAttachmentOnly();
      failMessage = true;
      expect(await sync.syncOnce(), SyncState.error);
      failMessage = false;
      expect(await sync.syncOnce(), SyncState.idle);
      expect(uploadBodies, hasLength(1));
      expect(messageBodies, hasLength(2));
      expect(messageBodies.map((body) => body['id']), everyElement(message.id));
      expect(
        messageBodies.map((body) => body['attachments']),
        everyElement([
          {'id': 'att-server-1'},
        ]),
      );
      expect(messageKeys[0], messageKeys[1]);
      expect(
        await repository.watchMessages(conversationId).first,
        hasLength(1),
      );
    },
  );
}
