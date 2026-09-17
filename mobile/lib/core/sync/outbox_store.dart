import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';

abstract final class OutboxStatus {
  static const pending = 'pending';
  static const inFlight = 'inFlight';
  static const acknowledged = 'acknowledged';
  static const conflict = 'conflict';
  static const failed = 'failed';
}

class OutboxStore {
  OutboxStore(this.database);

  final AppDatabase database;

  Future<OutboxMutation> enqueue({
    required String entityType,
    required String entityId,
    required String operation,
    required String payloadJson,
    required int? baseVersion,
    required int entityRevision,
    String? mutationId,
  }) async {
    final pending =
        await (database.select(database.outboxMutations)
              ..where(
                (row) =>
                    row.entityType.equals(entityType) &
                    row.entityId.equals(entityId) &
                    row.status.equals(OutboxStatus.pending),
              )
              ..orderBy([(row) => OrderingTerm.desc(row.createdAt)])
              ..limit(1))
            .getSingleOrNull();
    final now = DateTime.now().toUtc().toIso8601String();
    if (pending != null) {
      await (database.update(
        database.outboxMutations,
      )..where((row) => row.id.equals(pending.id))).write(
        OutboxMutationsCompanion(
          operation: Value(operation),
          payloadJson: Value(payloadJson),
          baseVersion: Value(baseVersion),
          entityRevision: Value(entityRevision),
          updatedAt: Value(now),
          lastError: const Value(null),
        ),
      );
      return (database.select(
        database.outboxMutations,
      )..where((row) => row.id.equals(pending.id))).getSingle();
    }

    final row = OutboxMutationsCompanion.insert(
      mutationId: mutationId ?? const Uuid().v7(),
      entityType: entityType,
      entityId: entityId,
      operation: operation,
      payloadJson: payloadJson,
      baseVersion: Value(baseVersion),
      entityRevision: Value(entityRevision),
      status: const Value(OutboxStatus.pending),
      createdAt: now,
      updatedAt: now,
    );
    await database.into(database.outboxMutations).insert(row);
    return (database.select(database.outboxMutations)
          ..where((value) => value.mutationId.equals(row.mutationId.value)))
        .getSingle();
  }

  Future<OutboxMutation?> findPendingForEntity(
    String entityType,
    String entityId,
  ) {
    return (database.select(database.outboxMutations)
          ..where(
            (row) =>
                row.entityType.equals(entityType) &
                row.entityId.equals(entityId) &
                row.status.equals(OutboxStatus.pending),
          )
          ..orderBy([(row) => OrderingTerm.desc(row.createdAt)])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<void> recoverInFlight() async {
    await (database.update(
      database.outboxMutations,
    )..where((row) => row.status.equals(OutboxStatus.inFlight))).write(
      const OutboxMutationsCompanion(status: Value(OutboxStatus.pending)),
    );
  }

  Future<void> markInFlight(String mutationId) async {
    await (database.update(database.outboxMutations)..where(
          (row) =>
              row.mutationId.equals(mutationId) &
              row.status.equals(OutboxStatus.pending),
        ))
        .write(
          OutboxMutationsCompanion(
            status: const Value(OutboxStatus.inFlight),
            attemptCount: const Value.absent(),
            updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
          ),
        );
    await database.customUpdate(
      'UPDATE outbox_mutations SET attempt_count = attempt_count + 1 WHERE mutation_id = ?',
      variables: [Variable<String>(mutationId)],
      updates: {database.outboxMutations},
    );
  }

  Future<void> acknowledge(String mutationId) =>
      _setTerminal(mutationId, OutboxStatus.acknowledged);

  /// Atomically acknowledges a Task mutation and applies its sync state.
  ///
  /// Keeping these writes in one transaction prevents a crash from leaving an
  /// acknowledged mutation paired with a still-pending entity.
  Future<bool> acknowledgeTaskMutation({
    required String mutationId,
    required String entityId,
    required int entityRevision,
    required int remoteVersion,
    int? serverVersion,
  }) => database.transaction(() async {
    final task = await (database.select(
      database.tasks,
    )..where((row) => row.id.equals(entityId))).getSingleOrNull();
    var entityUpdated = false;
    if (task != null &&
        task.localRevision == entityRevision &&
        task.syncStatus != 'synced') {
      await (database.update(
        database.tasks,
      )..where((row) => row.id.equals(entityId))).write(
        TasksCompanion(
          version: Value(serverVersion ?? task.version),
          remoteVersion: Value(remoteVersion),
          syncStatus: const Value('synced'),
        ),
      );
      entityUpdated = true;
    }
    await _setTerminal(mutationId, OutboxStatus.acknowledged);
    return entityUpdated;
  });

  /// Atomically acknowledges a Schedule mutation and applies its sync state.
  Future<bool> acknowledgeScheduleMutation({
    required String mutationId,
    required String entityId,
    required int entityRevision,
    required int remoteVersion,
    int? serverVersion,
  }) => database.transaction(() async {
    final event = await (database.select(
      database.calendarEvents,
    )..where((row) => row.id.equals(entityId))).getSingleOrNull();
    var entityUpdated = false;
    if (event != null &&
        event.localRevision == entityRevision &&
        event.syncStatus != 'synced') {
      await (database.update(
        database.calendarEvents,
      )..where((row) => row.id.equals(entityId))).write(
        CalendarEventsCompanion(
          version: Value(serverVersion ?? event.version),
          remoteVersion: Value(remoteVersion),
          syncStatus: const Value('synced'),
        ),
      );
      entityUpdated = true;
    }
    await _setTerminal(mutationId, OutboxStatus.acknowledged);
    return entityUpdated;
  });

  /// Repairs rows created by older code that acknowledged before updating the
  /// entity. A newer local revision is never marked synced by this recovery.
  Future<void> recoverAcknowledgedEntities() async {
    final acknowledged = await (database.select(
      database.outboxMutations,
    )..where((row) => row.status.equals(OutboxStatus.acknowledged))).get();
    for (final mutation in acknowledged) {
      if (mutation.entityType == 'task') {
        await database.transaction(() async {
          final task =
              await (database.select(database.tasks)
                    ..where((row) => row.id.equals(mutation.entityId)))
                  .getSingleOrNull();
          if (task != null &&
              task.localRevision == mutation.entityRevision &&
              task.syncStatus != 'synced') {
            await (database.update(database.tasks)
                  ..where((row) => row.id.equals(mutation.entityId)))
                .write(const TasksCompanion(syncStatus: Value('synced')));
          }
        });
      } else if (mutation.entityType == 'schedule') {
        await database.transaction(() async {
          final event =
              await (database.select(database.calendarEvents)
                    ..where((row) => row.id.equals(mutation.entityId)))
                  .getSingleOrNull();
          if (event != null &&
              event.localRevision == mutation.entityRevision &&
              event.syncStatus != 'synced') {
            await (database.update(
              database.calendarEvents,
            )..where((row) => row.id.equals(mutation.entityId))).write(
              const CalendarEventsCompanion(syncStatus: Value('synced')),
            );
          }
        });
      }
    }
  }

  Future<void> markConflict(String mutationId, Object error) =>
      _setTerminal(mutationId, OutboxStatus.conflict, error.toString());

  Future<void> markFailed(String mutationId, Object error) =>
      _setTerminal(mutationId, OutboxStatus.failed, error.toString());

  Future<void> _setTerminal(
    String mutationId,
    String status, [
    String? error,
  ]) async {
    await (database.update(database.outboxMutations)..where(
          (row) =>
              row.mutationId.equals(mutationId) &
              row.status.equals(OutboxStatus.inFlight),
        ))
        .write(
          OutboxMutationsCompanion(
            status: Value(status),
            lastError: Value(error),
            updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
          ),
        );
  }
}
