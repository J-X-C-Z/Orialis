import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/chat/data/agent_chat_service.dart';
import 'package:orialis_mobile/features/chat/data/chat_repository.dart';

class _Config extends AppConfig {
  _Config(this.url);
  final String url;
  @override
  Future<String> serverUrl() async => url;
  @override
  Future<String> deviceId() async => 'phone';
  @override
  Future<String?> sessionToken() async => 'test-session';
}

void main() {
  late HttpServer server;
  late AgentChatService service;
  final requests = <String>[];
  var bindingAvailable = true;
  final remote = {
    'id': 'conversation-mac',
    'title': 'Mac 电脑',
    'type': 'normal',
    'createdAt': '2026-10-03T00:00:00Z',
    'updatedAt': '2026-10-03T00:00:00Z',
    'version': 1,
  };
  setUp(() async {
    requests.clear();
    bindingAvailable = true;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    service = AgentChatService(_Config('http://127.0.0.1:${server.port}'));
    server.listen((request) async {
      expect(request.headers.value('Authorization'), 'Session test-session');
      requests.add('${request.method} ${request.uri.path}');
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/api/v1/agent/devices') {
        request.response.write(
          jsonEncode({
            'devices': [
              {
                'deviceId': 'JXCZ_MBA_Hermes',
                'platform': 'macos',
                'online': true,
              },
              {
                'deviceId': 'JXCZ_AOZORA_Hermes',
                'platform': 'linux',
                'online': false,
              },
            ],
          }),
        );
      } else if (request.method == 'POST') {
        request.response.write(jsonEncode(remote));
      } else if (request.method == 'PUT') {
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        expect(body['deviceId'], 'JXCZ_MBA_Hermes');
        request.response.statusCode = bindingAvailable ? 200 : 404;
        request.response.write('{}');
      } else if (request.method == 'GET') {
        request.response.write(
          jsonEncode({
            'conversationId': 'conversation-mac',
            'deviceId': 'JXCZ_MBA_Hermes',
          }),
        );
      } else {
        request.response.statusCode = 204;
      }
      await request.response.close();
    });
  });
  tearDown(() async => server.close(force: true));

  test('real registry lists Mac and offline Aozora separately', () async {
    final devices = await service.devices();
    expect(devices.map((d) => d.label), ['Mac 电脑', 'Aozora 服务器']);
    expect(devices.last.online, false);
    expect(await service.target('conversation-mac'), 'JXCZ_MBA_Hermes');
  });
  test('create binds exact device before exposing conversation', () async {
    final result = await service.createConversation(
      (await service.devices()).first,
    );
    expect(result['id'], 'conversation-mac');
    expect(requests.sublist(1), [
      'POST /api/v1/conversations',
      'PUT /api/v1/conversations/conversation-mac/agent-device',
    ]);
  });
  test('offline device cannot create an unbound chat', () async {
    final device = (await service.devices()).last;
    await expectLater(service.createConversation(device), throwsStateError);
    expect(requests.length, 1);
  });
  test('old server binding failure cleans up and fails closed', () async {
    final device = (await service.devices()).first;
    bindingAvailable = false;
    await expectLater(
      service.createConversation(device),
      throwsA(isA<Exception>()),
    );
    expect(requests.last, 'DELETE /api/v1/conversations/conversation-mac');
  });
  test(
    'import confirmed device conversation keeps local messages separate',
    () async {
      final db = AppDatabase(executor: NativeDatabase.memory());
      final repo = ChatRepository(database: db);
      final mac = await repo.importDeviceConversation(remote);
      final aozora = await repo.importDeviceConversation({
        ...remote,
        'id': 'conversation-aozora',
        'title': 'Aozora 服务器',
      });
      await repo.sendMessage(conversationId: mac.id, content: 'to Mac');
      await repo.sendMessage(conversationId: aozora.id, content: 'to Aozora');
      expect((await repo.watchMessages(mac.id).first).single.content, 'to Mac');
      expect(
        (await repo.watchMessages(aozora.id).first).single.content,
        'to Aozora',
      );
      expect(mac.syncStatus, 'synced');
      await db.close();
    },
  );
}
