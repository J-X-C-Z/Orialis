import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/chat/data/agent_chat_service.dart';
import 'package:orialis_mobile/features/chat/data/chat_repository.dart';

class _Config extends AppConfig {
  _Config(this.url);
  final String url;
  String token = 'test-session';
  String? username;
  @override
  Future<String?> sessionUsername() async => username;
  @override
  Future<String> serverUrl() async => url;
  @override
  Future<String> deviceId() async => 'phone';
  @override
  Future<String?> sessionToken() async => token;
}

void main() {
  late HttpServer server;
  late AgentChatService service;
  final requests = <String>[];
  var bindingAvailable = true;
  Completer<void>? bindingGate;
  String? bindingTarget;
  String? gatedConversation;
  String? rejectedConversation;
  var changeIdentity = false;
  var unavailable = false;
  String? createdTitle;
  int unavailableStatus = 503;
  bool changeRegistryIdentity = false;
  late _Config config;
  final remote = {
    'id': 'conversation-mac',
    'title': 'Mac 电脑',
    'type': 'normal',
    'createdAt': '2026-10-03T00:00:00Z',
    'updatedAt': '2026-10-03T00:00:00Z',
    'version': 1,
  };
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    requests.clear();
    bindingAvailable = true;
    bindingGate = null;
    gatedConversation = null;
    rejectedConversation = null;
    bindingTarget = 'JXCZ_MBA_Hermes';
    changeIdentity = false;
    unavailable = false;
    createdTitle = null;
    unavailableStatus = 503;
    changeRegistryIdentity = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    config = _Config('http://127.0.0.1:${server.port}');
    service = AgentChatService(config);
    server.listen((request) async {
      if (!unavailable) {
        expect(request.headers.value('Authorization'), 'Session test-session');
      }
      requests.add('${request.method} ${request.uri.path}');
      if (request.method == 'GET' &&
          request.uri.path.endsWith('/agent-device') &&
          (gatedConversation == null ||
              request.uri.path.contains('/$gatedConversation/'))) {
        await bindingGate?.future;
      }
      request.response.headers.contentType = ContentType.json;
      if (unavailable ||
          (rejectedConversation != null &&
              request.uri.path.contains('/$rejectedConversation/'))) {
        request.response.statusCode = unavailableStatus;
        request.response.write('{}');
      } else if (request.uri.path == '/api/v1/agent/devices') {
        if (changeRegistryIdentity) config.token = 'another-account';
        request.response.write(
          jsonEncode({
            'devices': [
              {
                'deviceId': 'JXCZ_AOZORA_Codex',
                'platform': 'linux',
                'online': true,
              },
              {
                'deviceId': 'TEST_MAC_Hermes',
                'platform': 'macos',
                'online': true,
              },
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
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        createdTitle = body['title'] as String?;
        request.response.write(jsonEncode({...remote, 'title': createdTitle}));
      } else if (request.method == 'PUT') {
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        expect(body['deviceId'], 'JXCZ_MBA_Hermes');
        request.response.statusCode = bindingAvailable ? 200 : 404;
        request.response.write('{}');
        if (changeIdentity) config.token = 'another-account';
      } else if (request.method == 'GET') {
        request.response.write(
          jsonEncode({
            'conversationId': 'conversation-mac',
            'deviceId': bindingTarget,
          }),
        );
      } else {
        request.response.statusCode = 204;
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    if (bindingGate?.isCompleted == false) bindingGate!.complete();
    service.dispose();
    await server.close(force: true);
  });

  test('registry exposes only Mac and Azure Hermes', () async {
    final devices = await service.devices();
    expect(devices.map((d) => d.label), ['Mac 电脑', 'Azure 服务器']);
    expect(devices.last.online, false);
    expect(devices.map((d) => d.id), ['JXCZ_MBA_Hermes', 'JXCZ_AOZORA_Hermes']);
    expect(await service.target('conversation-mac'), 'JXCZ_MBA_Hermes');
  });
  test(
    'configured missing Azure remains offline without choosing Codex',
    () async {
      final configured = AgentChatService(
        config,
        azureDeviceId: 'JXCZ_NEWAZURE_Hermes',
      );
      final devices = await configured.devices();
      expect(devices.length, 2);
      expect(devices.last.id, 'JXCZ_NEWAZURE_Hermes');
      expect(devices.last.label, 'Azure 服务器');
      expect(devices.last.online, false);
    },
  );
  test('direct Codex or test device cannot bypass the picker', () async {
    for (final id in ['JXCZ_AOZORA_Codex', 'TEST_MAC_Hermes']) {
      await expectLater(
        service.createConversation(
          ChatAgentDevice(id: id, platform: 'linux', online: true),
        ),
        throwsStateError,
      );
    }
    expect(requests, isEmpty);
  });
  test('verified binding history survives offline service restart', () async {
    expect(await service.target('conversation-mac'), 'JXCZ_MBA_Hermes');
    unavailable = true;
    final restarted = AgentChatService(config);
    expect(await restarted.target('conversation-mac'), 'JXCZ_MBA_Hermes');
    await expectLater(
      restarted.target('conversation-mac', requireOnline: true),
      throwsException,
    );
    expect((await restarted.devices()).map((device) => device.online), [
      false,
      false,
    ]);
    config.token = 'another-account';
    expect(await restarted.target('conversation-mac'), isNull);
  });
  test(
    'cached history opens before slow refresh and requests are shared',
    () async {
      expect(await service.target('conversation-mac'), 'JXCZ_MBA_Hermes');
      requests.clear();
      bindingGate = Completer<void>();
      bindingTarget = 'JXCZ_AOZORA_Hermes';
      final restarted = AgentChatService(config);
      final changed = restarted.targetChanges.first;
      expect(
        await restarted.cachedTarget('conversation-mac'),
        'JXCZ_MBA_Hermes',
      );
      expect(requests, isEmpty);
      final cached = await Future.wait(
        List.generate(5, (_) => restarted.target('conversation-mac')),
      ).timeout(const Duration(seconds: 1));
      expect(cached, everyElement('JXCZ_MBA_Hermes'));
      var onlineFinished = false;
      final online = restarted
          .target('conversation-mac', requireOnline: true)
          .then((value) {
            onlineFinished = true;
            return value;
          });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(onlineFinished, false);
      expect(requests, [
        'GET /api/v1/conversations/conversation-mac/agent-device',
      ]);
      bindingGate!.complete();
      expect(await online, 'JXCZ_AOZORA_Hermes');
      expect(await changed, ('conversation-mac', 'JXCZ_AOZORA_Hermes'));
      expect(
        await restarted.cachedTarget('conversation-mac'),
        'JXCZ_AOZORA_Hermes',
      );
      restarted.dispose();
    },
  );

  test(
    'background rejection removes the binding and notifies history',
    () async {
      expect(await service.target('conversation-mac'), 'JXCZ_MBA_Hermes');
      unavailable = true;
      unavailableStatus = 403;
      final changed = service.targetChanges.first;
      expect(await service.target('conversation-mac'), 'JXCZ_MBA_Hermes');
      expect(await changed, ('conversation-mac', null));
      expect(await service.cachedTarget('conversation-mac'), isNull);
    },
  );

  test(
    'auth rejection prevents another cached binding surviving restart',
    () async {
      await service.target('conversation-mac');
      await service.target('conversation-other');
      unavailable = true;
      unavailableStatus = 401;
      final changed = service.targetChanges.first;
      await expectLater(
        service.target('conversation-mac', requireOnline: true),
        throwsException,
      );
      expect(await changed, ('', null));
      final restarted = AgentChatService(config);
      expect(await restarted.cachedTarget('conversation-other'), isNull);
      restarted.dispose();
    },
  );

  test(
    'late success cannot restore bindings after concurrent auth rejection',
    () async {
      await service.target('conversation-mac');
      await service.target('conversation-other');
      bindingGate = Completer<void>();
      gatedConversation = 'conversation-other';
      rejectedConversation = 'conversation-mac';
      unavailableStatus = 401;
      final pending = service.target('conversation-other', requireOnline: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await expectLater(
        service.target('conversation-mac', requireOnline: true),
        throwsException,
      );
      bindingGate!.complete();
      expect(await pending, isNull);
      final restarted = AgentChatService(config);
      expect(await restarted.cachedTarget('conversation-other'), isNull);
      restarted.dispose();
    },
  );

  test(
    'identity switch during refresh cannot overwrite the old binding',
    () async {
      await service.target('conversation-mac');
      bindingGate = Completer<void>();
      bindingTarget = 'JXCZ_AOZORA_Hermes';
      final refresh = service.target('conversation-mac', requireOnline: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      config.token = 'another-account';
      expect(await service.cachedTarget('conversation-mac'), isNull);
      bindingGate!.complete();
      expect(await refresh, isNull);
      config.token = 'test-session';
      expect(await service.cachedTarget('conversation-mac'), 'JXCZ_MBA_Hermes');
    },
  );

  test(
    'device aliases persist per server session without changing routing',
    () async {
      await service.renameDevice('JXCZ_MBA_Hermes', '  工作 Mac  ');
      final restarted = AgentChatService(config);
      final device = (await restarted.devices()).first;
      expect(device.label, '工作 Mac');
      expect(device.id, 'JXCZ_MBA_Hermes');
      await restarted.createConversation(device);
      expect(createdTitle, '工作 Mac');
      config.token = 'another-account';
      unavailable = true;
      expect((await restarted.devices()).first.label, 'Mac 电脑');
      config.token = 'test-session';
      expect((await restarted.devices()).first.label, '工作 Mac');
    },
  );
  test('empty names never overwrite the saved device alias', () async {
    await service.renameDevice('JXCZ_MBA_Hermes', '工作 Mac');
    await expectLater(
      service.renameDevice('JXCZ_MBA_Hermes', '   '),
      throwsArgumentError,
    );
    expect((await service.devices()).first.label, '工作 Mac');
  });
  test(
    'rejected binding clears cached history before a later outage',
    () async {
      expect(await service.target('conversation-mac'), 'JXCZ_MBA_Hermes');
      unavailable = true;
      unavailableStatus = 403;
      await expectLater(
        service.target('conversation-mac', requireOnline: true),
        throwsException,
      );
      unavailableStatus = 503;
      expect(await AgentChatService(config).target('conversation-mac'), isNull);
    },
  );
  test(
    'account switch during registry lookup clears names and online state',
    () async {
      await service.renameDevice('JXCZ_MBA_Hermes', '工作 Mac');
      changeRegistryIdentity = true;
      final devices = await service.devices();
      expect(devices.map((device) => device.online), [false, false]);
      expect(devices.first.label, 'Mac 电脑');
    },
  );
  test(
    'device aliases survive same-account token renewal and isolate another username',
    () async {
      config.username = 'jxcz';
      await service.renameDevice('JXCZ_MBA_Hermes', '工作 Mac');
      config.token = 'renewed-session';
      unavailable = true;
      final restarted = AgentChatService(config);
      expect((await restarted.devices()).first.label, '工作 Mac');
      config.username = 'other-user';
      expect((await restarted.devices()).first.label, 'Mac 电脑');
    },
  );
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
    'account change during binding fails closed with original session cleanup',
    () async {
      final device = (await service.devices()).first;
      changeIdentity = true;
      await expectLater(service.createConversation(device), throwsStateError);
      expect(requests.last, 'DELETE /api/v1/conversations/conversation-mac');
    },
  );

  test(
    'import confirmed device conversation keeps local messages separate',
    () async {
      final db = AppDatabase(executor: NativeDatabase.memory());
      final repo = ChatRepository(database: db);
      final mac = await repo.importDeviceConversation(remote);
      final aozora = await repo.importDeviceConversation({
        ...remote,
        'id': 'conversation-aozora',
        'title': 'Azure 服务器',
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
