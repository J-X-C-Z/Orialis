import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/wear/wear_snapshot_producer.dart';

class _Config extends AppConfig {
  _Config(this.url);
  String url;
  String? token = 'secret-A';
  final listeners = <Future<void> Function()>{};
  @override
  Future<String> serverUrl() async => url;
  @override
  Future<String?> sessionToken() async => token;
  @override
  Future<String?> sessionUsername() async => 'untrusted-local-name';
  @override
  Future<String> deviceId() async => 'phone-test';
  @override
  void addIdentityListener(Future<void> Function() listener) =>
      listeners.add(listener);
  @override
  void removeIdentityListener(Future<void> Function() listener) =>
      listeners.remove(listener);
  Future<void> revoke() async {
    for (final listener in listeners.toList()) {
      await listener();
    }
  }
}

void main() {
  for (final scenario in [
    'success',
    'unauthorized',
    'malformed',
    'switchToken',
    'switchServer',
    'revokeAndRestore',
  ]) {
    test('account snapshot $scenario never leaks shared local data', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final config = _Config('http://127.0.0.1:${server.port}');
      final headers = <String?>[];
      server.listen((request) async {
        headers.add(request.headers.value(HttpHeaders.authorizationHeader));
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/api/v1/auth/session') {
          if (scenario == 'unauthorized') {
            request.response.statusCode = 401;
            request.response.write('{}');
          } else {
            request.response.write(
              jsonEncode({'userId': 'user-A', 'username': 'server-name'}),
            );
          }
        } else {
          if (scenario == 'switchToken') config.token = 'secret-B';
          if (scenario == 'switchServer') config.url = 'http://127.0.0.1:1';
          if (scenario == 'revokeAndRestore') await config.revoke();
          request.response.write(
            jsonEncode({
              'cursor': 1,
              'tasks': [
                {
                  'id': 'remote-task',
                  'title': 'Current account',
                  'userId': 'must-not-send',
                  'accessToken': 'must-not-send',
                },
              ],
              'calendarEvents': [],
              'projects': [],
              if (scenario != 'malformed') 'milestones': [],
            }),
          );
        }
        await request.response.close();
      });
      final db = AppDatabase(executor: AppDatabase.inMemoryExecutor());
      addTearDown(db.close);
      await db
          .into(db.tasks)
          .insert(
            TasksCompanion.insert(
              id: 'local-task',
              title: 'Shared old account',
              createdAt: '2026-10-02',
              updatedAt: '2026-10-02',
            ),
          );
      final preview = await WearSnapshotProducer(db, config).read();
      final encoded = jsonEncode(preview.snapshot);
      expect(preview.accountScopeVerified, scenario == 'success');
      expect(encoded, isNot(contains('secret-')));
      expect(encoded, isNot(contains('must-not-send')));
      expect(config.listeners, isEmpty);
      if (scenario == 'success') {
        expect(encoded, contains('remote-task'));
        expect(encoded, contains('server-name'));
        expect(encoded, isNot(contains('local-task')));
        expect(encoded, isNot(contains('untrusted-local-name')));
        expect(headers, ['Session secret-A', 'Session secret-A']);
        expect(preview.total['tasks'], 1);
      } else {
        expect(encoded, contains('local-task'));
        expect(encoded, isNot(contains('remote-task')));
      }
    });
  }
}
