import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import '../domain/memory_record.dart';

class MemoryStatus {
  const MemoryStatus({required this.supported});
  final bool supported;
}

class MemoryRepository extends ChangeNotifier {
  MemoryRepository({MethodChannel? channel})
    : channel = channel ?? const MethodChannel('top.jxcz.orialis/memory');

  final MethodChannel channel;

  void refresh() => notifyListeners();

  Future<MemoryStatus> status() async {
    try {
      final result = await channel.invokeMapMethod<Object?, Object?>('status');
      return MemoryStatus(supported: result?['supported'] == true);
    } on MissingPluginException {
      return const MemoryStatus(supported: false);
    }
  }

  Future<void> setScope(String? scope) =>
      channel.invokeMethod<void>('setScope', {'scope': scope});
  Future<bool> requestAddTile() async =>
      await channel.invokeMethod<bool>('requestAddTile') ?? false;
  Future<void> capture() => channel.invokeMethod<void>('capture');

  Future<String> prepareUpload(String id) async {
    final path = await channel.invokeMethod<String>('prepareUpload', {
      'id': id,
    });
    if (path == null || path.isEmpty) {
      throw const FormatException('截图上传副本未能生成');
    }
    return path;
  }

  Future<List<MemoryRecord>> list() async {
    final result = await channel.invokeListMethod<Object?>('list');
    if (result == null) throw const FormatException('记忆列表未能读取');
    return result.map((entry) {
      if (entry is! Map) throw const FormatException('记忆记录格式不正确');
      return MemoryRecord.fromMap(entry);
    }).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<MemoryRecord> read(String id) async => _record(
    await channel.invokeMapMethod<Object?, Object?>('read', {'id': id}),
  );

  Future<MemoryRecord> update(String id, Map<String, Object?> fields) async {
    final result = _record(
      await channel.invokeMapMethod<Object?, Object?>('update', {
        'id': id,
        'fields': fields,
      }),
    );
    notifyListeners();
    return result;
  }

  Future<void> delete(String id) async {
    await channel.invokeMethod<void>('delete', {'id': id});
    notifyListeners();
  }

  MemoryRecord _record(Map<Object?, Object?>? value) {
    if (value == null) throw const FormatException('这条记忆已不存在');
    return MemoryRecord.fromMap(value);
  }
}
