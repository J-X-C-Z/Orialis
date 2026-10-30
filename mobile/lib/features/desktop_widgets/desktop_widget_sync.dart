import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/database/app_database.dart';

Map<String, Object?> desktopWidgetSnapshot(List<Task> tasks, DateTime now) {
  DateTime? dueAt(Task task) {
    final due = task.due;
    if (due == null) return null;
    return DateTime.tryParse(
      '$due${task.dueTime == null ? 'T00:00:00' : 'T${task.dueTime}'}',
    );
  }

  final active = tasks.where((task) => task.deletedAt == null).toList();
  final today = active.where((task) {
    final due = dueAt(task)?.toLocal();
    return due != null &&
        due.year == now.year &&
        due.month == now.month &&
        due.day == now.day;
  }).toList();
  return {
    'tasks': [
      for (final task in active)
        {
          'id': task.id,
          'title': task.title,
          'dueAt': dueAt(task)?.toUtc().toIso8601String(),
          'completed': task.completed,
        },
    ],
    'completedCount': today.where((task) => task.completed).length,
    'totalCount': today.length,
    'updatedAt': now.toUtc().toIso8601String(),
  };
}

class DesktopWidgetSync {
  DesktopWidgetSync(Stream<List<Task>> tasks) {
    // Clear the previous account before the new database emits its first value.
    _publish([]);
    _subscription = tasks.listen(
      _publish,
      onError: (Object error) {
        debugPrint(
          'Desktop widget database stream failed: ${error.runtimeType}',
        );
      },
    );
  }

  static const _channel = MethodChannel('top.jxcz.orialis/widgets');
  late final StreamSubscription<List<Task>> _subscription;
  bool _disposed = false;

  void _publish(List<Task> tasks) {
    if (_disposed) return;
    unawaited(_send(tasks));
  }

  Future<void> _send(List<Task> tasks) async {
    try {
      await _channel.invokeMethod<void>(
        'updateSnapshot',
        desktopWidgetSnapshot(tasks, DateTime.now()),
      );
    } on PlatformException catch (error) {
      debugPrint('Desktop widget update failed: ${error.code}');
    } on MissingPluginException {
      debugPrint('Desktop widgets are unavailable in this host build');
    }
  }

  void dispose() {
    _disposed = true;
    unawaited(_subscription.cancel());
  }
}
