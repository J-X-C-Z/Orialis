import 'package:drift/drift.dart';

import '../database/app_database.dart';
import 'outbox_store.dart';

/// Signals new domain edits, rather than transport status changes. In-flight,
/// retry and conflict bookkeeping must not create an automatic retry loop.
Stream<void> watchDesktopLocalChanges(AppDatabase database) {
  var previous = <String, (int, String)>{};
  final query = database.select(database.outboxMutations)
    ..where(
      (row) =>
          row.entityType.isIn(const [
            'task',
            'schedule',
            'project',
            'project_milestone',
          ]) &
          row.status.equals(OutboxStatus.acknowledged).not(),
    );
  return query
      .watch()
      .map((rows) {
        final current = {
          for (final row in rows)
            row.mutationId: (row.entityRevision, row.operation),
        };
        final changed = current.entries.any(
          (entry) => previous[entry.key] != entry.value,
        );
        previous = current;
        return changed;
      })
      .where((changed) => changed)
      .map<void>((_) {});
}
