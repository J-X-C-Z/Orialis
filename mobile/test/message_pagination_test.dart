import 'package:flutter_test/flutter_test.dart';

import 'package:orialis_mobile/core/network/orialis_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
}
