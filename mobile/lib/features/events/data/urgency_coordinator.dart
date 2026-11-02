import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/database/app_database.dart';
import '../../chat/data/agent_chat_service.dart';
import 'event_repository.dart';

class UrgencyDecision {
  const UrgencyDecision(this.id, this.urgent, this.reason);
  final String id, reason;
  final bool urgent;
}

class UrgencyAssessment {
  UrgencyAssessment.parse(String content, Set<String> taskIds) {
    final decoded = jsonDecode(content);
    if (decoded is! Map ||
        decoded['tasks'] is! List ||
        decoded['reviewAt'] is! String) {
      throw const FormatException('Invalid urgency assessment');
    }
    final review = decoded['reviewAt'] as String;
    if (!RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(review)) {
      throw const FormatException('Urgency review time requires an offset');
    }
    reviewAt = DateTime.parse(review);
    final seen = <String>{};
    decisions = (decoded['tasks'] as List).map((row) {
      if (row is! Map ||
          row['id'] is! String ||
          !taskIds.contains(row['id']) ||
          !seen.add(row['id'] as String) ||
          row['urgent'] is! bool ||
          row['reason'] is! String ||
          (row['reason'] as String).trim().isEmpty) {
        throw const FormatException('Invalid urgency decision');
      }
      return UrgencyDecision(
        row['id'] as String,
        row['urgent'] as bool,
        row['reason'] as String,
      );
    }).toList();
  }

  late final DateTime reviewAt;
  late final List<UrgencyDecision> decisions;
}

/// Reuses authenticated background completions without creating chat messages.
class UrgencyCoordinator {
  UrgencyCoordinator({
    required this.database,
    required this.repository,
    required this.agents,
    required this.ownsDatabase,
  });

  final AppDatabase database;
  final EventRepository repository;
  final AgentChatService agents;
  final Future<bool> Function() ownsDatabase;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _debounce, _review, _poll;
  Completer<void>? _pollDone;
  bool _disposed = false, _running = false, _dirty = false;
  int _generation = 0;
  String? _lastContext;
  DateTime? _nextReview;

  void start() {
    agents.config.addIdentityListener(_revoke);
    _subscriptions.add(database.watchActiveTasks().listen((_) => _schedule()));
    _subscriptions.add(
      database.watchActiveCalendarEvents().listen((_) => _schedule()),
    );
    _subscriptions.add(
      database.watchActiveProjects().listen((_) => _schedule()),
    );
  }

  Future<void> _revoke() async {
    _generation++;
    _lastContext = null;
    _debounce?.cancel();
    _review?.cancel();
    _finishPoll();
  }

  void _schedule() {
    if (_disposed) return;
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 15), () => unawaited(refresh()));
  }

  Future<Map<String, Object?>> _context() async {
    final tasks = await (database.select(
      database.tasks,
    )..where((t) => t.deletedAt.isNull())).get();
    final schedules = await (database.select(
      database.calendarEvents,
    )..where((s) => s.deletedAt.isNull())).get();
    final projects = await (database.select(
      database.projects,
    )..where((p) => p.deletedAt.isNull())).get();
    tasks.sort((a, b) => a.id.compareTo(b.id));
    schedules.sort((a, b) => a.id.compareTo(b.id));
    projects.sort((a, b) => a.id.compareTo(b.id));
    return {
      'tasks': [
        for (final t in tasks)
          {
            'id': t.id,
            'title': t.title,
            'notes': t.notes,
            'due': t.due,
            'dueTime': t.dueTime,
            'important': t.important,
            'urgent': t.urgent,
            'completed': t.completed,
            'projectId': t.projectId,
            'parentTaskId': t.parentTaskId,
            'scheduleId': t.scheduleId,
            'recurrence': t.recurrence,
          },
      ],
      'schedules': [
        for (final s in schedules)
          {
            'id': s.id,
            'title': s.title,
            'description': s.description,
            'startAt': s.startAt,
            'endAt': s.endAt,
            'allDay': s.allDay,
          },
      ],
      'projects': [
        for (final p in projects)
          {
            'id': p.id,
            'name': p.name,
            'goal': p.goal,
            'description': p.description,
            'status': p.status,
            'due': p.due,
          },
      ],
    };
  }

  String _fingerprint(Map<String, Object?> context) =>
      sha256.convert(utf8.encode(jsonEncode(context))).toString();

  void _finishPoll() {
    _poll?.cancel();
    if (_pollDone case final done?) {
      _pollDone = null;
      if (!done.isCompleted) done.complete();
    }
  }

  Future<void> refresh({bool timeChanged = false}) async {
    if (_disposed) return;
    if (_running) {
      _dirty = true;
      return;
    }
    _running = true;
    _dirty = false;
    final generation = _generation;
    final previousReview = _nextReview;
    var nextReview =
        previousReview != null && previousReview.isAfter(DateTime.now())
        ? previousReview
        : DateTime.now().add(const Duration(hours: 1));
    try {
      final scope = await agents.identity();
      Future<bool> current() async =>
          !_disposed &&
          generation == _generation &&
          await ownsDatabase() &&
          await agents.identity() == scope;
      if (!await current()) return;
      final context = await _context();
      final fingerprint = _fingerprint(context);
      if (!timeChanged && fingerprint == _lastContext) return;
      final tasks = (context['tasks'] as List).cast<Map<String, Object?>>();
      final ids = tasks
          .where((t) => t['completed'] == false)
          .map((t) => t['id'] as String)
          .toSet();
      if (ids.isEmpty) return;
      final now = DateTime.now();
      // Clients evaluating the same context in the same minute share one run.
      final minute = DateTime(
        now.year,
        now.month,
        now.day,
        now.hour,
        now.minute,
      );
      final content = jsonEncode({
        'kind': 'orialis.urgency.v1',
        'context': {
          'now': minute.toIso8601String(),
          'utcOffsetMinutes': now.timeZoneOffset.inMinutes,
          ...context,
        },
      });
      if (utf8.encode(content).length > 100000) {
        throw const FormatException('Urgency context exceeds background limit');
      }
      final id = 'urgency-v1-${sha256.convert(utf8.encode(content))}';
      final api = await agents.client();
      if (!await current()) return;
      var result = await api.createMemoryAnalysis(id: id, content: content);
      final deadline = DateTime.now().add(const Duration(minutes: 5));
      while (result['status'] == 'analyzing' &&
          await current() &&
          DateTime.now().isBefore(deadline)) {
        final done = Completer<void>();
        _pollDone = done;
        _poll = Timer(const Duration(seconds: 2), _finishPoll);
        await done.future;
        if (!await current()) return;
        result = await api.memoryAnalysis(id) ?? {};
      }
      if (!await current() ||
          result['id'] != id ||
          result['status'] != 'completed') {
        return;
      }
      final assessment = UrgencyAssessment.parse(
        result['content'] as String,
        ids,
      );
      await database.transaction(() async {
        // An edit anywhere in the supplied context invalidates the whole result.
        if (!await current() || _fingerprint(await _context()) != fingerprint) {
          return;
        }
        for (final decision in assessment.decisions) {
          final task = tasks.singleWhere((t) => t['id'] == decision.id);
          if (task['urgent'] != decision.urgent) {
            await repository.setTaskQuadrant(
              decision.id,
              important: task['important'] as bool?,
              urgent: decision.urgent,
            );
          }
        }
        _lastContext = _fingerprint(await _context());
      });
      // This limits request frequency; urgency itself is decided only by AI.
      final earliest = DateTime.now().add(const Duration(minutes: 5));
      nextReview = assessment.reviewAt.isBefore(earliest)
          ? earliest
          : assessment.reviewAt;
    } catch (error) {
      // Never print task contents, credentials or provider exception messages.
      debugPrint('Urgency assessment deferred: ${error.runtimeType}');
    } finally {
      _running = false;
      if (!_disposed && generation == _generation) {
        _nextReview = nextReview;
        _review?.cancel();
        _review = Timer(
          nextReview.difference(DateTime.now()),
          () => unawaited(refresh(timeChanged: true)),
        );
        if (_dirty) _schedule();
      }
    }
  }

  void dispose() {
    _disposed = true;
    agents.config.removeIdentityListener(_revoke);
    _debounce?.cancel();
    _review?.cancel();
    _finishPoll();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
  }
}
