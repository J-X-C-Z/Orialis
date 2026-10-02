import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/design/design_components.dart';
import '../../../pages/shared/page_parts.dart';
import '../application/device_center_controller.dart';
import '../data/device_data_source.dart';
import '../domain/device.dart';

class DeviceCenterPage extends ConsumerWidget {
  const DeviceCenterPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(deviceCenterControllerProvider);
    final controller = ref.read(deviceCenterControllerProvider.notifier);
    return OrialisPageScaffold(
      title: '设备中心',
      leading: LuminaIconButton(
        tooltip: '返回',
        icon: const LuminaIcon(LuminaIcons.back),
        onPressed: () => context.pop(),
      ),
      body: Builder(
        builder: (context) => ListView(
          padding: EdgeInsets.only(
            top: LuminaPageHeaderInset.of(context) + 12,
            bottom: MediaQuery.paddingOf(context).bottom + 24,
          ),
          children: [
            ContentStack(
              gap: 20,
              children: [
                const LuminaSurface(
                  child: Text('设备信息来自当前 Orialis 账号所连接的 Node 服务。'),
                ),
                if (state.loading)
                  const Center(child: CircularProgressIndicator()),
                if (state.error != null)
                  LuminaSurface(
                    child: Text(
                      state.error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                for (final device in state.devices)
                  _DeviceCard(
                    device: device,
                    details: device.deviceId == state.currentDeviceId
                        ? state.selectedDetails
                        : null,
                    selected: device.deviceId == state.currentDeviceId,
                    onSelect: () => controller.select(device.deviceId),
                    onRevoke: () => _revoke(context, controller, device),
                  ),
                LuminaButton(
                  primary: false,
                  onPressed: () => _startPairing(context, controller),
                  child: const Text('将此设备加入账号'),
                ),
                LuminaButton(
                  primary: false,
                  onPressed: () => _decidePairing(context, controller),
                  child: const Text('确认或拒绝配对请求'),
                ),
                const QuietLabel(
                  '只有服务明确发布 multidevice.v1 后才会读取设备。当前设备选择仅保存在本机账号范围内；设备名称/默认设置不受此页修改。',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startPairing(
    BuildContext context,
    DeviceCenterController controller,
  ) async {
    final name = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('将此设备加入账号'),
        content: TextField(
          controller: name,
          autofocus: true,
          maxLength: 128,
          decoration: const InputDecoration(labelText: '本机设备名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, name.text),
            child: const Text('生成配对码'),
          ),
        ],
      ),
    );
    name.dispose();
    if (result == null) return;
    try {
      await controller.startPairing(result);
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) {
          final challenge = controller.activePairingChallenge!;
          return AlertDialog(
            title: const Text('等待账号确认'),
            content: Text(
              '请在已登录此账号的设备上选择“确认或拒绝配对请求”，输入以下配对 ID 和确认码。\n\n配对 ID：${challenge.pairingId}\n确认码：${challenge.confirmationCode}\n有效期至：${challenge.expiresAt.toLocal()}\n\n确认后回到此设备完成配对。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('稍后完成'),
              ),
              TextButton(
                onPressed: () async {
                  try {
                    await controller.completePairing();
                    if (context.mounted) Navigator.pop(context);
                  } catch (error) {
                    if (context.mounted) {
                      Navigator.pop(context);
                      await _showError(
                        context,
                        deviceCenterException(error).message,
                      );
                    }
                  }
                },
                child: const Text('已确认，完成配对'),
              ),
            ],
          );
        },
      );
    } catch (error) {
      if (context.mounted) {
        await _showError(context, deviceCenterException(error).message);
      }
    }
  }

  Future<void> _decidePairing(
    BuildContext context,
    DeviceCenterController controller,
  ) async {
    final pairingId = TextEditingController();
    final code = TextEditingController();
    final result = await showDialog<(String, String, String)>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('配对请求'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pairingId,
              autofocus: true,
              decoration: const InputDecoration(labelText: '配对 ID'),
            ),
            TextField(
              controller: code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(labelText: '6 位确认码'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, (pairingId.text, code.text, 'reject')),
            child: const Text('拒绝配对'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, (pairingId.text, code.text, 'confirm')),
            child: const Text('确认配对'),
          ),
        ],
      ),
    );
    pairingId.dispose();
    code.dispose();
    if (result == null) return;
    try {
      if (result.$3 == 'confirm') {
        await controller.confirmPairing(result.$1, result.$2);
      } else {
        await controller.rejectPairing(result.$1, result.$2);
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.$3 == 'confirm' ? '已确认配对' : '已拒绝配对')),
        );
        await controller.load();
      }
    } catch (error) {
      if (context.mounted) {
        await _showError(context, deviceCenterException(error).message);
      }
    }
  }

  Future<void> _revoke(
    BuildContext context,
    DeviceCenterController controller,
    ConnectedDevice device,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤销此设备？'),
        content: Text('撤销“${device.displayName}”的 Node 凭据。该设备需要重新配对才能接入。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('撤销设备'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await controller.revoke(device.deviceId);
    } catch (error) {
      if (context.mounted) {
        await _showError(context, deviceCenterException(error).message);
      }
    }
  }

  Future<void> _showError(BuildContext context, String message) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('操作未完成'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.device,
    required this.details,
    required this.selected,
    required this.onSelect,
    required this.onRevoke,
  });

  final ConnectedDevice device;
  final ConnectedDevice? details;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final shown = details ?? device;
    return LuminaSurface(
      child: ContentStack(
        gap: 12,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shown.displayName,
                      style: LuminaTheme.of(context).textTheme.titleMedium,
                    ),
                    QuietLabel('${shown.platform} · ${_status(shown.status)}'),
                  ],
                ),
              ),
              if (selected) const Chip(label: Text('当前')),
            ],
          ),
          if (shown.nodeVersion != null)
            QuietLabel('Node ${shown.nodeVersion} · ID ${shown.deviceId}'),
          if (shown.lastSeenAt != null)
            QuietLabel('最近在线：${shown.lastSeenAt!.toLocal()}'),
          Row(
            children: [
              Expanded(
                child: LuminaButton(
                  onPressed: selected ? null : onSelect,
                  child: Text(selected ? '当前设备' : '切换到此设备'),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(onPressed: onRevoke, child: const Text('撤销')),
            ],
          ),
          for (final capability in shown.capabilities)
            Row(
              children: [
                Expanded(child: Text(capability.name)),
                Text(capability.available ? '可用' : '不可用'),
                const SizedBox(width: 8),
                Text(capability.granted ? '已授权' : '未授权'),
              ],
            ),
          if (shown.capabilities.isEmpty) const QuietLabel('该设备未报告能力'),
        ],
      ),
    );
  }

  String _status(DeviceStatus status) => switch (status) {
    DeviceStatus.online => '在线',
    DeviceStatus.offline => '离线',
    DeviceStatus.revoked => '已撤销',
    DeviceStatus.unknown => '未知',
  };
}
