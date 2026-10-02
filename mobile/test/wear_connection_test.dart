import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/features/wear/wear_connection_manager.dart';
import 'package:orialis_mobile/features/wear/wear_protocol.dart';
import 'package:orialis_mobile/features/wear/wear_transport.dart';

class TestTransport implements WearTransport {
  @override
  Future<void> openApp() async {}
  final input = StreamController<WearMessage>.broadcast(sync: true);
  final observations = StreamController<WearDiagnostics>.broadcast(sync: true);
  WearDiagnostics value = const WearDiagnostics(
    availability: WearAvailability.available,
    serviceConnection: WearPresence.online,
    nodeCount: 1,
    nodeIds: ['band'],
    wearAppInstalled: true,
    permissionsGranted: true,
    session: 'native-session',
    observedNodeId: 'band',
  );
  final sent = <String>[];
  int disconnects = 0;
  void Function(String)? onSend;
  @override
  Stream<WearMessage> get messages => input.stream;
  @override
  Stream<WearDiagnostics> get diagnostics => observations.stream;
  @override
  Future<WearDiagnostics> connect() async => value;
  @override
  Future<WearDiagnostics> refresh() async => value;
  @override
  Future<WearDiagnostics> requestPermissions() async => value;
  @override
  Future<WearDiagnostics> selectNode(String nodeId) async => value;
  @override
  Future<void> disconnect() async {
    disconnects++;
  }

  @override
  Future<void> send(String nodeId, String session, String data) async {
    sent.add(data);
    onSend?.call(data);
  }

  void reply(
    String data, {
    String node = 'band',
    String session = 'native-session',
  }) => input.add(WearMessage(node, session, data));
  Future<void> close() async {
    await input.close();
    await observations.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestTransport transport;
  late WearConnectionManager manager;
  setUp(() {
    transport = TestTransport();
    manager = WearConnectionManager(
      transport,
      responseTimeout: const Duration(milliseconds: 40),
    );
  });
  tearDown(() async {
    manager.dispose();
    await transport.close();
  });
  Future<void> ready() async {
    await manager.connect();
    await manager.selectNode('band');
  }

  test('SDK absence stays unknown and blocks messages', () async {
    transport.value = const WearDiagnostics(
      availability: WearAvailability.sdkUnavailable,
      lastError: 'sdk_unavailable',
    );
    await manager.connect();
    expect(manager.state.diagnostics.nodeCount, isNull);
    expect(manager.state.phone, WearPresence.unknown);
    await manager.ping();
    expect(transport.sent, isEmpty);
    expect(manager.state.error, 'connection_not_ready');
    await manager.revokeSession();
    expect(
      manager.state.diagnostics.availability,
      WearAvailability.sdkUnavailable,
    );
    expect(manager.state.diagnostics.nodeCount, isNull);
    expect(manager.state.diagnostics.wearAppInstalled, isNull);
    expect(manager.state.diagnostics.permissionsGranted, isNull);
    expect(manager.state.diagnostics.session, isNull);
    expect(manager.state.phone, WearPresence.offline);
  });
  test(
    'transport delivery and mismatched sessions do not imply Pong or target online',
    () async {
      await ready();
      final sending = manager.ping();
      await Future<void>.delayed(Duration.zero);
      final ping = WearProtocol.decode(
        transport.sent.single,
      )['payload']['pingId'];
      expect(manager.state.delivery, contains('等待 Pong'));
      expect(manager.state.phone, WearPresence.unknown);
      final pong = WearProtocol.encode('pong', {'pingId': ping});
      transport.reply(pong, session: 'old-account-session');
      transport.reply(WearProtocol.encode('pong', {'pingId': 'unsolicited'}));
      expect(manager.state.busy, isTrue);
      transport.reply(pong);
      await sending;
      expect(manager.state.phone, WearPresence.online);
      expect(manager.state.orialis, WearPresence.unknown);
      expect(manager.state.target, WearPresence.unknown);
    },
  );
  test('late Pong cannot replace timeout', () async {
    await ready();
    await manager.ping();
    final id = WearProtocol.decode(transport.sent.single)['payload']['pingId'];
    expect(manager.state.error, 'response_timeout');
    transport.reply(WearProtocol.encode('pong', {'pingId': id}));
    expect(manager.state.phone, WearPresence.unknown);
    expect(manager.state.error, 'response_timeout');
  });
  test(
    'snapshot waits for exact transfer and revision ACK without new persisted field',
    () async {
      await ready();
      final sending = manager.sendSnapshot({
        'transferId': 't',
        'revision': 3,
        'title': '中文🙂' * 600,
      });
      await Future<void>.delayed(Duration.zero);
      expect(transport.sent.length, greaterThan(1));
      transport.reply(
        WearProtocol.encode('snapshot.ack', {'transferId': 't', 'revision': 2}),
      );
      expect(manager.state.busy, isTrue);
      transport.reply(
        WearProtocol.encode('snapshot.ack', {'transferId': 't', 'revision': 3}),
      );
      await sending;
      expect(manager.state.delivery, contains('同步完成 · 手环已保存'));
      expect(manager.state.target, WearPresence.unknown);
    },
  );
  test(
    'account/server identity mutation revokes in-flight messages with no replay',
    () async {
      SharedPreferences.setMockInitialValues({});
      final config = AppConfig();
      config.addIdentityListener(manager.revokeSession);
      await ready();
      final sending = manager.ping();
      await config.setServerUrl('https://new.example');
      await sending;
      expect(manager.state.selectedNode, isNull);
      expect(manager.state.diagnostics.session, isNull);
      expect(manager.state.phone, WearPresence.offline);
      expect(transport.disconnects, 1);
      await manager.connect();
      expect(transport.sent.length, 1);
      config.removeIdentityListener(manager.revokeSession);
    },
  );
  test(
    'installation and permission observations for another wearable do not authorize send',
    () async {
      transport.value = const WearDiagnostics(
        availability: WearAvailability.available,
        serviceConnection: WearPresence.online,
        nodeCount: 2,
        nodeIds: ['band', 'another'],
        wearAppInstalled: true,
        permissionsGranted: true,
        session: 'native-session',
        observedNodeId: 'another',
      );
      await ready();
      await manager.ping();
      expect(transport.sent, isEmpty);
      expect(manager.state.error, 'connection_not_ready');
    },
  );
  test('service loss cancels ACK wait and releases busy state', () async {
    await ready();
    final sending = manager.ping();
    await Future<void>.delayed(Duration.zero);
    transport.observations.add(
      const WearDiagnostics(
        availability: WearAvailability.available,
        serviceConnection: WearPresence.offline,
        nodeCount: 0,
      ),
    );
    await sending;
    expect(manager.state.busy, isFalse);
    expect(manager.state.selectedNode, isNull);
    expect(manager.state.phone, WearPresence.unknown);
    expect(manager.state.diagnostics.session, isNull);
  });
  test(
    'incoming band Ping replies with same id but does not assert execution',
    () async {
      await ready();
      transport.reply(WearProtocol.encode('ping', {'pingId': 'watch-ping'}));
      await Future<void>.delayed(Duration.zero);
      expect(
        WearProtocol.decode(transport.sent.single)['payload']['pingId'],
        'watch-ping',
      );
      expect(manager.state.target, WearPresence.unknown);
    },
  );
  test(
    'Unicode frames respect serialized UTF-8 budget and reconstruct losslessly',
    () {
      final snapshot = {
        'transferId': 'unicode',
        'revision': 0,
        'title': '汉字🙂\\"' * 900,
      };
      final frames = WearProtocol.splitSnapshot(snapshot);
      final chunks = frames.map((frame) {
        expect(
          utf8.encode(frame).length,
          lessThanOrEqualTo(WearProtocol.maxFrameBytes),
        );
        final chunk = WearProtocol.decode(frame)['payload']['chunk'] as String;
        expect(
          utf8.encode(chunk).length,
          lessThanOrEqualTo(WearProtocol.maxChunkBytes),
        );
        expect(chunk.contains('\uFFFD'), isFalse);
        return chunk;
      }).join();
      expect(jsonDecode(chunks), snapshot);
      expect(
        WearProtocol.decode(frames.first)['payload']['checksum'],
        WearProtocol.checksum(chunks),
      );
      expect(
        () => WearProtocol.splitSnapshot({
          'transferId': 'too-big',
          'revision': 0,
          'title': '🙂' * 5000,
        }),
        throwsFormatException,
      );
    },
  );
}
