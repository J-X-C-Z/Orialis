import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/core/sync/sync_engine.dart';

class CharacterizationConfig extends AppConfig {
  CharacterizationConfig({this.token});

  final String? token;
  int serverUrlReads = 0;
  int deviceIdReads = 0;

  @override
  Future<String?> sessionToken() async => token;

  @override
  Future<String> serverUrl() async {
    serverUrlReads++;
    return 'http://unused.invalid';
  }

  @override
  Future<String> deviceId() async {
    deviceIdReads++;
    return 'characterization-device';
  }
}

class CharacterizationApi extends OrialisApiClient {
  CharacterizationApi()
    : super(baseUrl: 'http://unused.invalid', deviceId: 'injected-device');

  int snapshotCalls = 0;
  int eventCalls = 0;

  @override
  Future<Map<String, dynamic>> syncSnapshot() async {
    snapshotCalls++;
    return {
      'cursor': 0,
      'projects': <Map<String, dynamic>>[],
      'milestones': <Map<String, dynamic>>[],
      'tasks': <Map<String, dynamic>>[],
      'calendarEvents': <Map<String, dynamic>>[],
    };
  }

  @override
  Future<Map<String, dynamic>> syncEvents({required int after}) async {
    eventCalls++;
    return {'events': [], 'nextCursor': after};
  }
}

void main() {
  test('an injected API is selected before config URL/device resolution', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final config = CharacterizationConfig(token: 'fake-session');
    final api = CharacterizationApi();
    final engine = SyncEngine(
      database: database,
      config: config,
      apiClient: api,
      includeChat: false,
    );

    expect(await engine.syncOnce(), SyncState.idle);

    expect(api.snapshotCalls, 1);
    expect(api.eventCalls, 1);
    expect(config.serverUrlReads, 0);
    expect(config.deviceIdReads, 0);
  });

  test('required session is checked before any API call', () async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final config = CharacterizationConfig();
    final api = CharacterizationApi();
    final engine = SyncEngine(
      database: database,
      config: config,
      apiClient: api,
      includeChat: false,
      requireSession: true,
    );

    expect(await engine.syncOnce(), SyncState.authRequired);

    expect(api.snapshotCalls, 0);
    expect(api.eventCalls, 0);
    expect(config.serverUrlReads, 0);
    expect(config.deviceIdReads, 0);
  });
}
