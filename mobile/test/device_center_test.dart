import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/features/devices/application/device_center_controller.dart';
import 'package:orialis_mobile/features/devices/data/device_data_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'capability discovery fails closed before calling Node routes',
    () async {
      final api = _ApiHarness(capabilities: ['chat.v1']);
      final source = api.source();

      await expectLater(
        source.listDevices(),
        throwsA(
          isA<DeviceCenterException>().having(
            (error) => error.message,
            'message',
            contains('尚未发布'),
          ),
        ),
      );
      expect(api.calls.map((call) => call.path), ['/api/v1/capabilities']);
      expect(api.calls.single.headers['Authorization'], 'Session test-session');
    },
  );

  test(
    'lists account Nodes and separately reads selected detail/capabilities',
    () async {
      final api = _ApiHarness(capabilities: ['multidevice.v1']);
      final source = api.source();

      final devices = await source.listDevices();
      expect(devices, hasLength(1));
      expect(devices.single.deviceId, 'node-phone');
      final listCall = api.calls.firstWhere(
        (call) => call.path == '/api/v1/nodes',
      );
      expect(listCall.headers['Authorization'], 'Session test-session');

      final details = await source.getDevice('node-phone');
      final capabilities = await source.getCapabilities('node-phone');
      expect(details.status.name, 'online');
      expect(capabilities.single.name, 'tasks.read');
      expect(capabilities.single.granted, isTrue);
      expect(api.calls.last.path, '/api/v1/nodes/node-phone/capabilities');
    },
  );

  test(
    'pairing decisions and revocation require confirmed contract responses',
    () async {
      final api = _ApiHarness(capabilities: ['multidevice.v1']);
      final source = api.source();

      await source.confirmPairing('pair-1', '123456');
      await source.rejectPairing('pair-2', '654321');
      await source.revoke('node-phone');
      final confirm = api.calls.firstWhere(
        (call) => call.path.endsWith('/pair-1/confirm'),
      );
      final reject = api.calls.firstWhere(
        (call) => call.path.endsWith('/pair-2/confirm'),
      );
      final revoke = api.calls.firstWhere((call) => call.method == 'DELETE');
      expect(confirm.method, 'POST');
      expect(confirm.data, {
        'confirmationCode': '123456',
        'decision': 'confirm',
      });
      expect(confirm.headers['Authorization'], 'Session test-session');
      expect(reject.data['decision'], 'reject');
      expect(revoke.method, 'DELETE');
      expect(revoke.path, '/api/v1/nodes/node-phone');
    },
  );

  test(
    'completed local pairing publishes the persisted Node binding',
    () async {
      final api = _ApiHarness(capabilities: ['multidevice.v1']);
      final credentials = _MemoryCredentialStore();
      final source = api.source(credentials: credentials);
      var bindingNotifications = 0;
      source.addLocalNodeBindingListener(() async {
        bindingNotifications++;
      });

      final challenge = await source.startPairing(
        const NodeIdentity(
          displayName: 'This phone',
          platform: 'android',
          nodeVersion: '0.1.0',
        ),
      );
      final deviceId = await source.completePairing(challenge);

      expect(deviceId, 'node-local');
      expect(bindingNotifications, 1);
      expect(await source.localNodeId(), 'node-local');
      expect(
        api.calls
            .where((call) => call.path.endsWith('/pairings'))
            .every((call) => call.headers['Authorization'] == null),
        isTrue,
      );
    },
  );

  test(
    'host lease starts after pairing, pauses in background, and stops on account switch',
    () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final api = _ApiHarness(capabilities: ['multidevice.v1']);
      final config = AppConfig();
      final source = api.source(config: config);
      final lifecycle = NodeHeartbeatLifecycle(source, config: config);

      final challenge = await source.startPairing(
        const NodeIdentity(
          displayName: 'This phone',
          platform: 'android',
          nodeVersion: '0.1.0',
        ),
      );
      await source.completePairing(challenge);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        api.calls.where((call) => call.path.endsWith('/heartbeat')),
        hasLength(1),
        reason: 'calls: ${api.calls.map((call) => call.path).toList()}',
      );
      expect(
        api.calls.singleWhere((call) => call.path.endsWith('/heartbeat')).data,
        <String, dynamic>{},
      );

      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        api.calls.where((call) => call.path.endsWith('/heartbeat')),
        hasLength(2),
      );

      api.sessionToken = 'session-b';
      api.accountId = 'account-b';
      await config.setSessionToken('session-b');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        api.calls.where((call) => call.path.endsWith('/heartbeat')),
        hasLength(2),
      );

      lifecycle.dispose();
      source.dispose();
    },
  );

  test('device scoped cache is isolated by account and Node ID', () {
    final cache = DeviceScopedCache<String>();
    cache.write('account-a', 'node-phone', 'A snapshot');
    cache.write('account-b', 'node-phone', 'B snapshot');
    cache.write('account-a', 'node-mac', 'Mac snapshot');
    expect(cache.read('account-a', 'node-phone'), 'A snapshot');
    expect(cache.read('account-b', 'node-phone'), 'B snapshot');
    expect(cache.read('account-a', 'node-mac'), 'Mac snapshot');
    cache.remove('account-a', 'node-phone');
    expect(cache.read('account-a', 'node-phone'), isNull);
    expect(cache.read('account-b', 'node-phone'), 'B snapshot');
  });

  test(
    'cancelled HTTP scope cannot send an old Session to a new server',
    () async {
      final api = _ApiHarness(capabilities: ['multidevice.v1'])
        ..pauseCapabilities();
      final source = api.source();
      final oldRequest = source.listDevices();
      final oldExpectation = expectLater(oldRequest, throwsA(anything));
      await api.capabilitiesStarted.future;

      api.serverUrl = 'https://server-b.test';
      api.sessionToken = 'session-b';
      api.accountId = 'account-b';
      expect(await source.listDevices(), hasLength(1));
      api.releaseCapabilities.complete();

      await oldExpectation;
      final callsToB = api.calls.where(
        (call) => call.origin == 'https://server-b.test',
      );
      expect(callsToB, isNotEmpty);
      expect(
        callsToB.every(
          (call) => call.headers['Authorization'] == 'Session session-b',
        ),
        isTrue,
      );
      expect(
        callsToB.any(
          (call) => call.headers['Authorization'] == 'Session test-session',
        ),
        isFalse,
      );
    },
  );

  test(
    'delayed secure credential read cannot send an old Node token after account switch',
    () async {
      final credentials = _DelayedCredentialStore();
      final api = _ApiHarness(capabilities: ['multidevice.v1']);
      final source = api.source(credentials: credentials);
      final heartbeat = source.heartbeat('node-phone', 'account-a');
      await credentials.readStarted.future;

      api.serverUrl = 'https://server-b.test';
      api.sessionToken = 'session-b';
      api.accountId = 'account-b';
      await source.listDevices();
      credentials.releaseRead.complete('node-credential-a');

      await expectLater(heartbeat, throwsA(anything));
      expect(
        api.calls.where((call) => call.path.endsWith('/heartbeat')),
        isEmpty,
      );
      final callsToB = api.calls.where(
        (call) => call.origin == 'https://server-b.test',
      );
      expect(
        callsToB.every(
          (call) => call.headers['Authorization'] != 'Node node-credential-a',
        ),
        isTrue,
      );
    },
  );
}

class _Call {
  const _Call(this.method, this.path, this.data, this.headers, this.origin);
  final String method;
  final String path;
  final dynamic data;
  final Map<String, dynamic> headers;
  final String origin;
}

class _ApiHarness {
  _ApiHarness({required this.capabilities});
  final List<String> capabilities;
  final calls = <_Call>[];
  String serverUrl = 'https://example.test';
  String sessionToken = 'test-session';
  String accountId = 'account-a';
  final capabilitiesStarted = Completer<void>();
  final releaseCapabilities = Completer<void>();
  bool _pauseCapabilities = false;

  void pauseCapabilities() => _pauseCapabilities = true;

  NodeApiDeviceDataSource source({
    NodeCredentialStore? credentials,
    AppConfig? config,
  }) {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
    final source = NodeApiDeviceDataSource(
      dio: dio,
      publicDio: dio,
      config: config,
      sessionToken: () async => sessionToken,
      serverUrl: () async => serverUrl,
      credentials: credentials ?? _MemoryCredentialStore(),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final path = options.uri.path;
          calls.add(
            _Call(
              options.method,
              path,
              options.data,
              Map.from(options.headers),
              options.uri.origin,
            ),
          );
          if (path == '/api/v1/capabilities' &&
              _pauseCapabilities &&
              !capabilitiesStarted.isCompleted) {
            capabilitiesStarted.complete();
            await releaseCapabilities.future;
            if (options.cancelToken?.isCancelled ?? false) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.cancel,
                ),
              );
              return;
            }
          }
          dynamic response;
          if (path == '/api/v1/capabilities') {
            response = {'capabilities': capabilities};
          } else if (path == '/api/v1/auth/session') {
            response = {'userId': accountId, 'username': accountId};
          } else if (path == '/api/v1/nodes') {
            response = {
              'protocolVersion': '1',
              'nodes': [
                {..._node, 'accountId': accountId},
              ],
              'nextCursor': null,
            };
          } else if (path == '/api/v1/nodes/node-phone/capabilities') {
            response = {
              'protocolVersion': '1',
              'deviceId': 'node-phone',
              'capabilities': [
                {
                  'name': 'tasks.read',
                  'version': '1.0.0',
                  'available': true,
                  'risk': 'low',
                  'constraints': {},
                  'grant': 'allow',
                },
              ],
            };
          } else if (path == '/api/v1/nodes/node-phone' &&
              options.method == 'DELETE') {
            response = {..._node, 'accountId': accountId, 'status': 'revoked'};
          } else if (path == '/api/v1/nodes/node-phone') {
            response = {..._node, 'accountId': accountId};
          } else if (path == '/api/v1/nodes/pairings/pair-1/confirm') {
            response = _pairing('pair-1', 'confirmed');
          } else if (path == '/api/v1/nodes/pairings/pair-2/confirm') {
            response = _pairing('pair-2', 'rejected');
          } else if (path == '/api/v1/nodes/pairings' &&
              options.method == 'POST') {
            response = {
              'protocolVersion': '1',
              'pairingId': 'pair-local',
              'pairingSecret': 'pair-secret',
              'confirmationCode': '123456',
              'targetNode': options.data['nodeIdentity'],
              'expiresAt': '2026-10-02T00:05:00Z',
            };
          } else if (path == '/api/v1/nodes/pairings/pair-local/complete') {
            response = {
              'protocolVersion': '1',
              'deviceId': 'node-local',
              'accountId': accountId,
              'deviceCredential': 'node-credential',
            };
          } else if (path == '/api/v1/nodes/node-local/heartbeat') {
            response = {'deviceId': 'node-local'};
          } else {
            handler.reject(
              DioException(
                requestOptions: options,
                error: 'unexpected route $path',
              ),
            );
            return;
          }
          handler.resolve(
            Response(requestOptions: options, data: response, statusCode: 200),
          );
        },
      ),
    );
    return source;
  }

  static final _node = <String, dynamic>{
    'protocolVersion': '1',
    'deviceId': 'node-phone',
    'accountId': 'account-a',
    'displayName': 'Phone',
    'platform': 'android',
    'nodeVersion': '0.1.0',
    'status': 'online',
    'createdAt': '2026-10-02T00:00:00Z',
    'lastSeenAt': '2026-10-02T00:00:10Z',
    'observedAt': '2026-10-02T00:00:10Z',
    'revocationVersion': 0,
    'capabilities': [
      {
        'name': 'tasks.read',
        'version': '1.0.0',
        'available': true,
        'risk': 'low',
        'constraints': {},
        'grant': 'allow',
      },
    ],
  };

  static Map<String, dynamic> _pairing(String pairingId, String status) => {
    'protocolVersion': '1',
    'pairingId': pairingId,
    'status': status,
    'accountId': 'account-a',
    'expiresAt': '2026-10-02T00:05:00Z',
  };
}

class _MemoryCredentialStore implements NodeCredentialStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

class _DelayedCredentialStore implements NodeCredentialStore {
  final readStarted = Completer<void>();
  final releaseRead = Completer<String?>();

  @override
  Future<String?> read({required String key}) {
    if (!readStarted.isCompleted) readStarted.complete();
    return releaseRead.future;
  }

  @override
  Future<void> write({required String key, required String value}) async {}

  @override
  Future<void> delete({required String key}) async {}
}
