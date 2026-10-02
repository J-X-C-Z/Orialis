import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app.dart';
import 'wear_connection_manager.dart';
import 'wear_transport.dart';
import 'wear_snapshot_producer.dart';

final wearTransportProvider = Provider<WearTransport>(
  (ref) => NativeWearTransport(),
);
final wearConnectionProvider =
    StateNotifierProvider<WearConnectionManager, WearConnectionState>((ref) {
      final config = ref.watch(appConfigProvider);
      final producer = WearSnapshotProducer(
        ref.watch(databaseProvider),
        config,
      );
      final manager = WearConnectionManager(
        ref.watch(wearTransportProvider),
        snapshotLoader: producer.read,
      );
      config.addIdentityListener(manager.revokeSession);
      ref.onDispose(() => config.removeIdentityListener(manager.revokeSession));
      return manager;
    });
