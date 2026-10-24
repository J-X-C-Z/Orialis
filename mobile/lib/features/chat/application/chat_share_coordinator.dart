import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/attachments/attachment_bridge.dart';
import '../../../core/config/app_config.dart';

class ChatShareFile {
  const ChatShareFile({
    required this.path,
    required this.name,
    required this.mimeType,
    required this.size,
  });

  final String path, name, mimeType;
  final int size;
}

class ChatSharePayload {
  const ChatSharePayload({
    required this.id,
    required this.text,
    this.files = const [],
  });

  final String id, text;
  final List<ChatShareFile> files;

  factory ChatSharePayload.fromMap(Map<dynamic, dynamic> value) {
    final id = value['id'] as String? ?? '';
    final text = value['text'] as String? ?? '';
    final files = [
      for (final item in value['files'] as List? ?? const [])
        ChatShareFile(
          path: (item as Map)['path'] as String,
          name: item['name'] as String,
          mimeType: item['mimeType'] as String,
          size: (item['size'] as num).toInt(),
        ),
    ];
    if (!RegExp(r'^[a-fA-F0-9-]{36}$').hasMatch(id) ||
        (text.trim().isEmpty && files.isEmpty) ||
        files.length > 8 ||
        files.any(
          (file) =>
              file.path.isEmpty ||
              file.size < 0 ||
              file.size > 20 * 1024 * 1024,
        ) ||
        files.fold<int>(0, (size, file) => size + file.size) >
            48 * 1024 * 1024) {
      throw const FormatException('Invalid shared content');
    }
    return ChatSharePayload(id: id, text: text, files: files);
  }
}

String appendSharedText(String draft, String shared) {
  if (shared.isEmpty) return draft;
  if (draft.isEmpty) {
    return shared.trimLeft().startsWith('/') ? '分享内容：\n$shared' : shared;
  }
  return '$draft\n$shared';
}

/// Native keeps the original until the chosen chat owns its copied attachments.
class ChatShareCoordinator extends ChangeNotifier {
  ChatShareCoordinator({required this.config, MethodChannel? channel})
    : channel = channel ?? const MethodChannel('top.jxcz.orialis/chat_share');

  final AppConfig config;
  final MethodChannel channel;
  void Function(String id)? onShare;
  ChatSharePayload? get pending => _pending;
  ChatSharePayload? _pending;
  final _applied = <String>{};
  final _importing = <String>{};
  bool _started = false, _disposed = false, _authenticated = false;
  int _generation = 0;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    config.addIdentityListener(_revoke);
    config.addIdentityCommittedListener(_restore);
    channel.setMethodCallHandler((call) async {
      if (call.method == 'shareReceived' && call.arguments is String) {
        await open(call.arguments as String);
      }
    });
    await _restore();
  }

  Future<void> _revoke() async {
    _generation++;
    _authenticated = false;
    _pending = null;
    _applied.clear();
    _importing.clear();
    if (!_disposed) notifyListeners();
  }

  Future<void> _restore() async {
    final generation = _generation;
    final token = await config.sessionToken();
    final username = await config.sessionUsername();
    if (_disposed || generation != _generation) return;
    _authenticated =
        token != null &&
        token.isNotEmpty &&
        username != null &&
        username.isNotEmpty;
    await refresh();
  }

  Future<void> refresh() async {
    if (_disposed || !_authenticated) return;
    final generation = _generation;
    try {
      final value = await channel.invokeMapMethod<dynamic, dynamic>('pending');
      if (value == null || _disposed || generation != _generation) return;
      await _present(ChatSharePayload.fromMap(value), generation);
    } on Object {
      // Leave native content pending when the app or platform is not ready.
    }
  }

  Future<void> open(String id) async {
    if (_disposed || !_authenticated || _pending?.id == id) return;
    final generation = _generation;
    try {
      final value = await channel.invokeMapMethod<dynamic, dynamic>('read', {
        'id': id,
      });
      if (value != null) {
        await _present(ChatSharePayload.fromMap(value), generation);
      }
    } on Object {
      // A later resume retries the still-pending native record.
    }
  }

  Future<void> _present(ChatSharePayload payload, int generation) async {
    if (_disposed || generation != _generation || !_authenticated) return;
    if (_pending?.id == payload.id) return;
    if (_applied.contains(payload.id)) {
      await channel.invokeMethod<void>('complete', {'id': payload.id});
      return;
    }
    _pending = payload;
    notifyListeners();
    onShare?.call(payload.id);
  }

  Future<bool> importIntoDraft({
    required String id,
    bool alreadyApplied = false,
    required Future<AttachmentRecord> Function(String path) importFile,
    required bool Function() isCurrent,
    required Future<void> Function(
      ChatSharePayload payload,
      List<AttachmentRecord> files,
      bool Function() isCurrent,
    )
    apply,
  }) async {
    final payload = _pending;
    if (_disposed ||
        !_authenticated ||
        payload?.id != id ||
        !_importing.add(id)) {
      return false;
    }
    final generation = _generation;
    bool current() =>
        !_disposed &&
        _authenticated &&
        generation == _generation &&
        _pending?.id == id &&
        isCurrent();
    try {
      if (!alreadyApplied && !_applied.contains(id)) {
        final files = <AttachmentRecord>[];
        for (final file in payload!.files) {
          if (!current()) return false;
          final copied = await importFile(file.path);
          files.add(
            AttachmentRecord(
              localPath: copied.localPath,
              name: file.name,
              mimeType: file.mimeType,
              size: copied.size,
            ),
          );
        }
        if (!current()) return false;
        await apply(payload, files, current);
        if (!current()) return false;
      }
      _applied.add(id);
      await channel.invokeMethod<void>('complete', {'id': id});
      if (!current()) return false;
      _pending = null;
      notifyListeners();
      unawaited(refresh());
      return true;
    } finally {
      if (generation == _generation) _importing.remove(id);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    config.removeIdentityListener(_revoke);
    config.removeIdentityCommittedListener(_restore);
    channel.setMethodCallHandler(null);
    super.dispose();
  }
}
