import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/realtime/mobile_realtime_client.dart';

class _LocalConfig extends AppConfig {
  _LocalConfig(this.port);
  final int port;
  @override
  Future<String> serverUrl() async => 'http://127.0.0.1:$port';
  @override
  Future<String> deviceId() async => 'desktop-test';
  @override
  Future<String?> sessionToken() async => null;
}

enum _ConfigRead { server, token, device }

class _GatedConfig extends _LocalConfig {
  _GatedConfig(super.port, this.read);
  final _ConfigRead read;
  final reached = Completer<void>();
  final release = Completer<void>();
  bool _held = false;

  Future<void> _wait(_ConfigRead current) async {
    if (current != read || _held) return;
    _held = true;
    reached.complete();
    await release.future;
  }

  @override
  Future<String> serverUrl() async {
    await _wait(_ConfigRead.server);
    return super.serverUrl();
  }

  @override
  Future<String?> sessionToken() async {
    await _wait(_ConfigRead.token);
    return super.sessionToken();
  }

  @override
  Future<String> deviceId() async {
    await _wait(_ConfigRead.device);
    return super.deviceId();
  }
}

void main() {
  for (final read in _ConfigRead.values) {
    test('dispose cancels a pending ${read.name} read permanently', () async {
      final config = _GatedConfig(1, read);
      final client = MobileRealtimeClient(config: config);
      addTearDown(client.dispose);
      final pending = client.connect();
      await config.reached.future;
      await client.dispose();
      config.release.complete();
      await pending;
      await client.connect();
      expect(client.isConnected, isFalse);
      expect(client.reconnectScheduled, isFalse);
      // Late frames and optional sends must not touch a closed event stream.
      client.ingestForTest('{"type":"hello.ack","payload":{}}');
      await client.sendEvent(kind: 'after-dispose');
      expect(client.capabilitiesNegotiated, isFalse);
    });

    test(
      'disconnect cancels old ${read.name} read while explicit reconnect works',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final hello = Completer<void>();
        final sockets = <WebSocket>[];
        var connections = 0;
        final subscription = server.listen((request) async {
          connections++;
          final socket = await WebSocketTransformer.upgrade(request);
          sockets.add(socket);
          socket.listen((raw) {
            final envelope = jsonDecode(raw as String) as Map<String, dynamic>;
            if (envelope['type'] == 'hello' && !hello.isCompleted) {
              hello.complete();
            }
          });
        });
        final config = _GatedConfig(server.port, read);
        final client = MobileRealtimeClient(config: config);
        addTearDown(() async {
          await client.dispose();
          for (final socket in sockets) {
            await socket.close();
          }
          await subscription.cancel();
          await server.close(force: true);
        });

        final oldAttempt = client.connect();
        await config.reached.future;
        await client.disconnect();
        expect(client.isConnected, isFalse);
        final newAttempt = client.connect();
        await hello.future.timeout(const Duration(seconds: 5));
        await newAttempt;
        // The stale attempt completes after the replacement is already live.
        config.release.complete();
        await oldAttempt;
        expect(connections, 1);
        expect(client.isConnected, isTrue);
        expect(client.reconnectScheduled, isFalse);
      },
    );
  }

  test(
    'desktop handshake and heartbeat survive an explicit reconnect',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var hello = Completer<Map<String, dynamic>>();
      var pong = Completer<Map<String, dynamic>>();
      final sockets = <WebSocket>[];
      final subscription = server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          final envelope = jsonDecode(raw as String) as Map<String, dynamic>;
          if (envelope['type'] == 'hello') {
            hello.complete(envelope);
            socket.add(
              jsonEncode({
                'type': 'ping',
                'request_id': 'heartbeat-test',
                'payload': {},
              }),
            );
          } else if (envelope['type'] == 'pong') {
            pong.complete(envelope);
          }
        });
      });
      final client = MobileRealtimeClient(
        config: _LocalConfig(server.port),
        platform: 'macos',
        clientName: 'orialis_desktop',
        advertisedCapabilities: const {},
      );
      addTearDown(() async {
        await client.dispose();
        for (final socket in sockets) {
          await socket.close();
        }
        await subscription.cancel();
        await server.close(force: true);
      });
      for (var attempt = 0; attempt < 2; attempt++) {
        await client.connect();
        final payload = (await hello.future.timeout(
          const Duration(seconds: 5),
        ))['payload'];
        expect(payload['platform'], 'macos');
        expect(payload['client'], 'orialis_desktop');
        expect(payload['capabilities'], isEmpty);
        final response = await pong.future.timeout(const Duration(seconds: 5));
        expect(response['request_id'], 'heartbeat-test');
        await client.disconnect();
        expect(client.isConnected, isFalse);
        expect(client.reconnectScheduled, isFalse);
        hello = Completer<Map<String, dynamic>>();
        pong = Completer<Map<String, dynamic>>();
      }
      expect(sockets, hasLength(2));
    },
  );
}
