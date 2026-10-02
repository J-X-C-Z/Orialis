import '../../../core/config/app_config.dart';
import '../../../core/network/orialis_api_client.dart';

class ChatAgentDevice {
  const ChatAgentDevice({
    required this.id,
    required this.platform,
    required this.online,
  });
  final String id;
  final String platform;
  final bool online;

  String get label {
    if (id.toLowerCase().contains('aozora')) return 'Aozora 服务器';
    if (platform == 'macos') return 'Mac 电脑';
    return id;
  }

  factory ChatAgentDevice.fromJson(Map<String, dynamic> json) =>
      ChatAgentDevice(
        id: json['deviceId'] as String,
        platform: json['platform'] as String,
        online: json['online'] as bool,
      );
}

/// Agent chat uses the authenticated Gateway registry, separate from Node pairing.
class AgentChatService {
  AgentChatService(this.config);
  final AppConfig config;

  Future<OrialisApiClient> client() async {
    if (await config.sessionToken() == null) {
      throw StateError('请先登录，再选择聊天设备');
    }
    return OrialisApiClient(
      baseUrl: await config.serverUrl(),
      deviceId: await config.deviceId(),
      config: config,
    );
  }

  Future<List<ChatAgentDevice>> devices() async =>
      (await (await client()).listAgentDevices())
          .map(ChatAgentDevice.fromJson)
          .toList();

  Future<String?> target(String conversationId) async =>
      (await client()).conversationAgentDevice(conversationId);

  Future<Map<String, dynamic>> createConversation(
    ChatAgentDevice device,
  ) async {
    if (!device.online) throw StateError('设备离线，请等待连接恢复');
    final api = await client();
    final conversation = await api.createConversation(title: device.label);
    try {
      await api.bindConversationAgentDevice(
        conversation['id'] as String,
        device.id,
      );
    } catch (_) {
      // A server without the binding route must never expose an unbound device chat.
      try {
        await api.deleteConversation(
          conversation['id'] as String,
          (conversation['version'] as num).toInt(),
          conversation['id'] as String,
        );
      } catch (_) {
        /* Preserve the original binding error. */
      }
      rethrow;
    }
    return conversation;
  }
}
