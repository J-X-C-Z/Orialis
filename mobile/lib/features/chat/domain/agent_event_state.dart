import '../../../core/realtime/mobile_realtime_client.dart';

/// The names are deliberately strings: the mobile client can display newer
/// server events without requiring a protocol or server release first.
class AgentEventStore {
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

  void apply(MobileEnvelope envelope) {
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

    final outer = envelope.payload;
    final kind =
        _text(outer['kind']) ??
        _text(outer['event']) ??
        _text(outer['eventType']) ??
        _text(outer['type']);
    if (kind == null) {
      fallbacks.add(UnknownAgentEvent(kind: 'event', payload: outer));
      return;
    }
    final nested = outer['data'];
    final payload = nested is Map
        ? {...outer, ...Map<String, dynamic>.from(nested)}
        : outer;
    switch (kind) {
      case 'agent.typing':
        typing = _bool(payload['active']) ?? _bool(payload['typing']) ?? true;
      case 'stream.delta':
      case 'agent.delta':
        _applyDelta(payload);
      case 'stream.complete':
      case 'agent.complete':
        _stream(payload).complete = true;
      case 'stream.error':
      case 'agent.error':
        final stream = _stream(payload);
        stream.error =
            _text(payload['message']) ?? _text(payload['error']) ?? '处理失败';
        stream.complete = true;
      case 'agent.status':
        agentStatus = _text(payload['status']) ?? _text(payload['state']);
        agentStatusDetail =
            _text(payload['message']) ?? _text(payload['detail']);
      case 'tool.start':
        final id = _id(payload, 'tool');
        tools[id] = ToolTimelineItem(
          id: id,
          name: _text(payload['name']) ?? _text(payload['tool']) ?? '工具',
          status: 'running',
          detail: _text(payload['detail']) ?? _text(payload['input']),
        );
      case 'tool.update':
        _updateTool(payload, 'running');
      case 'tool.end':
        _updateTool(payload, _text(payload['status']) ?? 'completed');
      case 'clarify.request':
        final request = ClarificationRequest.fromPayload(payload);
        clarifications[request.id] = request;
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
        final session = SessionInfo.fromPayload(payload, event: kind);
        sessions[session.id] = session;
      case 'artifact.created':
        final artifact = ArtifactInfo.fromPayload(payload);
        artifacts[artifact.id] = artifact;
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
    stream.deltas[sequence] = delta;
    stream.nextSequence = _nextSequence(stream.deltas);
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

  String get text {
    final keys = deltas.keys.toList()..sort();
    return keys.map((key) => deltas[key]!).join();
  }

  bool get hasGap {
    if (deltas.isEmpty) return false;
    final keys = deltas.keys.toList()..sort();
    for (var value = keys.first; value <= keys.last; value++) {
      if (!deltas.containsKey(value)) return true;
    }
    return false;
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
        options: _stringList(payload['options']),
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
        title: _text(payload['title']) ?? _text(payload['action']) ?? '需要你的确认',
        detail: _text(payload['detail']) ?? _text(payload['description']),
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
        output: _text(payload['output']) ?? _text(payload['result']) ?? '',
        ok: _bool(payload['ok']) ?? _text(payload['status']) != 'error',
      );
}

class SessionInfo {
  const SessionInfo({
    required this.id,
    required this.event,
    this.status,
    this.title,
  });
  final String id;
  final String event;
  final String? status;
  final String? title;

  factory SessionInfo.fromPayload(
    Map<String, dynamic> payload, {
    required String event,
  }) => SessionInfo(
    id: _id(payload, 'session'),
    event: event,
    status: _text(payload['status']) ?? _text(payload['state']),
    title: _text(payload['title']),
  );
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
        mimeType: _text(payload['mimeType']) ?? _text(payload['mime_type']),
        url:
            _text(payload['url']) ??
            _text(payload['downloadUrl']) ??
            _text(payload['download_url']),
        description: _text(payload['description']),
      );
}

class DeliveryNotice {
  const DeliveryNotice({required this.message, this.ok = true});
  final String message;
  final bool ok;

  factory DeliveryNotice.fromPayload(Map<String, dynamic> payload) =>
      DeliveryNotice(
        message:
            _text(payload['message']) ?? _text(payload['detail']) ?? '投递设置已更新',
        ok: _bool(payload['ok']) ?? true,
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
    _text(payload['id']) ??
    '$kind-${payload.hashCode}';

Set<String>? _stringSet(Object? value) {
  if (value is! List) return null;
  return value.whereType<String>().toSet();
}

List<String> _stringList(Object? value) =>
    value is List ? value.whereType<String>().toList() : const [];
