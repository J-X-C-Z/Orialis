import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart';

import '../../app/app.dart';
import '../../core/sync/sync_engine.dart';
import '../events/data/event_repository.dart';
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
      final database = ref.watch(databaseProvider);
      final manager = WearConnectionManager(
        ref.watch(wearTransportProvider),
        snapshotLoader: producer.read,
        taskCompletionHandler: (request) async {
          final token = await config.sessionToken();
          final server = await config.serverUrl();
          if (token == null) return {'status': 'rejected'};
          final task =
              await (database.select(database.tasks)..where(
                    (row) =>
                        row.id.equals(request['taskId'] as String) &
                        row.deletedAt.isNull(),
                  ))
                  .getSingleOrNull();
          if (task == null) return {'status': 'rejected'};
          if (task.remoteVersion != request['baseVersion']) {
            return {'status': 'conflict'};
          }
          if (await config.sessionToken() != token ||
              await config.serverUrl() != server) {
            return {'status': 'rejected'};
          }
          final completed = request['completed'] as bool;
          if (task.completed != completed) {
            await EventRepository(
              database: database,
              config: config,
            ).completeTask(task, completed);
          }
          final syncState = await SyncEngine(
            database: database,
            config: config,
            requireSession: true,
          ).syncOnce();
          if (syncState == SyncState.conflict) return {'status': 'conflict'};
          if (syncState != SyncState.idle ||
              await config.sessionToken() != token ||
              await config.serverUrl() != server) {
            return {'status': 'pending'};
          }
          final current = await (database.select(
            database.tasks,
          )..where((row) => row.id.equals(task.id))).getSingleOrNull();
          return {
            'status':
                current?.completed == completed &&
                    current?.syncStatus == 'synced'
                ? 'completed'
                : 'pending',
          };
        },
      );
      config.addIdentityListener(manager.revokeSession);
      ref.onDispose(() => config.removeIdentityListener(manager.revokeSession));
      return manager;
    });
