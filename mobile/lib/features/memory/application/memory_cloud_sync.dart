import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:mime/mime.dart';

import '../../../core/network/orialis_api_client.dart';
import '../../chat/data/agent_chat_service.dart';
import '../data/memory_repository.dart';
import '../domain/memory_record.dart';

/// Originals remain local; cloud images are the existing compressed upload copies.
class MemoryCloudSync {
  MemoryCloudSync({required this.repository, required this.agents}) {
    repository.onSync = sync;
  }

  final MemoryRepository repository;
  final AgentChatService agents;
  Future<void>? _running;
  Timer? _debounce, _retry;
  bool _disposed = false, _notifying = false, _rescan = false;
  bool hasPending = false;
  bool Function()? _isCurrent;
  String? _activeScope;
  final _preparedImages = <String, Uint8List>{};

  void start(bool Function() isCurrent) {
    _isCurrent = isCurrent;
    repository.addListener(_changed);
    _retry ??= Timer.periodic(const Duration(seconds: 30), (_) => _changed());
  }

  void _changed() {
    if (_disposed || _notifying || _isCurrent?.call() == false) return;
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(sync()),
    );
  }

  Future<void> sync() {
    if (_disposed || _isCurrent?.call() == false) return Future.value();
    if (_running != null) {
      _rescan = true;
      return _running!;
    }
    return _running = _drain();
  }

  Future<void> _drain() async {
    try {
      do {
        _rescan = false;
        await _sync();
      } while (_rescan && !_disposed && _isCurrent?.call() != false);
    } finally {
      _preparedImages.clear();
      _running = null;
    }
  }

  Future<void> _sync() async {
    hasPending = false;
    _preparedImages.clear();
    try {
      final identity = await agents.identity();
      _activeScope = repository.accountScope;
      Future<void> check() async {
        if (_disposed ||
            repository.accountScope != _activeScope ||
            _isCurrent?.call() == false ||
            await agents.identity() != identity) {
          throw const _ScopeChanged();
        }
      }

      final api = await agents.client();
      await check();
      final remote = <String, Map<String, dynamic>>{};
      var offset = 0;
      while (true) {
        final page = await api.memoryRecords(offset: offset);
        await check();
        final items = (page['items'] as List? ?? []).whereType<Map>();
        for (final item in items) {
          final value = Map<String, dynamic>.from(item);
          remote[value['id'] as String] = value;
        }
        if (page['hasMore'] != true) break;
        if (items.isEmpty) throw const FormatException('云端记忆分页无效');
        offset += items.length;
      }
      final locals = {
        for (final record in await repository.listAll()) record.id: record,
      };
      await check();
      for (final entry in remote.entries) {
        await check();
        final local = locals[entry.key];
        final cloud = entry.value;
        if (local?.cloudDeletedAt == 'pending') continue;
        try {
          final payload = local == null ? null : await _payload(local);
          await check();
          final dirty =
              local != null &&
              memoryCloudHash(payload!) != local.cloudRecordHash;
          final sameVersion =
              local?.cloudVersion == cloud['version'].toString();
          final sameContent =
              payload != null && memoryCloudHash(payload) == _remoteHash(cloud);
          if (local != null && dirty && !sameContent) {
            if (!sameVersion) await _error(local, '另一个设备有新版本；本机修改已保留', check);
            continue;
          }
          if (local == null ||
              !sameVersion ||
              !sameContent ||
              local.cloudSyncError != null) {
            final imported = await _accept(cloud, local, check);
            await _ensureImage(imported, api, check);
          } else {
            await _ensureImage(local, api, check);
          }
        } on _ScopeChanged {
          rethrow;
        } catch (_) {
          hasPending = true;
        }
      }
      for (final record in await repository.listAll()) {
        await check();
        if (record.cloudDeletedAt != null &&
            record.cloudDeletedAt != 'pending') {
          continue;
        }
        try {
          if (record.cloudDeletedAt == 'pending') {
            final version = int.tryParse(record.cloudVersion ?? '') ?? 0;
            if (version == 0 && !remote.containsKey(record.id)) {
              await _local(record, {
                'cloudDeletedAt': DateTime.now().toUtc().toIso8601String(),
                'cloudVersion': '0',
                'cloudSyncError': null,
              }, check);
            } else {
              final cloud = remote[record.id]?['deletedAt'] != null
                  ? remote[record.id]!
                  : await api.deleteMemoryRecord(record.id, version);
              await check();
              await _local(record, {
                'cloudVersion': cloud['version'].toString(),
                'cloudRecordHash': _remoteHash(cloud),
                'cloudDeletedAt': cloud['deletedAt'],
                'cloudSyncError': null,
              }, check);
            }
            continue;
          }
          final payload = await _payload(record);
          await check();
          final hash = memoryCloudHash(payload);
          if (hash == record.cloudRecordHash) continue;
          final cloud = remote[record.id];
          if (cloud != null &&
              cloud['version'].toString() != record.cloudVersion &&
              hash != _remoteHash(cloud)) {
            await _error(record, '另一个设备有新版本；本机修改已保留', check);
            continue;
          }
          if (record.imagePath != null &&
              payload['imageSha256'] != record.cloudImageSha256) {
            final bytes = _preparedImages[record.id];
            if (bytes == null ||
                sha256.convert(bytes).toString() != payload['imageSha256']) {
              throw const FormatException('上传副本已改变，请重试');
            }
            await check();
            await api.uploadMemoryImage(
              payload['imageSha256']! as String,
              bytes,
              _mime('', bytes),
            );
            await check();
          }
          final saved = await api.putMemoryRecord(
            record.id,
            payload,
            int.tryParse(record.cloudVersion ?? '') ?? 0,
          );
          await check();
          // A note edited during upload must stay dirty instead of being replaced by the response.
          final latest = await repository.read(record.id);
          if (memoryCloudHash(await _payload(latest)) != hash ||
              latest.cloudDeletedAt != record.cloudDeletedAt) {
            await _local(latest, {
              'cloudVersion': saved['version'].toString(),
              'cloudRecordHash': hash,
              'cloudImageSha256': payload['imageSha256'],
              'cloudSyncError': null,
            }, check);
            _rescan = true;
          } else {
            await _accept(saved, latest, check);
          }
        } on _ScopeChanged {
          rethrow;
        } on FormatException catch (error) {
          await _error(record, error.message, check);
        } on DioException catch (error) {
          await _error(
            record,
            error.response?.statusCode == 409
                ? '另一个设备有新版本；本机修改已保留'
                : '尚未同步到云端，连接恢复后自动重试',
            check,
          );
        } catch (_) {
          await _error(record, '尚未同步到云端，连接恢复后自动重试', check);
        } finally {
          _preparedImages.remove(record.id);
        }
      }
      await check();
      _notifying = true;
      try {
        repository.refresh();
      } finally {
        _notifying = false;
      }
    } on _ScopeChanged {
      // Account changes must never write a former account's results into the new scope.
    } catch (_) {
      hasPending = true;
    }
  }

  Future<Map<String, Object?>> _payload(MemoryRecord record) async {
    var imageHash = record.cloudImageSha256;
    if (record.imagePath != null && imageHash == null) {
      var bytes = _preparedImages[record.id];
      if (bytes == null) {
        final uploadPath = await repository.prepareUpload(record.id);
        final file = File(uploadPath);
        if (await file.length() > 900 * 1024) {
          throw const FormatException('压缩副本仍超过 900 KiB，原图仍保留在本机');
        }
        bytes = await file.readAsBytes();
        if (bytes.isEmpty || bytes.length > 900 * 1024) {
          throw const FormatException('图片上传副本无效，原图仍保留在本机');
        }
        _preparedImages[record.id] = bytes;
      }
      imageHash = sha256.convert(bytes).toString();
    }
    return record.toCloudMap(imageSha256: imageHash);
  }

  String _remoteHash(Map<String, dynamic> cloud) => memoryCloudHash(
    MemoryRecord.fromMap(cloud)
        .toCloudMap(imageSha256: cloud['imageSha256'] as String?),
  );

  Future<MemoryRecord> _accept(
    Map<String, dynamic> cloud,
    MemoryRecord? local,
    Future<void> Function() check,
  ) async {
    await check();
    final value = MemoryRecord.fromMap(cloud)
        .toCloudMap(imageSha256: cloud['imageSha256'] as String?);
    value.remove('imageSha256');
    value.addAll({
      'cloudVersion': cloud['version'].toString(),
      'cloudRecordHash': _remoteHash(cloud),
      'cloudImageSha256': cloud['imageSha256'],
      'cloudDeletedAt': cloud['deletedAt'],
      'cloudSyncError': null,
    });
    return repository.importCloud(value, local, expectedScope: _activeScope);
  }

  Future<void> _local(
    MemoryRecord record,
    Map<String, Object?> fields,
    Future<void> Function() check,
  ) async {
    await check();
    final values = Map<String, Object?>.from(record.toMap())
      ..remove('imagePath');
    values.addAll(fields);
    await repository.importCloud(values, record, expectedScope: _activeScope);
  }

  Future<void> _error(
    MemoryRecord record,
    String message,
    Future<void> Function() check,
  ) async {
    hasPending = true;
    await check();
    final latest = await repository.read(record.id);
    await _local(latest, {'cloudSyncError': message}, check);
  }

  Future<void> _ensureImage(
    MemoryRecord record,
    OrialisApiClient api,
    Future<void> Function() check,
  ) async {
    if (record.cloudDeletedAt != null || record.cloudImageSha256 == null) {
      return;
    }
    if (record.imagePath != null && await File(record.imagePath!).exists()) {
      return;
    }
    final bytes = await api.downloadMemoryImage(record.cloudImageSha256!);
    await check();
    if (sha256.convert(bytes).toString() != record.cloudImageSha256) {
      throw const FormatException('云端原图校验失败');
    }
    await repository.storeCloudImage(
      record.id,
      bytes,
      _mime('', bytes),
      record.cloudImageSha256!,
      expectedScope: _activeScope,
    );
  }

  String _mime(String path, Uint8List bytes) =>
      lookupMimeType(path, headerBytes: bytes) ?? 'application/octet-stream';

  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _retry?.cancel();
    repository.removeListener(_changed);
    if (repository.onSync == sync) repository.onSync = null;
  }
}

String memoryCloudHash(Map<String, Object?> record) =>
    sha256.convert(utf8.encode(jsonEncode(record))).toString();

class _ScopeChanged implements Exception {
  const _ScopeChanged();
}
