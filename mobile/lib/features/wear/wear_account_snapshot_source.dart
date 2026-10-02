import '../../core/config/app_config.dart';
import '../../core/network/orialis_api_client.dart';

/// A read-only server snapshot: never reconciles into the shared mobile DB.
class WearAccountSnapshot {
  const WearAccountSnapshot(this.collections, this.username, this.serverUrl);
  final Map<String, List<Map<String, Object?>>> collections;
  final String username, serverUrl;
}

class WearAccountSnapshotSource {
  WearAccountSnapshotSource(this.config);
  final AppConfig config;

  Future<WearAccountSnapshot?> read() async {
    var revoked = false;
    Future<void> revoke() async => revoked = true;
    config.addIdentityListener(revoke);
    try {
      final server = await config.serverUrl();
      final token = await config.sessionToken();
      if (token == null || token.isEmpty || revoked) return null;
      // The normal client reads config for every request. Freeze this token so
      // an account switch cannot combine identity A with snapshot B.
      final api = OrialisApiClient(
        baseUrl: server,
        deviceId: await config.deviceId(),
        config: _SnapshotCredentials(token),
      );
      final session = await api.session();
      if (session['userId'] is! String ||
          (session['userId'] as String).isEmpty ||
          session['username'] is! String ||
          revoked) {
        return null;
      }
      // Server sync_snapshot filters every collection by authenticated user_id
      // in one database transaction. It is the same endpoint used by SyncEngine.
      final snapshot = await api.syncSnapshot();
      final collections = <String, List<Map<String, Object?>>>{};
      for (final entry in const {
        'tasks': 'tasks',
        'schedules': 'calendarEvents',
        'projects': 'projects',
        'milestones': 'milestones',
      }.entries) {
        final raw = snapshot[entry.value];
        if (raw is! List) return null;
        final rows = <Map<String, Object?>>[];
        final ids = <String>{};
        for (final value in raw) {
          if (value is! Map ||
              value['id'] is! String ||
              (value['id'] as String).isEmpty ||
              !ids.add(value['id'] as String)) {
            return null;
          }
          if (value['deletedAt'] != null) continue;
          rows.add({
            for (final field in _fields[entry.key]!) field: value[field],
          });
        }
        collections[entry.key] = rows;
      }
      final currentServer = await config.serverUrl();
      final currentToken = await config.sessionToken();
      if (revoked || currentServer != server || currentToken != token) {
        return null;
      }
      return WearAccountSnapshot(
        collections,
        session['username'] as String,
        server,
      );
    } on Exception {
      // Network/auth/schema failures cannot authorize shared local data.
      return null;
    } finally {
      config.removeIdentityListener(revoke);
    }
  }

  static const _fields = {
    'tasks': [
      'id',
      'title',
      'notes',
      'due',
      'dueTime',
      'important',
      'urgent',
      'completed',
      'reminderMinutes',
      'recurrence',
      'projectId',
      'parentTaskId',
      'scheduleId',
      'manualPosition',
    ],
    'schedules': [
      'id',
      'title',
      'description',
      'location',
      'startAt',
      'endAt',
      'allDay',
      'important',
      'reminderMinutes',
    ],
    'projects': [
      'id',
      'name',
      'goal',
      'description',
      'status',
      'due',
      'nextActionTaskId',
      'manualPosition',
    ],
    'milestones': ['id', 'projectId', 'title', 'due', 'completed', 'position'],
  };
}

class _SnapshotCredentials extends AppConfig {
  _SnapshotCredentials(this._token);
  final String _token;
  @override
  Future<String?> sessionToken() async => _token;
}
