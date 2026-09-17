import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';

class _TestConfig extends AppConfig {
  @override
  Future<String?> sessionToken() async => 'test-session';
}

void main() {
  test('message page parses keyset response metadata', () {
    final page = MessagePage.fromJson({
      'items': [
        {'id': 'm1', 'content': '第一页'},
      ],
      'nextCursor': 'cursor-2',
      'hasMore': true,
    });

    expect(page.items.single['id'], 'm1');
    expect(page.nextCursor, 'cursor-2');
    expect(page.hasMore, isTrue);
  });

  test('message page keeps legacy array response compatible', () {
    final page = MessagePage.fromJson([
      {'id': 'm1', 'content': '旧响应'},
    ]);

    expect(page.items.single['content'], '旧响应');
    expect(page.nextCursor, isNull);
    expect(page.hasMore, isFalse);
  });

  test(
    'listMessages follows opaque cursors until the page is complete',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final cursors = <String?>[];
      server.listen((request) async {
        cursors.add(request.uri.queryParameters['after']);
        final after = request.uri.queryParameters['after'];
        final body = after == null
            ? {
                'items': [
                  {'id': 'm1'},
                ],
                'nextCursor': 'opaque/+2',
                'hasMore': true,
              }
            : {
                'items': [
                  {'id': 'm2'},
                ],
                'nextCursor': null,
                'hasMore': false,
              };
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(body));
        await request.response.close();
      });
      final api = OrialisApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        deviceId: 'device-1',
        config: _TestConfig(),
      );

      final messages = await api.listMessages('conversation-1');

      expect(messages.map((item) => item['id']), ['m1', 'm2']);
      expect(cursors, [null, 'opaque/+2']);
    },
  );
}
