import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import '../domain/memory_record.dart';
import 'memory_local_store.dart';

const defaultMemoryShortcuts = <String, Map<String, Object>>{
  'screen': {
    'key': 'M',
    'command': true,
    'option': true,
    'shift': false,
    'control': false,
  },
  'selection': {
    'key': 'N',
    'command': true,
    'option': true,
    'shift': false,
    'control': false,
  },
};

String memoryShortcutLabel(Map shortcut) =>
    '${shortcut['control'] == true ? '⌃' : ''}'
    '${shortcut['option'] == true ? '⌥' : ''}'
    '${shortcut['shift'] == true ? '⇧' : ''}'
    '${shortcut['command'] == true ? '⌘' : ''}${shortcut['key'] ?? ''}';

class MemoryStatus {
  const MemoryStatus({
    required this.supported,
    this.silentCaptureSupported = false,
    this.silentCaptureEnabled = false,
    this.captureSupported = true,
  });
  final bool supported;
  final bool captureSupported;
  final bool silentCaptureSupported;
  final bool silentCaptureEnabled;
}

class MemoryRepository extends ChangeNotifier {
  MemoryRepository({MethodChannel? channel})
    : channel = channel ?? const MethodChannel('top.jxcz.orialis/memory');

  final MethodChannel channel;
  final _fallback = MemoryLocalStore();
  String? _scope;
  String? get accountScope => _scope;
  Future<void> Function()? onSync;
  Future<void> sync() async => onSync?.call();

  Future<dynamic> _call(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.iOS ||
              defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.linux)) {
        return _fallback.handle(method, arguments);
      }
      rethrow;
    }
  }

  void refresh() => notifyListeners();

  Future<MemoryStatus> status() async {
    try {
      final result = await _call('status');
      return MemoryStatus(
        supported: result?['supported'] == true,
        captureSupported: result?['captureSupported'] != false,
        silentCaptureSupported: result?['silentCaptureSupported'] == true,
        silentCaptureEnabled: result?['silentCaptureEnabled'] == true,
      );
    } on MissingPluginException {
      return const MemoryStatus(supported: false);
    }
  }

  Future<void> setScope(String? scope) async {
    await _call('setScope', {'scope': scope});
    _scope = scope;
  }

  Future<String?> takePendingRoute() async =>
      await _call('takePendingRoute') as String?;

  Future<bool> requestAddTile() async => await _call('requestAddTile') == true;
  Future<void> capture() async => _call('capture');
  Future<void> openCaptureSettings() async => _call('openCaptureSettings');
  Future<Map<String, dynamic>> getShortcuts() async =>
      Map<String, dynamic>.from(await _call('getShortcuts') ?? {});
  Future<void> setShortcuts(Map<String, dynamic> shortcuts) async =>
      _call('setShortcuts', shortcuts);
  Future<void> setShortcutRecording(bool recording) async =>
      _call(recording ? 'suspendShortcuts' : 'resumeShortcuts');

  Future<String> prepareUpload(String id) async {
    final path = await _call('prepareUpload', {'id': id});
    if (path is! String || path.isEmpty) {
      throw const FormatException('截图上传副本未能生成');
    }
    return path;
  }

  Future<List<MemoryRecord>> listAll() async {
    final result = await _call('list');
    if (result is! List) throw const FormatException('记忆列表未能读取');
    return result.map((entry) {
      if (entry is! Map) throw const FormatException('记忆记录格式不正确');
      return MemoryRecord.fromMap(entry);
    }).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<List<MemoryRecord>> list() async => (await listAll())
      .where((record) => record.cloudDeletedAt == null)
      .toList();
  Future<MemoryRecord> read(String id) async =>
      _record(await _call('read', {'id': id}));

  Future<MemoryRecord> update(
    String id,
    Map<String, Object?> fields, {
    String? expectedAnalysisRequestId,
  }) async {
    final result = _record(
      await _call('update', {
        'id': id,
        'fields': fields,
        'expectedAnalysisRequestId': ?expectedAnalysisRequestId,
      }),
    );
    notifyListeners();
    return result;
  }

  Future<MemoryRecord> importCloud(
    Map<String, Object?> record,
    MemoryRecord? expected, {
    String? expectedScope,
  }) async => _record(
    await _call('importCloud', {
      'record': record,
      'expectedRecord': expected?.toMap(),
      'expectedScope': expectedScope,
    }),
  );

  Future<void> storeCloudImage(
    String id,
    Uint8List bytes,
    String mimeType,
    String sha256, {
    String? expectedScope,
  }) async {
    await _call('storeCloudImage', {
      'id': id,
      'bytes': bytes,
      'mimeType': mimeType,
      'sha256': sha256,
      'expectedScope': expectedScope,
    });
  }

  Future<void> delete(String id) async {
    // Keep original evidence locally; the synchronizer sends an account-scoped tombstone.
    await update(id, {'cloudDeletedAt': 'pending', 'cloudSyncError': null});
  }

  MemoryRecord _record(dynamic value) {
    if (value is! Map) throw const FormatException('这条记忆已不存在');
    return MemoryRecord.fromMap(value);
  }
}
