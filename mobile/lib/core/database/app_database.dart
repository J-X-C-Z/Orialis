import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:drift/native.dart';

part 'app_database.g.dart';

class Tasks extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get notes => text().nullable()();
  TextColumn get due => text().nullable()();
  TextColumn get dueTime => text().nullable()();
  BoolColumn get important => boolean().nullable()();
  BoolColumn get urgent => boolean().nullable()();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
  TextColumn get completedAt => text().nullable()();
  IntColumn get reminderMinutes => integer().nullable()();
  TextColumn get projectId => text().nullable()();
  TextColumn get parentTaskId => text().nullable()();
  TextColumn get scheduleId => text().nullable()();
  TextColumn get recurrence => text().nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();
  IntColumn get remoteVersion => integer().withDefault(const Constant(0))();
  IntColumn get localRevision => integer().withDefault(const Constant(0))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();
  TextColumn get syncStatus => text().withDefault(const Constant('synced'))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class CalendarEvents extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get location => text().nullable()();
  TextColumn get startAt => text()();
  TextColumn get endAt => text()();
  BoolColumn get allDay => boolean().withDefault(const Constant(false))();
  BoolColumn get important => boolean().withDefault(const Constant(false))();
  IntColumn get reminderMinutes => integer().nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();
  IntColumn get remoteVersion => integer().withDefault(const Constant(0))();
  IntColumn get localRevision => integer().withDefault(const Constant(0))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();
  TextColumn get syncStatus => text().withDefault(const Constant('synced'))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Projects extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get goal => text().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get color => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get startDate => text().nullable()();
  TextColumn get due => text().nullable()();
  TextColumn get nextActionTaskId => text().nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();
  IntColumn get remoteVersion => integer().withDefault(const Constant(0))();
  IntColumn get localRevision => integer().withDefault(const Constant(0))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();
  TextColumn get syncStatus => text().withDefault(const Constant('synced'))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@TableIndex(
  name: 'idx_project_milestones_project_position',
  columns: {#projectId, #deletedAt, #position, #id},
)
class ProjectMilestones extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text()();
  TextColumn get title => text()();
  TextColumn get due => text().nullable()();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
  TextColumn get completedAt => text().nullable()();
  IntColumn get position => integer().withDefault(const Constant(0))();
  IntColumn get version => integer().withDefault(const Constant(1))();
  IntColumn get remoteVersion => integer().withDefault(const Constant(0))();
  IntColumn get localRevision => integer().withDefault(const Constant(0))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();
  TextColumn get syncStatus => text().withDefault(const Constant('synced'))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Messages extends Table {
  TextColumn get conversationId => text()();
  TextColumn get id => text()();
  TextColumn get role => text()();
  TextColumn get content => text()();
  TextColumn get createdAt => text()();
  TextColumn get attachmentsJson => text().withDefault(const Constant('[]'))();
  TextColumn get syncStatus => text().withDefault(const Constant('synced'))();
  IntColumn get remoteVersion => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {conversationId, id};
}

class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get type => text().withDefault(const Constant('normal'))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  IntColumn get version => integer().withDefault(const Constant(1))();
  IntColumn get remoteVersion => integer().withDefault(const Constant(0))();
  IntColumn get localRevision => integer().withDefault(const Constant(0))();
  TextColumn get deletedAt => text().nullable()();
  TextColumn get syncStatus => text().withDefault(const Constant('synced'))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class SyncMetadata extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

class OutboxMutations extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get mutationId => text().unique()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get operation => text()();
  TextColumn get payloadJson => text()();
  IntColumn get baseVersion => integer().nullable()();
  IntColumn get entityRevision => integer().withDefault(const Constant(0))();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
}

@DriftDatabase(
  tables: [
    Tasks,
    CalendarEvents,
    Messages,
    Conversations,
    SyncMetadata,
    OutboxMutations,
    Projects,
    ProjectMilestones,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase({QueryExecutor? executor}) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 9;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      Future<bool> hasColumn(String tableName, String columnName) async {
        final columns = await customSelect(
          'PRAGMA table_info("$tableName")',
        ).get();
        return columns.any((row) => row.data['name'] == columnName);
      }

      Future<bool> hasSchemaObject(String type, String name) async {
        final objects = await customSelect(
          'SELECT name FROM sqlite_master WHERE type = ? AND name = ?',
          variables: [Variable.withString(type), Variable.withString(name)],
        ).get();
        return objects.isNotEmpty;
      }

      Future<void> addColumnIfMissing(
        String tableName,
        String columnName,
        Future<void> Function() addColumn,
      ) async {
        if (!await hasColumn(tableName, columnName)) {
          await addColumn();
        }
      }

      if (from < 2) {
        await addColumnIfMissing(
          'tasks',
          'remote_version',
          () => m.addColumn(tasks, tasks.remoteVersion),
        );
        await addColumnIfMissing(
          'calendar_events',
          'remote_version',
          () => m.addColumn(calendarEvents, calendarEvents.remoteVersion),
        );
      }
      if (from < 3) {
        if (!await hasSchemaObject('table', 'messages')) {
          await m.createTable(messages);
        }
      }
      if (from < 4) {
        await addColumnIfMissing(
          'messages',
          'attachments_json',
          () => m.addColumn(messages, messages.attachmentsJson),
        );
      }
      if (from < 5) {
        if (!await hasSchemaObject('table', 'conversations')) {
          await m.createTable(conversations);
        }
      }
      if (from < 6) {
        await customStatement('ALTER TABLE tasks RENAME TO tasks_v5');
        await customStatement('''
          CREATE TABLE tasks (
            id TEXT NOT NULL PRIMARY KEY,
            title TEXT NOT NULL,
            notes TEXT,
            due TEXT,
            due_time TEXT,
            important INTEGER,
            urgent INTEGER,
            completed INTEGER NOT NULL DEFAULT 0,
            completed_at TEXT,
            reminder_minutes INTEGER,
            project_id TEXT,
            recurrence TEXT,
            version INTEGER NOT NULL DEFAULT 1,
            remote_version INTEGER NOT NULL DEFAULT 0,
            local_revision INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            deleted_at TEXT,
            sync_status TEXT NOT NULL DEFAULT 'synced'
          )
        ''');
        final oldTaskColumns = await customSelect(
          'PRAGMA table_info(tasks_v5)',
        ).get();
        final hasOldRecurrence = oldTaskColumns.any(
          (row) => row.data['name'] == 'recurrence',
        );
        final oldRecurrence = hasOldRecurrence ? 'recurrence' : 'NULL';
        await customStatement('''
          INSERT INTO tasks (
            id, title, notes, due, due_time, important, urgent, completed,
            completed_at, reminder_minutes, project_id, recurrence, version,
            remote_version, created_at,
            updated_at, deleted_at, sync_status
          )
          SELECT id, title, notes, due, due_time, important, urgent, completed,
            completed_at, NULL, project_id, $oldRecurrence, version,
            remote_version, created_at,
            updated_at, deleted_at, sync_status
          FROM tasks_v5
        ''');
        await customStatement('DROP TABLE tasks_v5');
        await addColumnIfMissing(
          'calendar_events',
          'reminder_minutes',
          () => m.addColumn(calendarEvents, calendarEvents.reminderMinutes),
        );
        await addColumnIfMissing(
          'calendar_events',
          'local_revision',
          () => m.addColumn(calendarEvents, calendarEvents.localRevision),
        );
        if (!await hasSchemaObject('table', 'outbox_mutations')) {
          await m.createTable(outboxMutations);
        }
      }
      if (from < 7) {
        if (!await hasSchemaObject('table', 'projects')) {
          await m.createTable(projects);
        }
        if (!await hasSchemaObject('table', 'project_milestones')) {
          await m.createTable(projectMilestones);
        }
        // SQLite supports IF NOT EXISTS for indexes; use it here because a
        // pre-release database may have the index without matching Drift's
        // recorded schema version.
        await customStatement(
          'CREATE INDEX IF NOT EXISTS '
          'idx_project_milestones_project_position '
          'ON project_milestones (project_id, deleted_at, position, id)',
        );
      }
      if (from < 8) {
        // Some pre-release A03 builds shipped columns while still reporting
        // an older schema version. Keep upgrades idempotent for those
        // devices instead of failing on duplicate-column errors.
        await addColumnIfMissing(
          'conversations',
          'local_revision',
          () => m.addColumn(conversations, conversations.localRevision),
        );
      }
      if (from < 9) {
        await addColumnIfMissing(
          'tasks',
          'parent_task_id',
          () => m.addColumn(tasks, tasks.parentTaskId),
        );
        await addColumnIfMissing(
          'tasks',
          'schedule_id',
          () => m.addColumn(tasks, tasks.scheduleId),
        );
        await addColumnIfMissing(
          'calendar_events',
          'important',
          () => m.addColumn(calendarEvents, calendarEvents.important),
        );
      }
    },
  );

  Stream<List<Task>> watchActiveTasks() {
    return (select(tasks)
          ..where((row) => row.deletedAt.isNull())
          ..orderBy([(row) => OrderingTerm(expression: row.due)]))
        .watch();
  }

  Stream<List<Project>> watchActiveProjects() {
    return (select(projects)
          ..where((row) => row.deletedAt.isNull())
          ..orderBy([
            (row) => OrderingTerm(expression: row.createdAt),
            (row) => OrderingTerm(expression: row.id),
          ]))
        .watch();
  }

  Stream<List<ProjectMilestone>> watchActiveProjectMilestones(
    String projectId,
  ) {
    return (select(projectMilestones)
          ..where(
            (row) => row.projectId.equals(projectId) & row.deletedAt.isNull(),
          )
          ..orderBy([
            (row) => OrderingTerm(expression: row.position),
            (row) => OrderingTerm(expression: row.id),
          ]))
        .watch();
  }

  Stream<List<CalendarEvent>> watchActiveCalendarEvents() {
    return (select(calendarEvents)
          ..where((row) => row.deletedAt.isNull())
          ..orderBy([(row) => OrderingTerm(expression: row.startAt)]))
        .watch();
  }

  Stream<List<Conversation>> watchActiveConversations() {
    return (select(conversations)
          ..where((row) => row.deletedAt.isNull())
          ..orderBy([
            (row) =>
                OrderingTerm(expression: row.type, mode: OrderingMode.desc),
            (row) => OrderingTerm(
              expression: row.updatedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'orialis');
  }

  static QueryExecutor inMemoryExecutor() => NativeDatabase.memory();
}
