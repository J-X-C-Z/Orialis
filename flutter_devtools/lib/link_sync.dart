import 'server_client.dart';
import 'wristband_contract.dart';

/// Native-independent orchestration for the phone -> server -> wristband path.
///
/// The server snapshot is fetched by Flutter over HTTPS. The final handoff is
/// a MethodChannel call, so removing the WebView does not remove data sync.
class LinkSyncCoordinator {
  LinkSyncCoordinator({required this.server, required this.wristband});

  final FangcunServerClient server;
  final WristbandClient wristband;

  Future<LinkSyncResult> syncLatestToWristband({int? lastRevision}) async {
    final snapshot = await server.getLinkSnapshot();
    if (lastRevision != null && snapshot.revision == lastRevision) {
      return LinkSyncResult(snapshot: snapshot, skipped: true);
    }
    // XiaomiWristbandAdapter frames this JSON and the Vela app validates the
    // snapshot at the top level. Do not wrap the envelope a second time.
    final result = await wristband.sync(snapshot.raw);
    return LinkSyncResult(snapshot: snapshot, wristband: result);
  }

  /// Pull actions that were made on the band, commit them to the revisioned
  /// server document, then push the resulting document back to the band.
  Future<BidirectionalSyncResult> syncBidirectional({int? lastRevision}) async {
    final events = await wristband.pollEvents();
    var applied = 0;
    if (events.isNotEmpty) {
      final remote = await server.getData();
      final document = _copyDocument(remote.data);
      final tasks = document['tasks'];
      if (tasks is List) {
        for (final event in events) {
          final action = event['action'];
          final taskId = event['taskId']?.toString();
          if (taskId == null || taskId.isEmpty) continue;
          final task = tasks.whereType<Map>().cast<Map>().firstWhere(
                (item) => item['id']?.toString() == taskId,
                orElse: () => <String, dynamic>{},
              );
          if (task.isEmpty) continue;
          if (action == 'confirm' || action == 'setCompleted') {
            final completed = action == 'confirm' ? true : event['completed'] == true;
            if (task['completed'] == completed) continue;
            task['completed'] = completed;
            task['updatedAt'] = DateTime.now().toUtc().toIso8601String();
            applied++;
          }
        }
      }
      if (applied > 0) await server.putData(document, remote.revision);
      await wristband.acknowledgeEvents(events.length);
    }
    final pushed = await syncLatestToWristband(lastRevision: lastRevision);
    return BidirectionalSyncResult(result: pushed, appliedEvents: applied);
  }

  static Map<String, dynamic> _copyDocument(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value.map((key, value) => MapEntry(key.toString(), value)));
    return <String, dynamic>{};
  }
}

class LinkSyncResult {
  const LinkSyncResult({required this.snapshot, this.wristband, this.skipped = false});

  final LinkSnapshot snapshot;
  final WristbandResult? wristband;
  final bool skipped;
}

class BidirectionalSyncResult {
  const BidirectionalSyncResult({required this.result, required this.appliedEvents});

  final LinkSyncResult result;
  final int appliedEvents;
}
