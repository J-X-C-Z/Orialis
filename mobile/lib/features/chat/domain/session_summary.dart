import 'agent_event_state.dart';

enum ChatSessionState { ready, running, pending, failed, completed }

class ChatSessionSummary {
  const ChatSessionSummary(this.state, {this.pendingRequests = 0});

  final ChatSessionState state;
  final int pendingRequests;

  String get label => switch (state) {
    ChatSessionState.ready => '就绪 · 无实时状态',
    ChatSessionState.running => '运行中',
    ChatSessionState.pending => '$pendingRequests 项待处理',
    ChatSessionState.failed => '失败',
    ChatSessionState.completed => '已完成',
  };

  factory ChatSessionSummary.fromEvents(AgentEventStore? events) {
    if (events == null) return const ChatSessionSummary(ChatSessionState.ready);
    final pending = events.approvals.length + events.clarifications.length;
    if (pending > 0) {
      return ChatSessionSummary(
        ChatSessionState.pending,
        pendingRequests: pending,
      );
    }
    final reported = switch (events.agentStatus) {
      'idle' || 'ready' || 'unknown' => ChatSessionState.ready,
      'failed' || 'error' || 'timeout' => ChatSessionState.failed,
      'completed' ||
      'complete' ||
      'done' ||
      'stopped' ||
      'cancelled' => ChatSessionState.completed,
      'running' ||
      'working' ||
      'processing' ||
      'thinking' ||
      'busy' ||
      'responding' ||
      'generating' ||
      'streaming' ||
      'typing' => ChatSessionState.running,
      _ => null,
    };
    if (events.hasStatusSnapshot && reported != null) {
      return ChatSessionSummary(reported);
    }
    final stream = events.streams.values.lastOrNull;
    final session = events.sessions.values.lastOrNull;
    final tool = events.tools.values.lastOrNull;
    if (events.typing || (stream != null && !stream.complete)) {
      return const ChatSessionSummary(ChatSessionState.running);
    }
    const failed = {'failed', 'error', 'timeout'};
    if (stream?.error != null ||
        failed.contains(events.agentStatus) ||
        failed.contains(session?.status) ||
        session?.event == 'session.error') {
      return const ChatSessionSummary(ChatSessionState.failed);
    }
    const completed = {
      'completed',
      'complete',
      'done',
      'stopped',
      'cancelled',
      'ended',
    };
    if (stream?.complete == true ||
        completed.contains(events.agentStatus) ||
        completed.contains(session?.status)) {
      return const ChatSessionSummary(ChatSessionState.completed);
    }
    const running = {'running', 'working', 'thinking', 'busy', 'started'};
    if (events.tools.values.any((tool) => tool.status == 'running') ||
        running.contains(events.agentStatus) ||
        running.contains(session?.status)) {
      return const ChatSessionSummary(ChatSessionState.running);
    }
    if (tool?.status == 'failed' || events.errors.isNotEmpty) {
      return const ChatSessionSummary(ChatSessionState.failed);
    }
    return const ChatSessionSummary(ChatSessionState.ready);
  }
}
