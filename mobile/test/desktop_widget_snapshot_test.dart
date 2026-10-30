import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/desktop_widgets/desktop_widget_sync.dart';

Task task(
  String id, {
  String? due,
  bool completed = false,
  String? deletedAt,
}) => Task(
  id: id,
  title: id,
  due: due,
  completed: completed,
  deletedAt: deletedAt,
  version: 1,
  remoteVersion: 0,
  localRevision: 0,
  createdAt: '',
  updatedAt: '',
  syncStatus: 'synced',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'clears old account then publishes changes and stops after dispose',
    () async {
      final calls = <Map<Object?, Object?>>[];
      const channel = MethodChannel('top.jxcz.orialis/widgets');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.arguments as Map<Object?, Object?>);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final stream = StreamController<List<Task>>();
      final sync = DesktopWidgetSync(stream.stream);
      stream.add([task('new-account')]);
      await Future<void>.delayed(Duration.zero);
      expect(calls.first['tasks'], isEmpty);
      expect((calls.last['tasks'] as List).single['id'], 'new-account');
      sync.dispose();
      stream.add([task('ignored')]);
      await Future<void>.delayed(Duration.zero);
      expect(calls.length, 2);
      await stream.close();
    },
  );
  test(
    'exports future dates for midnight refresh and excludes deleted tasks',
    () {
      final snapshot = desktopWidgetSnapshot([
        task('today', due: '2026-10-31'),
        task('done', due: '2026-10-31', completed: true),
        task('tomorrow', due: '2026-11-01'),
        task('deleted', due: '2026-10-31', deletedAt: '2026-10-31'),
      ], DateTime(2026, 10, 31, 12));
      expect(snapshot['totalCount'], 2);
      expect(snapshot['completedCount'], 1);
      final rows = snapshot['tasks'] as List;
      expect(rows.length, 3);
      final date = DateTime.parse(rows.first['dueAt'] as String).toLocal();
      expect(date, DateTime(2026, 10, 31));
      expect(rows[1]['completed'], true);
      expect(rows.first.containsKey('notes'), false);
    },
  );
}
