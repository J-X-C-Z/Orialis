import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import '../data/agent_chat_service.dart';
import 'agent_status_ring.dart';

class ChatDevicePicker extends StatefulWidget {
  const ChatDevicePicker({
    required this.agents,
    required this.onRename,
    super.key,
  });

  final AgentChatService agents;
  final Future<String?> Function(ChatAgentDevice) onRename;

  @override
  State<ChatDevicePicker> createState() => _ChatDevicePickerState();
}

class _ChatDevicePickerState extends State<ChatDevicePicker> {
  late Future<List<ChatAgentDevice>> _devices = widget.agents.devices();
  final _names = <String, String>{};
  bool _renaming = false;

  Future<void> _rename(ChatAgentDevice device) async {
    if (_renaming) return;
    _renaming = true;
    try {
      final name = await widget.onRename(device);
      if (mounted && name != null) setState(() => _names[device.id] = name);
    } finally {
      _renaming = false;
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('与设备对话', style: LuminaTheme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('点击在线设备开始对话，长按设备卡片修改名称。'),
            const SizedBox(height: 24),
            FutureBuilder<List<ChatAgentDevice>>(
              future: _devices,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      children: [
                        LuminaProgress(),
                        SizedBox(height: 12),
                        Text('正在读取设备状态…'),
                      ],
                    ),
                  );
                }
                if (snapshot.hasError) {
                  return LuminaButton(
                    onPressed: () =>
                        setState(() => _devices = widget.agents.devices()),
                    child: const Text('设备状态读取失败，点击重试'),
                  );
                }
                final devices = snapshot.data ?? [];
                if (devices.isEmpty) return const Text('请先连接已配置的设备。');
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < devices.length; i++) ...[
                      if (i > 0) const SizedBox(height: 16),
                      _deviceRow(devices[i]),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    ),
  );

  Widget _deviceRow(ChatAgentDevice device) {
    final label = _names[device.id] ?? device.label;
    final status = device.online ? '在线' : '离线';
    final renamed = ChatAgentDevice(
      id: device.id,
      platform: device.platform,
      online: device.online,
      displayLabel: label,
    );
    return Semantics(
      onLongPressHint: '修改设备名称',
      child: GestureDetector(
        onLongPress: () => _rename(renamed),
        child: LuminaListRow(
          key: ValueKey('chat-device-${device.id}'),
          title: label,
          subtitle: '$status · ${widget.agents.agentLabel(device.id)}',
          trailing: AgentStatusRing(
            status: device.online
                ? AgentRingStatus.online
                : AgentRingStatus.offline,
            label: '$label · $status',
            onPressed: () => showLuminaToast(context, '$label · $status'),
          ),
          onTap: device.online
              ? () => Navigator.of(context, rootNavigator: true).pop(renamed)
              : null,
        ),
      ),
    );
  }
}
