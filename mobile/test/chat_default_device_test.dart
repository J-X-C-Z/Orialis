import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/features/chat/data/agent_chat_service.dart';

class _Config extends AppConfig {
  _Config(this.url);
  String url;
  String token = 'token-a';
  String username = 'alice';

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
  late _Config config;
  var azureOnline = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    azureOnline = true;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    config = _Config('http://127.0.0.1:${server.port}');
    service = AgentChatService(config);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'devices': [
            {
              'deviceId': 'JXCZ_MBA_Hermes',
              'platform': 'macos',
              'online': true,
            },
            {
              'deviceId': 'JXCZ_PC_Hermes',
              'platform': 'windows',
              'online': true,
            },
            {
              'deviceId': 'JXCZ_HAKARI_Hermes',
              'platform': 'linux',
              'online': true,
            },
            {
              'deviceId': 'JXCZ_AOZORA_Hermes',
              'platform': 'linux',
              'online': azureOnline,
            },
          ],
        }),
      );
      await request.response.close();
    });
  });

  tearDown(() async {
    service.dispose();
    await server.close(force: true);
  });

  test('Azure is default and default device is freshly resolved', () async {
    expect(await service.defaultDeviceId(), 'JXCZ_AOZORA_Hermes');
    expect((await service.defaultDevice()).id, 'JXCZ_AOZORA_Hermes');
  });

  test(
    'selection persists per server and account across service instances',
    () async {
      await service.setDefaultDevice('JXCZ_MBA_Hermes');
      final restarted = AgentChatService(config);
      expect(await restarted.defaultDeviceId(), 'JXCZ_MBA_Hermes');

      config.username = 'bob';
      expect(await restarted.defaultDeviceId(), 'JXCZ_AOZORA_Hermes');
      await restarted.setDefaultDevice('JXCZ_PC_Hermes');
      config.username = 'alice';
      config.token = 'renewed-token';
      expect(await restarted.defaultDeviceId(), 'JXCZ_MBA_Hermes');
      config.username = 'bob';
      expect(await restarted.defaultDeviceId(), 'JXCZ_PC_Hermes');
      config.url = 'http://another-server';
      expect(await restarted.defaultDeviceId(), 'JXCZ_AOZORA_Hermes');
      restarted.dispose();
    },
  );

  test(
    'offline selected target stays selected and throws without fallback',
    () async {
      await service.setDefaultDevice('JXCZ_AOZORA_Hermes');
      azureOnline = false;
      expect(await service.defaultDeviceId(), 'JXCZ_AOZORA_Hermes');
      await expectLater(service.defaultDevice(), throwsStateError);
    },
  );

  test('only configured targets can be selected', () async {
    await expectLater(
      service.setDefaultDevice('JXCZ_AOZORA_Codex'),
      throwsStateError,
    );
  });
}
