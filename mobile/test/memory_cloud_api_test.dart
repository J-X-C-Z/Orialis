import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';

class Config extends AppConfig {
  @override
  Future<String?> sessionToken() async => 'account-test-session';
}

void main() {
  test('memory API sends authenticated compressed-copy bytes without re-encoding and versioned metadata', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final captured = <(String, String, List<int>)>[];
    final bytes = Uint8List.fromList([
      137,
      80,
      78,
      71,
      ...List.generate(10000, (i) => i % 256),
    ]);
    final hash = sha256.convert(bytes).toString();
    final listener = server.listen((request) async {
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Session account-test-session',
      );
      final body = await request.fold<List<int>>(
        [],
        (all, part) => all..addAll(part),
      );
      captured.add((request.method, request.uri.path, body));
      if (request.method == 'GET' && request.uri.path.contains('/images/')) {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(bytes);
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(
            request.uri.path.endsWith('/records')
                ? {'items': [], 'hasMore': false}
                : {'id': 'one', 'version': 3},
          ),
        );
      }
      await request.response.close();
    });
    final client = OrialisApiClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      deviceId: 'device-b',
      config: Config(),
    );
    try {
      await client.uploadMemoryImage(hash, bytes, 'image/png');
      await client.putMemoryRecord('one', {
        'notes': '账号下的笔记',
        'imageSha256': hash,
      }, 2);
      await client.memoryRecords(offset: 100, query: '笔记');
      expect(await client.downloadMemoryImage(hash), bytes);
      expect(captured[0].$1, 'PUT');
      expect(captured[0].$2, '/api/v1/memory/images/$hash');
      expect(captured[0].$3, bytes);
      expect(jsonDecode(utf8.decode(captured[1].$3)), {
        'record': {'notes': '账号下的笔记', 'imageSha256': hash},
        'expectedVersion': 2,
      });
    } finally {
      client.close();
      await listener.cancel();
      await server.close(force: true);
    }
  });
}
