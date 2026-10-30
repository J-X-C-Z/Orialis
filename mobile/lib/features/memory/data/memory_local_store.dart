import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Local cloud-memory cache for desktop platforms without a capture bridge.
class MemoryLocalStore {
  MemoryLocalStore({this.rootDirectory});

  final Directory? rootDirectory;
  String? _scope;
  Future<void> _tail = Future<void>.value();
  static const _mutable = {
    'title',
    'summary',
    'notes',
    'note',
    'category',
    'sourceUrl',
    'videoStatus',
    'videoSummary',
    'videoError',
    'analysisStatus',
    'analysisError',
    'analysisRequestId',
    'analysisConversationId',
    'analysisMessageId',
    'cloudVersion',
    'cloudRecordHash',
    'cloudImageSha256',
    'cloudDeletedAt',
    'cloudSyncError',
  };
  static const _recordFields = {
    'id',
    'createdAt',
    'sourcePackage',
    'sourceLabel',
    'visibleText',
    'sharedText',
    'urls',
    ..._mutable,
  };

  Future<Object?> handle(String method, Map<String, Object?>? args) {
    final next = _tail.then((_) => _handle(method, args ?? {}));
    _tail = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return next;
  }

  Future<Directory> _directory() async {
    final scope = _scope;
    if (scope == null) throw StateError('请先登录账号');
    final root = rootDirectory ?? await getApplicationSupportDirectory();
    final result = Directory('${root.path}/screen_memory_v1/$scope');
    await result.create(recursive: true);
    return result;
  }

  String _id(Object? value) {
    if (value is! String ||
        !RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(value)) {
      throw const FormatException('记忆标识无效');
    }
    return value;
  }

  Future<File> _recordFile(String id) async =>
      File('${(await _directory()).path}/$id.json');

  Future<Map<String, Object?>?> _read(String id) async {
    final file = await _recordFile(id);
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map || decoded['id'] != id) {
      throw const FormatException('记忆记录损坏');
    }
    return Map<String, Object?>.from(decoded);
  }

  Future<void> _write(String id, Map<String, Object?> record) async {
    final file = await _recordFile(id);
    final next = File('${file.path}.next');
    await next.writeAsString(jsonEncode(record), flush: true);
    // A same-directory rename atomically replaces the cache on desktop filesystems.
    await next.rename(file.path);
  }

  bool _same(Object? left, Object? right) {
    if ((left == null || left == '') && (right == null || right == '')) {
      return true;
    }
    if (left is Map && right is Map) {
      return left.length == right.length &&
          left.keys.every(
            (key) => right.containsKey(key) && _same(left[key], right[key]),
          );
    }
    if (left is List && right is List) {
      return left.length == right.length &&
          List.generate(
            left.length,
            (i) => i,
          ).every((i) => _same(left[i], right[i]));
    }
    return left == right;
  }

  void _checkExpected(Map<String, Object?>? current, Object? expected) {
    if (expected == null) {
      if (current != null) throw StateError('记忆已在本机变更，请重新同步');
      return;
    }
    if (expected is! Map || current == null) {
      throw StateError('记忆已在本机变更，请重新同步');
    }
    for (final key in expected.keys) {
      if (key == 'createdAt') {
        if (DateTime.tryParse('${expected[key]}')?.toUtc() !=
            DateTime.tryParse('${current[key]}')?.toUtc()) {
          throw StateError('记忆已在本机变更，请重新同步');
        }
      } else if (!_same(current[key], expected[key])) {
        throw StateError('记忆已在本机变更，请重新同步');
      }
    }
  }

  Future<Object?> _handle(String method, Map<String, Object?> args) async {
    if (args.containsKey('expectedScope') && args['expectedScope'] != _scope) {
      throw StateError('账号已变更，请重试同步');
    }
    if (method == 'status') {
      return {'supported': true, 'captureSupported': false};
    }
    if (method == 'setScope') {
      final value = args['scope'];
      if (value != null &&
          (value is! String || !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(value))) {
        throw const FormatException('账号范围无效');
      }
      _scope = value as String?;
      return null;
    }
    if (method == 'takePendingRoute') return null;
    if (method == 'requestAddTile') return false;
    if (method == 'list') {
      if (_scope == null) return <Map<String, Object?>>[];
      final directory = await _directory();
      final records = <Map<String, Object?>>[];
      await for (final item in directory.list()) {
        if (item is File && item.path.endsWith('.json')) {
          final name = item.uri.pathSegments.last;
          final record = await _read(_id(name.substring(0, name.length - 5)));
          if (record != null) records.add(record);
        }
      }
      records.sort(
        (a, b) => '${b['createdAt']}'.compareTo('${a['createdAt']}'),
      );
      return records;
    }
    final id = _id(args['id'] ?? (args['record'] as Map?)?['id']);
    final current = await _read(id);
    if (method == 'read') return current;
    if (method == 'update') {
      if (current == null) throw StateError('记忆不存在');
      final expected = args['expectedAnalysisRequestId'];
      if (expected != null &&
          (current['analysisRequestId'] ?? '') != expected) {
        throw StateError('已有更新的记忆理解任务');
      }
      final fields = Map<String, Object?>.from(args['fields'] as Map);
      if (fields.keys.any((key) => !_mutable.contains(key))) {
        throw const FormatException('记忆字段不允许修改');
      }
      current.addAll(fields);
      if (fields.keys.any((key) => !key.startsWith('cloud'))) {
        current['cloudSyncError'] = 'pending';
      }
      await _write(id, current);
      return current;
    }
    if (method == 'importCloud') {
      if (!args.containsKey('expectedRecord')) {
        throw const FormatException('缺少本机版本校验');
      }
      _checkExpected(current, args['expectedRecord']);
      final record = Map<String, Object?>.from(args['record'] as Map);
      if (record.containsKey('imagePath') ||
          record.keys.any((key) => !_recordFields.contains(key))) {
        throw const FormatException('云端记忆包含不允许的字段');
      }
      if (record['id'] != id ||
          DateTime.tryParse('${record['createdAt']}') == null) {
        throw const FormatException('云端记忆格式无效');
      }
      final merged = <String, Object?>{...?current, ...record};
      await _write(id, merged);
      return merged;
    }
    if (method == 'storeCloudImage') {
      if (current == null) throw StateError('记忆不存在');
      final raw = args['bytes'];
      final bytes = raw is Uint8List
          ? raw
          : raw is String
          ? base64Decode(raw)
          : null;
      final sha = args['sha256'];
      if (bytes == null ||
          bytes.isEmpty ||
          bytes.length > 32 * 1024 * 1024 ||
          sha is! String ||
          sha256.convert(bytes).toString() != sha) {
        throw const FormatException('云端原图校验失败');
      }
      if (current['cloudImageSha256'] != null &&
          current['cloudImageSha256'] != sha) {
        throw StateError('云端原图版本已变更，请重新同步');
      }
      final mime = args['mimeType'];
      final extension = {
        'image/png': 'png',
        'image/jpeg': 'jpg',
        'image/webp': 'webp',
      }[mime];
      if (extension == null) throw const FormatException('图片格式不支持');
      final oldPath = current['imagePath'];
      if (oldPath is String && await File(oldPath).exists()) {
        // The capture device keeps its original; the cloud holds a compressed copy.
        return oldPath;
      }
      final file = File('${(await _directory()).path}/$id.$extension');
      final next = File('${file.path}.next');
      await next.writeAsBytes(bytes, flush: true);
      await next.rename(file.path);
      current['imagePath'] = file.path;
      await _write(id, current);
      return file.path;
    }
    if (method == 'delete') {
      if (current == null) return false;
      // A tombstone hides the record while retaining its local original for recovery.
      current['cloudDeletedAt'] = 'pending';
      await _write(id, current);
      return true;
    }
    if (method == 'prepareUpload') {
      final path = current?['imagePath'];
      if (path is String && await File(path).exists()) return path;
      throw StateError('记忆原图不存在');
    }
    throw UnsupportedError('此设备不支持屏幕采集');
  }
}
