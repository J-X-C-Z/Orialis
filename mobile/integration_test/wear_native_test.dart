// Real device acceptance. Uses existing login read-only; never changes phone DB.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/wear/wear_connection_manager.dart';
import 'package:orialis_mobile/features/wear/wear_snapshot_producer.dart';
import 'package:orialis_mobile/features/wear/wear_transport.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('physical Xiaomi wearable ping and persisted account snapshot', (
    tester,
  ) async {
    expect(
      const bool.fromEnvironment('WEAR_REAL_DEVICE'),
      isTrue,
      reason: 'Explicit real device acceptance required',
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('Orialis 手环互联验收'))),
      ),
    );
    await tester.runAsync(() async {
      final database = AppDatabase(name: 'orialis');
      final config = AppConfig();
      final producer = WearSnapshotProducer(database, config);
      final manager = WearConnectionManager(
        NativeWearTransport(),
        snapshotLoader: producer.read,
      );
      config.addIdentityListener(manager.revokeSession);
      void evidence(String phase) {
        final s = manager.state, d = manager.state.diagnostics;
        debugPrint(
          'WEAR_DEVICE_EVIDENCE ${jsonEncode({'phase': phase, 'availability': d.availability.name, 'service': d.serviceConnection.name, 'nodeCount': d.nodeCount, 'installed': d.wearAppInstalled, 'permission': d.permissionsGranted, 'session': d.session != null, 'phone': s.phone.name, 'delivery': s.delivery, 'error': s.error ?? d.lastError, 'verifiedSource': s.snapshot?.accountScopeVerified, 'included': s.snapshot?.included})}',
        );
      }

      try {
        await manager.refreshSnapshot();
        evidence('source_preflight');
        await manager.connect();
        evidence('discover');
        expect(
          manager.state.diagnostics.nodeIds.length,
          1,
          reason:
              'One real connected wearable required; never guess among multiple targets',
        );
        await manager.selectNode(manager.state.diagnostics.nodeIds.single);
        evidence('select');
        if (manager.state.diagnostics.permissionsGranted != true) {
          await manager.requestPermissions();
          evidence('authorize');
        }
        expect(
          manager.state.diagnostics.canMessageFor(manager.state.selectedNode),
          true,
        );
        await manager.openApp();
        await manager.ping();
        evidence('pong');
        expect(manager.state.phone, WearPresence.online);
        await manager.refreshSnapshot();
        evidence('source');
        expect(manager.state.snapshot?.accountScopeVerified, true);
        await manager.sendCurrentSnapshot();
        evidence('persist');
        expect(manager.state.delivery, '同步完成 · 手环已保存');
      } finally {
        config.removeIdentityListener(manager.revokeSession);
        await manager.revokeSession();
        manager.dispose();
        await database.close();
      }
    });
  });
}
