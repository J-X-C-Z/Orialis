import 'package:flutter/foundation.dart';

import '../../../core/realtime/mobile_realtime_client.dart';

/// The names are deliberately strings: the mobile client can display newer
/// server events without requiring a protocol or server release first.
///
/// Extends [ChangeNotifier] so the agent panel can rebuild in isolation from
/// the chat page chrome. Callers that receive event bursts should [applySilent]
/// each one and [notifyListeners] once per frame.
class AgentEventStore extends ChangeNotifier {
  /// Only an explicit plugin acknowledgement may mark a message received.
  final Set<String> receivedMessageIds = {};

  void _receiveMessage(Map<String, dynamic> payload) {
    if (payload['status'] != 'received') return;
    final id = _text(payload['message_id']) ?? _text(payload['messageId']);
    if (id != null) receivedMessageIds.add(id);
  }

  AgentEventStore({Set<String>? capabilities})
    : capabilities = AgentCapabilities(capabilities);

  AgentCapabilities capabilities;
  bool typing = false;
  String? agentStatus;
  String? agentStatusDetail;
  final Map<String, AgentStream> streams = {};
  final Map<String, ToolTimelineItem> tools = {};
  final Map<String, ClarificationRequest> clarifications = {};
  final Map<String, ApprovalRequest> approvals = {};
  final Map<String, CommandResult> commandResults = {};
  final Map<String, SessionInfo> sessions = {};
  final Map<String, ArtifactInfo> artifacts = {};
  final List<DeliveryNotice> deliveryNotices = [];
  final List<AgentError> errors = [];
  final List<UnknownAgentEvent> fallbacks = [];
  final ActionSubmissionGuard actions = ActionSubmissionGuard();

  /// Bumped whenever the server reports Agent device list changes.
  int agentDevicesChanged = 0;

  void apply(MobileEnvelope envelope) {
    applySilent(envelope);
    notifyListeners();
  }

  /// Wakes listeners after a batch of [applySilent] calls.
  void notify() => notifyListeners();

  /// Applies one event without waking listeners; batch callers notify once.
  void applySilent(MobileEnvelope envelope) {
    if (envelope.type == 'message.ack') {
      _receiveMessage(envelope.payload);
      return;
    }
    if (envelope.type == 'hello.ack') {
      final declared =
          _stringSet(envelope.payload['capabilities']) ??
          _stringSet(envelope.payload['features']);
      capabilities = AgentCapabilities(declared, negotiated: declared != null);
      return;
    }
    if (envelope.type == 'error') {
      _addError(envelope.payload, envelope.requestId);
      return;
    }
    if (envelope.type != 'event') return;

    final outer = _normalizeEventPayload(envelope.payload);
    var kind = _eventKind(outer);
    if (kind == null) {
      fallbacks.add(UnknownAgentEvent(kind: 'event', payload: outer));
      return;
    }
    var payload = outer;
    // Server wraps structured Agent Gateway frames as
    // `{kind: agent_gateway_event, event: {...}}`. Unwrap so the nested
    // `type` drives the switch below.
    if (kind == 'agent_gateway_event') {
      final nested = outer['event'];
      if (nested is! Map) {
        fallbacks.add(UnknownAgentEvent(kind: kind, payload: outer));
        return;
      }
      payload = _normalizeEventPayload(Map<String, dynamic>.from(nested));
      kind = _eventKind(payload);
      if (kind == null) {
        fallbacks.add(UnknownAgentEvent(kind: 'agent_gateway_event', payload: payload));
        return;
      }
    } else {
      final nested = outer['data'];
      if (nested is Map) {
        payload = {...outer, ..._normalizeEventPayload(Map<String, dynamic>.from(nested))};
      }
    }
    kind = _canonicalEventKind(kind);
    switch (kind) {
      case 'message.ack':
        _receiveMessage(payload);
      case 'agent.typing':
        typing = _bool(payload['active']) ?? _bool(payload['typing']) ?? true;
      case 'agent.start':
        // Stream open is implied by the first delta; keep the run id warm.
        _stream(payload);
      case 'stream.delta':
      case 'agent.delta':
        _applyDelta(payload);
      case 'stream.complete':
      case 'agent.complete':
        _stream(payload).markComplete();
      case 'stream.error':
      case 'agent.error':
        _stream(payload).markError(
          _text(payload['message']) ?? _text(payload['error']) ?? '处理失败',
        );
      case 'agent.status':
        agentStatus = _text(payload['status']) ?? _text(payload['state']);
        agentStatusDetail =
            _text(payload['message']) ?? _text(payload['detail']);
      case 'tool.start':
        final id = _id(payload, 'tool');
        tools[id] = ToolTimelineItem(
          id: id,
          name:
              _text(payload['name']) ??
              _text(payload['tool']) ??
              _text(payload['toolName']) ??
              '工具',
          status: 'running',
          detail: _text(payload['detail']) ?? _text(payload['input']),
        );
      case 'tool.update':
        _updateTool(payload, 'running');
      case 'tool.end':
        final status = _text(payload['status']) ?? _text(payload['state']);
        _updateTool(
          payload,
          status == 'failed' || status == 'error' ? 'failed' : (status ?? 'completed'),
        );
      case 'clarify.request':
        final request = ClarificationRequest.fromPayload(payload);
        clarifications[request.id] = request;
      case 'clarify.resolve':
      case 'clarify.cancel':
        clarifications.remove(_id(payload, 'clarification'));
      case 'approval.request':
        final request = ApprovalRequest.fromPayload(payload);
        approvals[request.id] = request;
      case 'approval.resolved':
        approvals.remove(_id(payload, 'approval'));
      case 'hermes.command.result':
        final result = CommandResult.fromPayload(payload);
        commandResults[result.id] = result;
      case 'delivery.notification':
      case 'delivery.notification.result':
        deliveryNotices.add(DeliveryNotice.fromPayload(payload));
      case 'session.created':
      case 'session.reset':
      case 'session.resumed':
      case 'session.status':
      case 'session.title':
      case 'session.retry':
      case 'session.stop':
      case 'session.update':
      case 'session.complete':
      case 'session.cancel':
      case 'session.error':
      case 'session.ended':
        final session = SessionInfo.fromPayload(payload, event: kind);
        sessions[session.id] = session;
      case 'artifact.created':
      case 'artifact.completed':
        final artifact = ArtifactInfo.fromPayload(payload);
        artifacts[artifact.id] = artifact;
      case 'artifact.progress':
      case 'artifact.failed':
        final artifact = ArtifactInfo.fromPayload(payload);
        artifacts[artifact.id] = artifact;
      case 'agent_devices_changed':
        agentDevicesChanged++;
      default:
        fallbacks.add(UnknownAgentEvent(kind: kind, payload: payload));
    }
  }

  AgentStream _stream(Map<String, dynamic> payload) {
    final id = _id(payload, 'stream');
    return streams.putIfAbsent(id, () => AgentStream(id: id));
  }

  void _applyDelta(Map<String, dynamic> payload) {
    final stream = _stream(payload);
    final rawSequence =
        payload['sequence'] ?? payload['seq'] ?? payload['index'];
    final sequence = rawSequence is num
        ? rawSequence.toInt()
        : stream.nextSequence;
    final delta = _text(payload['delta']) ?? _text(payload['content']) ?? '';
    if (delta.isEmpty || stream.deltas.containsKey(sequence)) return;
    stream.putDelta(sequence, delta);
    // Sequential streaming is the common path; only fall back to a scan when
    // an out-of-order or sparse sequence map needs a precise next index.
    stream.nextSequence = sequence >= stream.nextSequence
        ? sequence + 1
        : _nextSequence(stream.deltas);
  }

  void _updateTool(Map<String, dynamic> payload, String status) {
    final id = _id(payload, 'tool');
    final old = tools[id];
    tools[id] = ToolTimelineItem(
      id: id,
      name: _text(payload['name']) ?? old?.name ?? '工具',
      status: status,
      detail:
          _text(payload['detail']) ?? _text(payload['output']) ?? old?.detail,
    );
  }

  void _addError(Map<String, dynamic> payload, String? requestId) {
    errors.add(
      AgentError(
        code: _text(payload['code']) ?? 'error',
        message: _text(payload['message']) ?? '服务暂时不可用',
        requestId: requestId ?? _text(payload['replyTo']),
      ),
    );
  }
}

/// Resolves the effective event kind and conversation id for an envelope.
///
/// Server-originated structured Agent Gateway frames arrive wrapped as
/// `{kind: agent_gateway_event, event: {...}}`; this helper unwraps them and
/// applies the same canonical naming the store switches on.
({String? kind, String? conversationId}) resolveAgentEnvelope(
  MobileEnvelope envelope,
) {
  if (envelope.type != 'event') {
    return (kind: envelope.type, conversationId: null);
  }
  final outer = _normalizeEventPayload(envelope.payload);
  var kind = _eventKind(outer);
  var payload = outer;
  if (kind == 'agent_gateway_event') {
    final nested = outer['event'];
    if (nested is! Map) return (kind: kind, conversationId: null);
    payload = _normalizeEventPayload(Map<String, dynamic>.from(nested));
    kind = _eventKind(payload);
  } else {
    final nested = outer['data'];
    if (nested is Map) {
      payload = {
        ...outer,
        ..._normalizeEventPayload(Map<String, dynamic>.from(nested)),
      };
      kind = _eventKind(payload) ?? kind;
    }
  }
  if (kind == null) return (kind: null, conversationId: null);
  return (
    kind: _canonicalEventKind(kind),
    conversationId:
        _text(payload['conversationId']) ?? _text(payload['conversation_id']),
  );
}

class AgentCapabilities {
  AgentCapabilities(Set<String>? values, {this.negotiated = false})
    : values = values ?? <String>{};

  final Set<String> values;
  final bool negotiated;

  bool supports(String value) => values.contains(value);

  String get label => negotiated ? '能力已协商' : '兼容模式';
}

class AgentStream {
  AgentStream({required this.id});
  final String id;
  final Map<int, String> deltas = {};
  int nextSequence = 0;
  bool complete = false;
  String? error;

  // Streaming rebuilds call text/hasGap every frame; keep the last result so
  // long replies do not re-sort and re-join the full delta map on each tick.
  String? _textCache;
  bool? _hasGapCache;
  List<int>? _sortedKeysCache;

  void _invalidate() {
    _textCache = null;
    _hasGapCache = null;
    _sortedKeysCache = null;
  }

  void putDelta(int sequence, String delta) {
    if (delta.isEmpty || deltas.containsKey(sequence)) return;
    deltas[sequence] = delta;
    _invalidate();
  }

  void markComplete() {
    complete = true;
    _invalidate();
  }

  void markError(String value) {
    error = value;
    complete = true;
    _invalidate();
  }

  List<int> get _sortedKeys =>
      _sortedKeysCache ??= (deltas.keys.toList()..sort());

  String get text {
    final cached = _textCache;
    if (cached != null) return cached;
    if (deltas.isEmpty) return _textCache = '';
    return _textCache = [for (final key in _sortedKeys) deltas[key]!].join();
  }

  bool get hasGap {
    final cached = _hasGapCache;
    if (cached != null) return cached;
    if (deltas.isEmpty) return _hasGapCache = false;
    final keys = _sortedKeys;
    for (var value = keys.first; value <= keys.last; value++) {
      if (!deltas.containsKey(value)) return _hasGapCache = true;
    }
    return _hasGapCache = false;
  }

  String get displayStatus {
    if (error != null) return '出错';
    if (complete && !hasGap) return '完成';
    if (complete) return '等待缺失片段';
    return '生成中';
  }
}

class ToolTimelineItem {
  const ToolTimelineItem({
    required this.id,
    required this.name,
    required this.status,
    this.detail,
  });
  final String id;
  final String name;
  final String status;
  final String? detail;
}

class ClarificationRequest {
  const ClarificationRequest({
    required this.id,
    required this.question,
    required this.options,
  });
  final String id;
  final String question;
  final List<String> options;

  factory ClarificationRequest.fromPayload(Map<String, dynamic> payload) =>
      ClarificationRequest(
        id: _id(payload, 'clarification'),
        question:
            _text(payload['question']) ?? _text(payload['prompt']) ?? '请补充选择',
        options: _stringList(payload['options'] ?? payload['choices']),
      );
}

class ApprovalRequest {
  const ApprovalRequest({required this.id, required this.title, this.detail});
  final String id;
  final String title;
  final String? detail;

  factory ApprovalRequest.fromPayload(Map<String, dynamic> payload) =>
      ApprovalRequest(
        id: _id(payload, 'approval'),
        title:
            _text(payload['title']) ??
            _text(payload['action']) ??
            _text(payload['command']) ??
            '需要你的确认',
        detail:
            _text(payload['detail']) ??
            _text(payload['description']) ??
            _text(payload['message']),
      );
}

class CommandResult {
  const CommandResult({
    required this.id,
    required this.command,
    required this.output,
    required this.ok,
  });
  final String id;
  final String command;
  final String output;
  final bool ok;

  factory CommandResult.fromPayload(Map<String, dynamic> payload) =>
      CommandResult(
        id: _id(payload, 'command'),
        command: _text(payload['command']) ?? 'Hermes 命令',
        output:
            _text(payload['output']) ??
            _text(payload['result']) ??
            _text(payload['content']) ??
            _text(payload['message']) ??
            '',
        ok:
            _bool(payload['ok']) ??
            !const {'error', 'failed', 'cancelled', 'timeout'}.contains(
              _text(payload['status']),
            ),
      );
}

class SessionInfo {
  const SessionInfo({
    required this.id,
    required this.event,
    this.status,
    this.title,
    this.message,
    this.command,
  });
  final String id;
  final String event;
  final String? status;
  final String? title;
  final String? message;
  final String? command;

  factory SessionInfo.fromPayload(
    Map<String, dynamic> payload, {
    required String event,
  }) {
    final update = payload['update'];
    return SessionInfo(
      id: _id(payload, 'session'),
      event: event,
      status:
          _text(payload['status']) ??
          _text(payload['state']) ??
          (update is Map ? _text(update['status']) : null) ??
          (event == 'session.complete'
              ? 'completed'
              : event == 'session.cancel'
              ? 'cancelled'
              : event == 'session.error' || event == 'session.ended'
              ? 'ended'
              : null),
      title:
          _text(payload['title']) ??
          (update is Map ? _text(update['title']) : null),
      message:
          _text(payload['message']) ??
          _text(payload['content']) ??
          _text(payload['output']),
      command: _text(payload['command']),
    );
  }
}

class ArtifactInfo {
  const ArtifactInfo({
    required this.id,
    required this.name,
    this.mimeType,
    this.url,
    this.description,
  });
  final String id;
  final String name;
  final String? mimeType;
  final String? url;
  final String? description;

  factory ArtifactInfo.fromPayload(Map<String, dynamic> payload) =>
      ArtifactInfo(
        id: _id(payload, 'artifact'),
        name: _text(payload['name']) ?? '未命名产物',
        mimeType:
            _text(payload['mimeType']) ??
            _text(payload['mime_type']) ??
            _text(payload['kind']),
        url:
            _text(payload['url']) ??
            _text(payload['downloadUrl']) ??
            _text(payload['download_url']) ??
            _text(payload['uri']),
        description:
            _text(payload['description']) ?? _text(payload['message']),
      );
}

class DeliveryNotice {
  const DeliveryNotice({required this.message, this.ok = true});
  final String message;
  final bool ok;

  factory DeliveryNotice.fromPayload(Map<String, dynamic> payload) =>
      DeliveryNotice(
        message:
            _text(payload['message']) ??
            _text(payload['detail']) ??
            _text(payload['content']) ??
            '投递设置已更新',
        ok:
            _bool(payload['ok']) ??
            !const {'error', 'failed', 'rejected', 'timeout'}.contains(
              _text(payload['status']),
            ),
      );
}

class AgentError {
  const AgentError({required this.code, required this.message, this.requestId});
  final String code;
  final String message;
  final String? requestId;
}

class UnknownAgentEvent {
  const UnknownAgentEvent({required this.kind, required this.payload});
  final String kind;
  final Map<String, dynamic> payload;
}

class ActionSubmissionGuard {
  final Set<String> _claimed = {};
  bool claim(String id) => _claimed.add(id);
  bool contains(String id) => _claimed.contains(id);
  void release(String id) => _claimed.remove(id);
}

int _nextSequence(Map<int, String> deltas) {
  if (deltas.isEmpty) return 0;
  final keys = deltas.keys.toList()..sort();
  var next = keys.first;
  while (deltas.containsKey(next)) {
    next++;
  }
  return next;
}

String? _text(Object? value) =>
    value is String && value.isNotEmpty ? value : null;
bool? _bool(Object? value) => value is bool ? value : null;

String _id(Map<String, dynamic> payload, String kind) =>
    _text(payload['${kind}Id']) ??
    _text(payload['${kind}_id']) ??
    _text(payload['toolCallId']) ??
    _text(payload['tool_call_id']) ??
    _text(payload['requestId']) ??
    _text(payload['request_id']) ??
    _text(payload['id']) ??
    '$kind-${payload.hashCode}';

Set<String>? _stringSet(Object? value) {
  if (value is! List) return null;
  return value.whereType<String>().toSet();
}

List<String> _stringList(Object? value) =>
    value is List ? value.whereType<String>().toList() : const [];

String? _eventKind(Map<String, dynamic> payload) =>
    // Prefer the gateway `type`/`event_type` discriminators: nested artifact
    // objects also carry a domain-level `kind` (e.g. "document") that must not
    // be mistaken for an event name.
    _text(payload['type']) ??
    _text(payload['event_type']) ??
    _text(payload['eventType']) ??
    _text(payload['kind']) ??
    _text(payload['event']);

/// Maps plugin/server wire names onto the names this store already switches on.
/// Unknown names pass through so the fallback card keeps working.
String _canonicalEventKind(String kind) => switch (kind) {
  'agent.started' => 'agent.start',
  'agent.completed' => 'agent.complete',
  'agent.failed' => 'agent.error',
  'stream.start' => 'agent.start',
  'stream.end' => 'stream.complete',
  'tool.started' => 'tool.start',
  'tool.progress' => 'tool.update',
  'tool.completed' => 'tool.end',
  'tool.failed' => 'tool.end',
  'tool.state' => 'tool.update',
  'clarify.requested' => 'clarify.request',
  'clarify.responded' => 'clarify.resolve',
  'approval.requested' => 'approval.request',
  'approval.responded' => 'approval.resolved',
  'approval.resolve' => 'approval.resolved',
  'command.reply' || 'slash.reply' => 'hermes.command.result',
  'delivery.send' ||
  'cron.delivery' ||
  'proactive.delivery' ||
  'delivery.ack' => 'delivery.notification',
  'session.started' ||
  'session.created' => 'session.created',
  'session.completed' => 'session.complete',
  'session.cancelled' => 'session.cancel',
  'session.failed' => 'session.error',
  'artifact.started' ||
  'artifact.created' ||
  'artifact.ready' => 'artifact.created',
  'artifact.event' => 'artifact.completed',
  'agent.state' => 'agent.status',
  'typing' => 'agent.typing',
  _ => kind,
};

/// Copies snake_case gateway fields onto the camelCase aliases the card
/// parsers already read, and flattens nested artifact objects.
Map<String, dynamic> _normalizeEventPayload(Map<String, dynamic> raw) {
  final payload = Map<String, dynamic>.from(raw);
  const aliases = <String, List<String>>{
    'tool_call_id': ['toolCallId', 'toolId', 'id'],
    'tool_name': ['toolName', 'name', 'tool'],
    'request_id': ['requestId', 'clarificationId', 'approvalId', 'id'],
    'session_id': ['sessionId', 'id'],
    'run_id': ['runId', 'streamId', 'id'],
    'stream_id': ['streamId', 'id'],
    'message_id': ['messageId', 'id'],
    'delivery_id': ['deliveryId', 'messageId', 'id'],
    'artifact_id': ['artifactId', 'id'],
    'conversation_id': ['conversationId'],
    'event_id': ['eventId'],
    'mime_type': ['mimeType'],
    'download_url': ['downloadUrl', 'url'],
    'reply_to': ['replyTo'],
    'multi_select': ['multiSelect'],
    'timeout_ms': ['timeoutMs'],
  };
  aliases.forEach((snake, camels) {
    final value = payload[snake];
    if (value == null) return;
    for (final camel in camels) {
      payload.putIfAbsent(camel, () => value);
    }
  });
  // Clarify options travel as `choices` on the gateway and `options` in cards.
  if (payload['options'] == null && payload['choices'] != null) {
    payload['options'] = payload['choices'];
  }
  // Approval detail fields arrive as action/details on the flat frame.
  if (payload['title'] == null) {
    payload['title'] = payload['action'] ?? payload['command'];
  }
  if (payload['detail'] == null) {
    payload['detail'] = payload['description'] ?? payload['details'];
  }
  // Tool progress/completion text lives under message/output/progress.
  if (payload['detail'] == null) {
    final output = payload['output'] ?? payload['progress'];
    payload['detail'] = output is String ? output : _text(payload['message']);
  }
  // Flatten nested artifact object (artifact.started/completed frames).
  // Skip `kind`: artifact.kind is domain metadata ("document"), not an event name.
  final artifact = payload['artifact'];
  if (artifact is Map) {
    final nested = _normalizeEventPayload(Map<String, dynamic>.from(artifact));
    nested.forEach((key, value) {
      if (key == 'kind') return;
      payload.putIfAbsent(key, () => value);
    });
    payload['artifactId'] ??= nested['id'];
    payload['artifact_id'] ??= nested['id'];
  }
  // Delivery frames carry content as the notice body.
  if (payload['message'] == null && payload['content'] is String) {
    payload['message'] = payload['content'];
  }
  return payload;
}
