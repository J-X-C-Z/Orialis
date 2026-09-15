import 'package:flutter_test/flutter_test.dart';
import 'package:fangcun_devtools/server_client.dart';

class FakeTransport implements ServerTransport {
  final requests = <({String method, Uri uri, Map<String, String> headers, String? body})>[];
  final responses = <ServerHttpResponse>[];

  @override
  Future<ServerHttpResponse> request(String method, Uri uri, {required Map<String, String> headers, String? body}) async {
    requests.add((method: method, uri: uri, headers: Map.of(headers), body: body));
    return responses.removeAt(0);
  }
}

void main() {
  test('uses v1, logs in as Flutter, and authenticates subsequent calls', () async {
    final fake = FakeTransport()
      ..responses.add(const ServerHttpResponse(200, '{"ok":true}'))
      ..responses.add(const ServerHttpResponse(200, '{"accessToken":"secret","tokenType":"Session","expiresIn":2592000,"user":{"id":1}}'))
      ..responses.add(const ServerHttpResponse(200, '{"authenticated":true}'));
    final client = FangcunServerClient(baseUrl: Uri.parse('https://example.test/'), transport: fake);

    await client.health();
    final info = await client.login('alice', 'password');
    await client.session();

    expect(info.accessToken, 'secret');
    expect(fake.requests[0].uri.path, '/api/v1/health');
    expect(fake.requests[1].uri.path, '/api/v1/auth/login');
    expect(fake.requests[1].headers.containsKey('Authorization'), isFalse);
    expect(fake.requests[2].headers['Authorization'], 'Session secret');
  });

<<<<<<< HEAD
  test('falls back to the deployed Web API when v1 login is not routed', () async {
    final fake = FakeTransport()
      ..responses.add(const ServerHttpResponse(401, '{"error":"请先登录"}'))
      ..responses.add(const ServerHttpResponse(200, '{"accessToken":"legacy","tokenType":"Session","expiresIn":10,"user":{}}'))
      ..responses.add(const ServerHttpResponse(200, '{"data":{"tasks":[]},"revision":2}'));
    final client = FangcunServerClient(baseUrl: Uri.parse('https://example.test'), transport: fake);

    await client.login('alice', 'password');
    await client.getData();

    expect(fake.requests[0].uri.path, '/api/v1/auth/login');
    expect(fake.requests[1].uri.path, '/api/auth/login');
    expect(fake.requests[2].uri.path, '/api/data');
  });

=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
  test('reads and writes revisioned data', () async {
    final fake = FakeTransport()
      ..responses.add(const ServerHttpResponse(200, '{"accessToken":"t","tokenType":"Session","expiresIn":10,"user":{}}'))
      ..responses.add(const ServerHttpResponse(200, '{"data":{"tasks":[]},"revision":3,"updatedAt":"now"}'))
      ..responses.add(const ServerHttpResponse(200, '{"ok":true,"revision":4,"updatedAt":"later"}'));
    final client = FangcunServerClient(baseUrl: Uri.parse('https://example.test'), transport: fake);
    await client.login('a', 'password');
    final snapshot = await client.getData();
    final saved = await client.putData({'tasks': []}, snapshot.revision);

    expect(snapshot.revision, 3);
    expect(saved.revision, 4);
    expect(fake.requests.last.headers['Authorization'], 'Session t');
  });

  test('turns 409 into a revision conflict exception and clears token on logout', () async {
    final fake = FakeTransport()
      ..responses.add(const ServerHttpResponse(200, '{"accessToken":"t","tokenType":"Session","expiresIn":10,"user":{}}'))
      ..responses.add(const ServerHttpResponse(409, '{"error":"云端数据已被另一台设备更新","revision":8,"updatedAt":"later"}'))
      ..responses.add(const ServerHttpResponse(200, '{"ok":true}'));
    final client = FangcunServerClient(baseUrl: Uri.parse('https://example.test'), transport: fake);
    await client.login('a', 'password');

    await expectLater(client.putData({}, 7), throwsA(isA<RevisionConflictException>().having((e) => e.remoteRevision, 'remote revision', 8)));
    await client.logout();
    expect(client.isAuthenticated, isFalse);
    expect(fake.requests.last.headers.containsKey('Authorization'), isTrue);
  });
<<<<<<< HEAD

  test('reads the native-independent link health and snapshot endpoints', () async {
    final fake = FakeTransport()
      ..responses.add(const ServerHttpResponse(200, '{"ok":true,"schema":"fangcun.link.v1","version":1,"authenticated":false,"transport":"not-connected","mode":"pull-only"}'))
      ..responses.add(const ServerHttpResponse(200, '{"schema":"fangcun.link.v1","version":1,"dataState":"live","sync":{"revision":7},"payload":{"tasks":{}}}'));
    final client = FangcunServerClient(baseUrl: Uri.parse('https://example.test'), transport: fake);

    final health = await client.linkHealth();
    final snapshot = await client.getLinkSnapshot();

    expect(health.schema, 'fangcun.link.v1');
    expect(health.authenticated, isFalse);
    expect(snapshot.dataState, 'live');
    expect(snapshot.revision, 7);
    expect(fake.requests[1].uri.path, '/api/v1/link/snapshot');
  });
=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
}
