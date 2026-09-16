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
  BoolColumn get important => boolean().withDefault(const Constant(false))();
  BoolColumn get urgent => boolean().withDefault(const Constant(false))();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
  TextColumn get completedAt => text().nullable()();
  TextColumn get projectId => text().nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();
  IntColumn get remoteVersion => integer().withDefault(const Constant(0))();
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
  IntColumn get version => integer().withDefault(const Constant(1))();
  IntColumn get remoteVersion => integer().withDefault(const Constant(0))();
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
  TextColumn get syncStatus => text().withDefault(const Constant('synced'))();
  IntColumn get remoteVersion => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {conversationId, id};
}

class SyncMetadata extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

@DriftDatabase(tables: [Tasks, CalendarEvents, Messages, SyncMetadata])
class AppDatabase extends _$AppDatabase {
  AppDatabase({QueryExecutor? executor}) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(tasks, tasks.remoteVersion);
        await m.addColumn(calendarEvents, calendarEvents.remoteVersion);
      }
      if (from < 3) {
        await m.createTable(messages);
      }
    },
  );

  Stream<List<Task>> watchActiveTasks() {
    return (select(tasks)
          ..where((row) => row.deletedAt.isNull())
          ..orderBy([(row) => OrderingTerm(expression: row.due)]))
        .watch();
  }

  Stream<List<CalendarEvent>> watchActiveCalendarEvents() {
    return (select(calendarEvents)
          ..where((row) => row.deletedAt.isNull())
          ..orderBy([(row) => OrderingTerm(expression: row.startAt)]))
        .watch();
  }

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'orialis');
  }

  static QueryExecutor inMemoryExecutor() => NativeDatabase.memory();
}
