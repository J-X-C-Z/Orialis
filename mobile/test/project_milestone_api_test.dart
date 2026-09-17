import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';

class ApiTestConfig extends AppConfig {
  @override
  Future<String?> sessionToken() async => 'test-session';
}

void main() {
  late HttpServer server;
  late OrialisApiClient api;
  late List<
    ({
      String method,
      Uri uri,
      String? key,
      String? auth,
      String? device,
      Map<String, dynamic>? body,
    })
  >
  requests;
  late int status;
  setUp(() async {
    status = 200;
    requests = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      requests.add((
        method: request.method,
        uri: request.uri,
        key: request.headers.value('Idempotency-Key'),
        auth: request.headers.value('Authorization'),
        device: request.headers.value('X-Orialis-Device-Id'),
        body: body.isEmpty ? null : jsonDecode(body) as Map<String, dynamic>,
      ));
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'items': [],
          'nextCursor': 'opaque-next',
          'hasMore': true,
          'id': 'server-assigned-id',
          'version': 2,
          'cursor': 10,
          'tasks': [],
          'projects': [],
          'calendarEvents': [],
          'milestones': [],
        }),
      );
      await request.response.close();
    });
    api = OrialisApiClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      deviceId: 'device-1',
      config: ApiTestConfig(),
    );
  });
  tearDown(() => server.close(force: true));

  test(
    'snapshot and events use real routes and carry session/device headers',
    () async {
      final snapshot = await api.syncSnapshot();
      expect(snapshot['cursor'], 10);
      expect(snapshot['milestones'], isEmpty);
      await api.syncEvents(after: 10);
      expect(requests.map((r) => r.uri.path), [
        '/api/v1/sync/snapshot',
        '/api/v1/sync/events',
      ]);
      expect(requests.last.uri.queryParameters, {'after': '10'});
      expect(requests.map((r) => r.auth), everyElement('Session test-session'));
      expect(requests.map((r) => r.device), everyElement('device-1'));
    },
  );

  test(
    'project CRUD preserves pagination, null patches and mutation identity',
    () async {
      final result = await api.listProjects(
        after: 'opaque+cursor',
        limit: 2,
        status: 'active',
      );
      expect(result['nextCursor'], 'opaque-next');
      expect(result['hasMore'], isTrue);
      expect(requests.last.uri.queryParameters, {
        'after': 'opaque+cursor',
        'limit': '2',
        'status': 'active',
      });
      final created = await api.createProject({
        'name': 'Project',
      }, 'create-key');
      expect(created['id'], 'server-assigned-id');
      expect(requests.last.body, {'name': 'Project'});
      const id = 'project /一';
      await api.updateProject(id, {
        'goal': null,
        'baseVersion': 4,
      }, 'update-key');
      expect(requests.last.uri.pathSegments, ['api', 'v1', 'projects', id]);
      expect(requests.last.body, {'goal': null, 'baseVersion': 4});
      await api.deleteProject(id, 'delete-key');
      expect(requests.last.uri.pathSegments, ['api', 'v1', 'projects', id]);
      expect(requests.last.body, isNull);
      expect(requests.map((r) => r.method), ['GET', 'POST', 'PATCH', 'DELETE']);
      expect(requests.map((r) => r.key), [
        null,
        'create-key',
        'update-key',
        'delete-key',
      ]);
    },
  );

  test(
    'milestone CRUD uses encoded nested routes and server writable fields',
    () async {
      const parent = 'project /一';
      const id = 'milestone /二';
      final result = await api.listProjectMilestones(
        parent,
        after: 'cursor/+',
        limit: 3,
      );
      expect(result['nextCursor'], 'opaque-next');
      expect(requests.last.uri.queryParameters, {
        'after': 'cursor/+',
        'limit': '3',
      });
      final created = await api.createProjectMilestone(parent, {
        'title': 'Milestone',
        'due': '2026-09-30',
        'position': 2,
      }, 'create-key');
      expect(created['id'], 'server-assigned-id');
      expect(requests.last.uri.pathSegments, [
        'api',
        'v1',
        'projects',
        parent,
        'milestones',
      ]);
      expect(requests.last.body, {
        'title': 'Milestone',
        'due': '2026-09-30',
        'position': 2,
      });
      await api.updateProjectMilestone(parent, id, {
        'due': null,
        'completed': true,
        'baseVersion': 7,
      }, 'update-key');
      expect(requests.last.body, {
        'due': null,
        'completed': true,
        'baseVersion': 7,
      });
      expect(requests.last.uri.pathSegments, [
        'api',
        'v1',
        'projects',
        parent,
        'milestones',
        id,
      ]);
      await api.deleteProjectMilestone(parent, id, 'delete-key');
      expect(requests.last.uri.pathSegments, [
        'api',
        'v1',
        'projects',
        parent,
        'milestones',
        id,
      ]);
      expect(requests.last.body, isNull);
      expect(requests.map((r) => r.method), ['GET', 'POST', 'PATCH', 'DELETE']);
      expect(requests.map((r) => r.key), [
        null,
        'create-key',
        'update-key',
        'delete-key',
      ]);
    },
  );

  test(
    '409 is propagated and an explicit retry reuses its supplied key',
    () async {
      status = 409;
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          api.updateProjectMilestone('p1', 'm1', {
            'title': 'Local edit',
            'baseVersion': 3,
          }, 'stable-key'),
          throwsA(
            isA<DioException>().having(
              (e) => e.response?.statusCode,
              'status',
              409,
            ),
          ),
        );
      }
      expect(requests.map((r) => r.key), ['stable-key', 'stable-key']);
      expect(requests.map((r) => r.body?['baseVersion']), [3, 3]);
      expect(requests, hasLength(2));
    },
  );
}
