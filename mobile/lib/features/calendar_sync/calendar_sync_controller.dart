import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import '../events/data/event_repository.dart';

// A three-way comparison avoids treating our own writes as new edits.
enum CalendarMerge {
  unchanged,
  push,
  pull,
  deleteLocal,
  deleteNative,
  conflict,
}

CalendarMerge calendarMerge(String? before, String? local, String? native) {
  if (local == native) return CalendarMerge.unchanged;
  if (local == before) {
    return native == null ? CalendarMerge.deleteLocal : CalendarMerge.pull;
  }
  if (native == before) {
    return local == null ? CalendarMerge.deleteNative : CalendarMerge.push;
  }
  return CalendarMerge.conflict;
}

class CalendarSyncController extends ChangeNotifier
    with WidgetsBindingObserver {
  CalendarSyncController({
    required this.database,
    required this.repository,
    required this.scope,
    this.channel = const MethodChannel('top.jxcz.orialis/calendar_sync'),
  });
  final AppDatabase database;
  final EventRepository repository;
  final String scope;
  final MethodChannel channel;
  SharedPreferences? _prefs;
  StreamSubscription<List<CalendarEvent>>? _subscription;
  Timer? _timer;
  bool _disposed = false, busy = false, _again = false;
  String? calendarId, error;
  String? lastSync;
  Map<String, dynamic> _links = {};
  Map<String, dynamic> _calendars = {};
  bool _enabled = false;
  bool get supported => Platform.isAndroid;
  bool get enabled => _enabled && calendarId != null;
  String get _key => 'native-calendar-v1:$scope';

  Future<void> start() async {
    if (!supported) return;
    _prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    final stored =
        jsonDecode(_prefs!.getString(_key) ?? '{}') as Map<String, dynamic>;
    calendarId = stored['calendarId'] as String?;
    _enabled = stored['enabled'] == true;
    _calendars = Map<String, dynamic>.from(stored['calendars'] as Map? ?? {});
    _links = Map<String, dynamic>.from(stored['links'] as Map? ?? {});
    lastSync = stored['lastSync'] as String?;
    WidgetsBinding.instance.addObserver(this);
    _subscription = repository.watchCalendarEvents().listen((_) => _schedule());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _schedule());
    notifyListeners();
    _schedule();
  }

  void _schedule() {
    if (enabled && !_disposed) unawaited(sync());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _schedule();
  }

  Future<List<Map<String, dynamic>>> calendars() async {
    if (await channel.invokeMethod<bool>('requestPermission') != true) {
      throw StateError('请允许读取和写入日历');
    }
    return (await channel.invokeListMethod<dynamic>('calendars') ?? [])
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
  }

  Future<void> connect(String id) async {
    if (busy) throw StateError('请等待当前同步完成');
    if (_prefs == null) await start();
    // Switching calendars starts a fresh merge; existing calendars are kept.
    if (calendarId != id) {
      if (calendarId != null) {
        _calendars[calendarId!] = Map<String, dynamic>.from(_links);
      }
      _links = Map<String, dynamic>.from(_calendars[id] as Map? ?? {});
    }
    calendarId = id;
    _enabled = true;
    await _save();
    notifyListeners();
    await sync();
  }

  Future<void> disconnect() async {
    _enabled = false;
    await _save();
    if (!_disposed) notifyListeners();
  }

  Future<void> _save() async {
    if (_disposed) return;
    final ok = await _prefs!.setString(
      _key,
      jsonEncode({
        'calendarId': calendarId,
        'enabled': _enabled,
        'calendars': _calendars,
        'links': _links,
        'lastSync': lastSync,
      }),
    );
    if (!ok) throw StateError('无法保存同步进度');
  }

  Map<String, dynamic> _payload(CalendarEvent e) {
    int stamp(String value) {
      final d = DateTime.parse(value).toLocal();
      return (e.allDay ? DateTime.utc(d.year, d.month, d.day) : d)
          .millisecondsSinceEpoch;
    }

    return {
      'title': e.title,
      'description': e.description ?? '',
      'location': e.location ?? '',
      'startAt': stamp(e.startAt),
      'endAt': stamp(e.endAt),
      'allDay': e.allDay,
      'reminderMinutes': e.reminderMinutes,
    };
  }

  Map<String, dynamic> _nativePayload(Map<String, dynamic> e) => {
    'title': e['title'] ?? '',
    'description': e['description'] ?? '',
    'location': e['location'] ?? '',
    'startAt': e['startAt'],
    'endAt': e['endAt'],
    'allDay': e['allDay'] == true,
    'reminderMinutes': e['reminderMinutes'],
  };
  DateTime _date(Map<String, dynamic> p, String key) {
    final date = DateTime.fromMillisecondsSinceEpoch(
      (p[key] as num).toInt(),
      isUtc: true,
    );
    return p['allDay'] == true
        ? DateTime(date.year, date.month, date.day)
        : date;
  }

  Future<void> _pull(
    Map<String, dynamic> p,
    String id,
    CalendarEvent? existing,
  ) async {
    final title = (p['title'] as String).trim().isEmpty
        ? '未命名日程'
        : p['title'] as String;
    if (existing == null) {
      await repository.createCalendarEvent(
        eventId: id,
        title: title,
        startAt: _date(p, 'startAt'),
        endAt: _date(p, 'endAt'),
        description: p['description'] as String?,
        location: p['location'] as String?,
        allDay: p['allDay'] == true,
        reminderMinutes: p['reminderMinutes'] as int?,
      );
    } else {
      await repository.updateSchedule(
        existing,
        title: title,
        startAt: _date(p, 'startAt'),
        endAt: _date(p, 'endAt'),
        description: p['description'] as String?,
        location: p['location'] as String?,
        allDay: p['allDay'] == true,
        reminderMinutes: p['reminderMinutes'] as int?,
        reminderMinutesProvided: true,
      );
    }
  }

  Future<void> sync() async {
    if (!enabled || _disposed) return;
    if (busy) {
      _again = true;
      return;
    }
    busy = true;
    error = null;
    notifyListeners();
    final selected = calendarId;
    bool active() => !_disposed && enabled && calendarId == selected;
    try {
      final nativeRows = await channel.invokeListMethod<dynamic>('events', {
        'calendarId': selected,
      });
      if (nativeRows == null) throw StateError('系统日历未能完整读取');
      if (!active()) return;
      final native = {
        for (final row in nativeRows)
          (row as Map)['id'] as String: Map<String, dynamic>.from(row),
      };
      final local = {
        for (final e in await repository.watchCalendarEvents().first) e.id: e,
      };
      // Recover successful exports whose progress write was interrupted.
      for (final n in native.values) {
        final key = n['key'];
        if (key is String &&
            local.containsKey(key) &&
            !_links.containsKey(key)) {
          _links[key] = {
            'nativeId': n['id'],
            'baseline': jsonEncode(_nativePayload(n)),
          };
        }
      }
      final consumed = _links.values.map((v) => (v as Map)['nativeId']).toSet();
      for (final id in {..._links.keys, ...local.keys}) {
        if (!active()) return;
        final link = _links[id] as Map?;
        final nativeId = link?['nativeId'] as String?;
        final n = native[nativeId];
        if (n?['recurring'] == true) continue;
        final l = local[id];
        final lp = l == null ? null : _payload(l);
        final np = n == null ? null : _nativePayload(n);
        final action = calendarMerge(
          link?['baseline'] as String?,
          lp == null ? null : jsonEncode(lp),
          np == null ? null : jsonEncode(np),
        );
        if (action == CalendarMerge.conflict && np != null) {
          // Preserve the native edit as a separate event before publishing the local edit.
          final copyId = const Uuid().v5(
            Namespace.url.value,
            '$scope/$selected/$nativeId/${jsonEncode(np)}',
          );
          if (!local.containsKey(copyId)) {
            await _pull(
              {...np, 'title': '${np['title']}（同步冲突副本）'},
              copyId,
              null,
            );
          }
        }
        if (!active()) return;
        if (action == CalendarMerge.deleteLocal && l != null) {
          await repository.deleteCalendarEvent(l);
          _links.remove(id);
        } else if (action == CalendarMerge.deleteNative && nativeId != null) {
          await channel.invokeMethod<void>('delete', {
            'calendarId': selected,
            'id': nativeId,
          });
          _links.remove(id);
        } else if (action == CalendarMerge.pull && np != null) {
          await _pull(np, id, l);
          _links[id] = {'nativeId': nativeId, 'baseline': jsonEncode(np)};
        } else if ((action == CalendarMerge.push ||
                action == CalendarMerge.conflict) &&
            lp != null) {
          final written = await channel.invokeMethod<String>('put', {
            'calendarId': selected,
            if (n != null) 'id': nativeId,
            'key': id,
            ...lp,
          });
          if (written == null) throw StateError('系统日历写入未确认');
          _links[id] = {'nativeId': written, 'baseline': jsonEncode(lp)};
        } else if (action == CalendarMerge.conflict &&
            l == null &&
            nativeId != null) {
          await channel.invokeMethod<void>('delete', {
            'calendarId': selected,
            'id': nativeId,
          });
          _links.remove(id);
        } else if (l == null && n == null) {
          _links.remove(id);
        }
        await _save();
      }
      final known = _links.values.map((v) => (v as Map)['nativeId']).toSet();
      for (final n in native.values) {
        if (!active()) return;
        if (known.contains(n['id']) ||
            consumed.contains(n['id']) ||
            n['recurring'] == true) {
          continue;
        }
        final id = const Uuid().v5(
          Namespace.url.value,
          '$scope/$selected/${n['id']}',
        );
        final existing = await (database.select(
          database.calendarEvents,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        if (existing?.deletedAt != null) continue;
        final p = _nativePayload(n);
        await _pull(p, id, existing);
        _links[id] = {'nativeId': n['id'], 'baseline': jsonEncode(p)};
        await _save();
      }
      lastSync = DateTime.now().toIso8601String();
      await _save();
    } catch (_) {
      if (!_disposed) error = '同步未完成，请检查日历权限与所选日历后重试';
    } finally {
      busy = false;
      if (!_disposed) {
        notifyListeners();
        if (_again) {
          _again = false;
          _schedule();
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
