import 'package:uuid/uuid.dart';

import '../../chat/data/agent_chat_service.dart';

class QuickEventRequest {
  QuickEventRequest(String text)
    : text = text.trim(),
      id = 'event-${const Uuid().v7()}',
      createdAt = DateTime.now();

  final String text, id;
  final DateTime createdAt;
  (String, String)? _identity;
  Future<void>? _pending;
  bool _submitted = false;
}

/// Submit to the existing authenticated Hermes route; event parsing stays remote.
class QuickEventService {
  QuickEventService(this.agents);
  final AgentChatService agents;

  Future<void> submit(QuickEventRequest request) {
    if (request._submitted) return Future.value();
    return request._pending ??= _submit(request).whenComplete(() {
      request._pending = null;
    });
  }

  Future<void> _submit(QuickEventRequest request) async {
    if (request.text.isEmpty || request.text.length > 10000) {
      throw StateError('请输入 1–10000 字的事件描述');
    }
    final identity = await agents.identity();
    request._identity ??= identity;
    Future<void> check() async {
      if (await agents.identity() != request._identity) {
        throw StateError('登录或服务地址已改变，请重新打开快捷添加');
      }
    }

    await check();
    final devices = await agents.devices();
    await check();
    if (!devices.any(
      (device) =>
          device.id == agents.azureDeviceId &&
          device.online &&
          agents.isAllowedTarget(device.id),
    )) {
      throw StateError('Azure Hermes 暂未连接，请稍后重试');
    }
    final api = await agents.client();
    await check();
    await api.createConversation(
      title: '快捷添加事件',
      id: request.id,
      mutationId: '${request.id}:create',
    );
    await check();
    final target = await api.conversationAgentDevice(request.id);
    await check();
    if (target != null && target != agents.azureDeviceId) {
      throw StateError('此处理会话不属于 Azure Hermes，请重新打开快捷添加');
    }
    if (target == null) {
      await api.bindConversationAgentDevice(request.id, agents.azureDeviceId);
    }
    await check();
    await api.createMessage(
      conversationId: request.id,
      id: request.id,
      content:
          '''请处理用户的快捷添加事件请求，使用现有 Orialis 工具创建任务或日程，并用中文反馈实际处理结果。明确的日历安排创建为日程，待办事项创建为任务；时间或含义不足以确定时请询问，不要虚构已完成的操作。
用户发起时的本地时间：${request.createdAt.toIso8601String()}；UTC 偏移（分钟）：${request.createdAt.timeZoneOffset.inMinutes}。
以下为用户的事件描述：
${request.text}''',
    );
    await check();
    request._submitted = true;
  }
}
