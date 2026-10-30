import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/features/wear/wear_connection_manager.dart';
import 'package:orialis_mobile/features/wear/wear_protocol.dart';
import 'package:orialis_mobile/features/wear/wear_snapshot_producer.dart';
import 'package:orialis_mobile/features/wear/wear_transport.dart';

import 'wear_connection_test.dart' show TestTransport;

void main() {
  late TestTransport transport;
  late StreamController<void> changes;
  late WearConnectionManager manager;
  var content = 'initial', reads = 0, verified = true, acknowledge = true;
  Completer<WearSnapshotPreview>? loading;
  WearSnapshotPreview preview() => WearSnapshotPreview(
    snapshot: {
      'transferId': 'transfer-$reads',
      'revision': reads,
      'view': {
        'updatedAt': DateTime.now().toIso8601String(),
        'content': content,
      },
    },
    included: const {},
    total: const {},
    bytes: 100,
    updatedAt: DateTime.now(),
    accountScopeVerified: verified,
  );
  setUp(() {
    content = 'initial';
    reads = 0;
    verified = true;
    acknowledge = true;
    loading = null;
    transport = TestTransport();
    changes = StreamController<void>.broadcast(sync: true);
    transport.onSend = (data) {
      final frame = WearProtocol.decode(data);
      if (acknowledge && frame['type'] == 'snapshot.part') {
        final payload = frame['payload'] as Map;
        transport.reply(
          WearProtocol.encode('snapshot.ack', {
            'transferId': payload['transferId'],
            'revision': payload['revision'],
          }),
          session: manager.state.diagnostics.session!,
        );
      }
    };
  });
  tearDown(() async {
    if (manager.mounted) manager.dispose();
    await changes.close();
    await transport.close();
  });
  Future<void> ready() async {
    manager = WearConnectionManager(
      transport,
      snapshotChanges: changes.stream,
      snapshotLoader: () async {
        reads++;
        return loading?.future ?? preview();
      },
    );
    await manager.connect();
    await manager.selectNode('band');
  }

  void syncTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        manager.dispose();
      }
    });
  }

  const debounce = Duration(milliseconds: 800);
  syncTest(
    'ready syncs automatically; bursts coalesce and identical content skips radio',
    (tester) async {
      await ready();
      await tester.pump(debounce);
      expect(transport.sent.length, 1);
      expect(manager.state.delivery, '同步完成 · 手环已保存');
      changes.add(null);
      changes.add(null);
      changes.add(null);
      await tester.pump(debounce);
      expect(reads, 2);
      expect(transport.sent.length, 1);
      content = 'changed task';
      changes.add(null);
      changes.add(null);
      await tester.pump(debounce);
      expect(transport.sent.length, 2);
      final frame = WearProtocol.decode(transport.sent.last);
      expect(
        jsonDecode(frame['payload']['chunk'] as String)['view']['content'],
        'changed task',
      );
    },
  );
  syncTest('edits while waiting for ACK send latest content after ACK', (
    tester,
  ) async {
    acknowledge = false;
    await ready();
    await tester.pump(debounce);
    expect(manager.state.busy, isTrue);
    content = 'latest';
    changes.add(null);
    await tester.pump(debounce);
    expect(transport.sent.length, 1);
    final payload = WearProtocol.decode(transport.sent.single)['payload'];
    acknowledge = true;
    transport.reply(
      WearProtocol.encode('snapshot.ack', {
        'transferId': payload['transferId'],
        'revision': payload['revision'],
      }),
    );
    await tester.pump();
    await tester.pump(debounce);
    expect(transport.sent.length, 2);
    expect(manager.state.delivery, '同步完成 · 手环已保存');
  });
  syncTest('reconnect sends fresh snapshot even with unchanged content', (
    tester,
  ) async {
    await ready();
    await tester.pump(debounce);
    transport.observations.add(
      const WearDiagnostics(
        availability: WearAvailability.available,
        serviceConnection: WearPresence.offline,
      ),
    );
    transport.observations.add(
      const WearDiagnostics(
        availability: WearAvailability.available,
        serviceConnection: WearPresence.online,
        nodeIds: ['band'],
        observedNodeId: 'band',
        permissionsGranted: true,
        session: 'restored-session',
      ),
    );
    await tester.pump(debounce);
    expect(transport.sent.length, 2);
    expect(manager.state.selectedNode, 'band');
  });
  syncTest('unverified local fallback never automatically leaves phone', (
    tester,
  ) async {
    verified = false;
    await ready();
    await tester.pump(debounce);
    expect(transport.sent, isEmpty);
    expect(manager.state.error, 'account_scope_unverified');
  });
  syncTest('revocation during read cancels send and subsequent ticks', (
    tester,
  ) async {
    loading = Completer<WearSnapshotPreview>();
    await ready();
    await tester.pump(debounce);
    await manager.revokeSession();
    loading!.complete(preview());
    await tester.pump();
    changes.add(null);
    await tester.pump(const Duration(minutes: 1));
    expect(transport.sent, isEmpty);
    expect(manager.state.selectedNode, isNull);
  });
  syncTest(
    'periodic check catches missed change without resending identical snapshot',
    (tester) async {
      await ready();
      await tester.pump(debounce);
      content = 'missed remote update';
      await tester.pump(const Duration(seconds: 30));
      await tester.pump(debounce);
      expect(transport.sent.length, 2);
      await tester.pump(const Duration(seconds: 30));
      await tester.pump(debounce);
      expect(transport.sent.length, 2);
    },
  );
  syncTest('ACK timeout retries unchanged data on the next periodic check', (
    tester,
  ) async {
    acknowledge = false;
    await ready();
    await tester.pump(debounce);
    await tester.pump(const Duration(seconds: 89));
    expect(transport.sent.length, 1);
    expect(manager.state.busy, isTrue);
    acknowledge = true;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(debounce);
    expect(transport.sent.length, 2);
    expect(manager.state.delivery, '同步完成 · 手环已保存');
  });

  syncTest(
    'reconnection discards an old read and sends a newly loaded snapshot',
    (tester) async {
      loading = Completer<WearSnapshotPreview>();
      await ready();
      await tester.pump(debounce);
      final oldRead = loading!;
      final oldPreview = preview();
      transport.observations.add(
        const WearDiagnostics(
          availability: WearAvailability.available,
          serviceConnection: WearPresence.offline,
        ),
      );
      transport.observations.add(transport.value);
      await tester.pump(debounce);
      content = 'fresh after reconnect';
      loading = null;
      oldRead.complete(oldPreview);
      await tester.pump();
      await tester.pump(debounce);
      expect(transport.sent.length, 1);
      final frame = WearProtocol.decode(transport.sent.single);
      expect(
        jsonDecode(frame['payload']['chunk'] as String)['view']['content'],
        'fresh after reconnect',
      );
    },
  );
}
