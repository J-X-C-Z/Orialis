import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

/// Unassigned pre-account data never enters an account's repositories or sync.
/// Use raw reads so older schemas are viewable without running migrations.
class LegacyDatabaseReader implements QueryExecutorUser {
  LegacyDatabaseReader(File file)
    : _executor = NativeDatabase(
        file,
        enableMigrations: false,
        setup: (database) => database.execute('PRAGMA query_only = ON'),
      );

  final QueryExecutor _executor;
  static const tables = [
    'tasks',
    'calendar_events',
    'projects',
    'project_milestones',
    'conversations',
    'messages',
    'outbox_mutations',
    'sync_metadata',
  ];

  @override
  int get schemaVersion => 0;
  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}

  Future<List<String>> availableTables() async {
    await _executor.ensureOpen(this);
    final rows = await _executor.runSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
      [],
    );
    return tables
        .where((name) => rows.any((row) => row['name'] == name))
        .toList();
  }

  Future<List<Map<String, Object?>>> readPage(String table, int offset) async {
    if (!tables.contains(table) || offset < 0) {
      throw ArgumentError('invalid page');
    }
    await _executor.ensureOpen(this);
    return _executor.runSelect('SELECT * FROM "$table" LIMIT 100 OFFSET ?', [
      offset,
    ]);
  }

  Future<void> close() => _executor.close();
}
