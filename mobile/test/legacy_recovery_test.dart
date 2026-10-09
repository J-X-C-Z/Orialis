import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/database/legacy_database_reader.dart';
import 'package:orialis_mobile/pages/profile/legacy_recovery.dart';

class _NoMigration implements QueryExecutorUser {
  @override
  int get schemaVersion => 0;
  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}

void main() {
  testWidgets(
    'old schema is discoverable and selectable without migration or account sync',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('ori106-legacy-ui-'),
      ))!;
      final file = File('${root.path}/orialis.sqlite');
      await tester.runAsync(() async {
        final seed = NativeDatabase(
          file,
          enableMigrations: false,
          setup: (db) {
            db.execute('CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT)');
            db.execute("INSERT INTO tasks VALUES ('old-task', '旧版离线任务')");
            db.execute(
              'CREATE TABLE outbox_mutations (mutation_id TEXT, payload_json TEXT)',
            );
            db.execute(
              "INSERT INTO outbox_mutations VALUES ('stable-old-id', '{\"title\":\"旧版离线任务\"}')",
            );
            db.execute('PRAGMA user_version = 3');
          },
        );
        await seed.ensureOpen(_NoMigration());
        await seed.close();
      });
      final hash = sha256.convert(
        await tester.runAsync(file.readAsBytes) ?? [],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseDirectoryProvider.overrideWithValue(() async => root),
          ],
          child: const MaterialApp(
            home: Scaffold(body: LegacyRecoveryNotice(allowOpen: true)),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pumpAndSettle();
      expect(find.text(legacyRecoveryMessage), findsOneWidget);
      await tester.tap(find.text('旧版数据（只读）'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('tasks').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('旧版离线任务'), findsOneWidget);
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('outbox_mutations').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('stable-old-id'), findsOneWidget);
      // Full pages remain accessible rather than truncating the only recovery view.
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      expect(find.textContaining('stable-old-id'), findsNothing);
      await tester.tap(find.text('上一页'));
      await tester.pumpAndSettle();
      expect(find.textContaining('stable-old-id'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        final reader = LegacyDatabaseReader(file);
        expect(await reader.availableTables(), ['tasks', 'outbox_mutations']);
        expect(
          (await reader.readPage('outbox_mutations', 0)).single['mutation_id'],
          'stable-old-id',
        );
        await reader.close();
        expect(sha256.convert(await file.readAsBytes()), hash);
        await root.delete(recursive: true);
      });
    },
  );
}
