import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/attachments/attachment_bridge.dart';
import '../../../core/config/app_config.dart';

class ChatDraftState {
  const ChatDraftState({
    required this.text,
    this.attachments = const [],
    this.appliedShareIds = const {},
  });

  final String text;
  final List<AttachmentRecord> attachments;
  final Set<String> appliedShareIds;
}

class ChatDrafts {
  ChatDrafts._(this._preferences, this._scope);

  final SharedPreferences _preferences;
  final String _scope;
  Future<void> _pending = Future.value();

  static Future<ChatDrafts> open(AppConfig config) async {
    final scope = await config.desktopDatabaseName();
    return ChatDrafts._(await SharedPreferences.getInstance(), scope);
  }

  String _key(String conversationId) =>
      'orialis.chat.draft.${jsonEncode([_scope, conversationId])}';

  String _stateKey(String conversationId) =>
      'orialis.chat.draft.v2.${jsonEncode([_scope, conversationId])}';

  ChatDraftState _read(String conversationId) {
    final value = _preferences.getString(_stateKey(conversationId));
    if (value == null) {
      return ChatDraftState(
        text: _preferences.getString(_key(conversationId)) ?? '',
      );
    }
    final json = jsonDecode(value) as Map<String, dynamic>;
    return ChatDraftState(
      text: json['text'] as String,
      attachments: (json['attachments'] as List<dynamic>)
          .map(
            (item) => AttachmentRecord.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
      appliedShareIds: (json['appliedShareIds'] as List<dynamic>)
          .cast<String>()
          .toSet(),
    );
  }

  Future<ChatDraftState> loadState(String conversationId) async {
    await _pending;
    return _read(conversationId);
  }

  Future<String> load(String conversationId) async =>
      (await loadState(conversationId)).text;

  Future<void> _write(String conversationId, ChatDraftState state) async {
    final key = _stateKey(conversationId);
    final previous = _preferences.getString(key);
    final encoded = jsonEncode({
      'text': state.text,
      'attachments': state.attachments.map((item) => item.toJson()).toList(),
      'appliedShareIds': state.appliedShareIds.toList(),
    });
    try {
      if (!await _preferences.setString(key, encoded)) {
        throw StateError('Chat draft could not be saved');
      }
    } on Object {
      // SharedPreferences mutates its cache before a platform write succeeds.
      await _preferences.reload();
      if (_preferences.getString(key) != previous) {
        throw StateError('Chat draft write failed with an uncertain result');
      }
      rethrow;
    }
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final operation = _pending.then((_) => action());
    // A failed write must not prevent a later edit from being saved.
    _pending = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> save(String conversationId, String text) => _enqueue(() {
    final current = _read(conversationId);
    return _write(
      conversationId,
      ChatDraftState(
        text: text,
        attachments: current.attachments,
        appliedShareIds: current.appliedShareIds,
      ),
    );
  });

  Future<void> saveState(String conversationId, ChatDraftState state) =>
      _enqueue(() {
        final current = _read(conversationId);
        return _write(
          conversationId,
          ChatDraftState(
            text: state.text,
            attachments: state.attachments,
            appliedShareIds: {
              ...current.appliedShareIds,
              ...state.appliedShareIds,
            },
          ),
        );
      });

  Future<void> clearSubmitted(
    String conversationId,
    String submittedText, {
    Iterable<String>? attachmentPaths,
  }) => _enqueue(() {
    final current = _read(conversationId);
    final paths = attachmentPaths?.toSet() ?? const <String>{};
    return _write(
      conversationId,
      ChatDraftState(
        text: current.text == submittedText ? '' : current.text,
        attachments: current.attachments
            .where((item) => !paths.contains(item.localPath))
            .toList(),
        appliedShareIds: current.appliedShareIds,
      ),
    );
  });
}
