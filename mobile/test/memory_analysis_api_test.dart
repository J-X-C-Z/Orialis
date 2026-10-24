import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';

class _Config extends AppConfig {
  @override
  Future<String?> sessionToken() async => 'test-session';
}

void main() {
  test('background API uses authenticated dedicated routes and handles only 404 as absent', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <String>[];
    var status = 200;
    server.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      expect(request.headers.value('Authorization'), 'Session test-session');
      final raw = await utf8.decoder.bind(request).join();
      if (request.method == 'POST') {
        expect(jsonDecode(raw), {
          'content': '屏幕内容',
          'imageBase64': '/9j/2Q==',
          'sourceUrls': ['https://b23.tv/Original'],
        });
      }
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'id': 'capture-1', 'status': 'analyzing'}),
      );
      await request.response.close();
    });
    final api = OrialisApiClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      deviceId: 'test-device',
      config: _Config(),
    );
    expect(
      (await api.createMemoryAnalysis(
        id: 'capture-1',
        content: '屏幕内容',
        imageBase64: '/9j/2Q==',
        sourceUrls: ['https://b23.tv/Original'],
      ))['status'],
      'analyzing',
    );
    expect((await api.memoryAnalysis('capture-1'))?['id'], 'capture-1');
    status = 404;
    expect(await api.memoryAnalysis('capture-1'), isNull);
    status = 401;
    await expectLater(
      api.memoryAnalysis('capture-1'),
      throwsA(isA<DioException>()),
    );
    expect(requests, [
      'POST /api/v1/memory/analyses/capture-1',
      'GET /api/v1/memory/analyses/capture-1',
      'GET /api/v1/memory/analyses/capture-1',
      'GET /api/v1/memory/analyses/capture-1',
    ]);
  });
}
