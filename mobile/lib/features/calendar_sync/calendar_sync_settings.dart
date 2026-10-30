import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lumina_ui/lumina_ui.dart';

import '../../app/app.dart';

class CalendarSyncSettings extends ConsumerWidget {
  const CalendarSyncSettings({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(calendarSyncProvider);
    if (!sync.supported) return const SizedBox.shrink();
    return LuminaSection(
      title: '手机日历双向同步',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('选择一个可写系统日历，合并两边日程。新增、修改和删除双向同步，同时修改时保留冲突副本。'),
          const SizedBox(height: 12),
          Text(
            sync.error ??
                (sync.busy
                    ? '正在同步…'
                    : sync.enabled
                    ? '已连接'
                    : '未连接'),
          ),
          const SizedBox(height: 12),
          LuminaButton(
            primary: false,
            onPressed: sync.busy
                ? null
                : () async {
                    try {
                      final calendars = await sync.calendars();
                      if (!context.mounted) return;
                      if (calendars.isEmpty) {
                        showLuminaMessage(
                          context,
                          '手机中没有可写日历，请先在系统日历添加账户或本地日历',
                        );
                        return;
                      }
                      final id = await showLuminaSheet<String>(
                        context: context,
                        builder: (sheetContext) => SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('选择要双向同步的系统日历'),
                              for (final calendar in calendars)
                                LuminaListRow(
                                  title: calendar['name'] as String,
                                  onTap: () =>
                                      Navigator.of(sheetContext)
                                          .pop(calendar['id'] as String),
                                ),
                            ],
                          ),
                        ),
                      );
                      if (id != null && context.mounted) await sync.connect(id);
                    } catch (_) {
                      if (context.mounted) {
                        showLuminaMessage(context, '无法连接，请允许日历读写权限后重试');
                      }
                    }
                  },
            child: Text(sync.enabled ? '更换系统日历' : '连接系统日历'),
          ),
          if (sync.enabled) ...[
            const SizedBox(height: 8),
            LuminaButton(
              primary: false,
              onPressed: sync.busy ? null : sync.sync,
              child: const Text('立即同步'),
            ),
            const SizedBox(height: 8),
            LuminaButton(
              primary: false,
              onPressed: sync.busy ? null : sync.disconnect,
              child: const Text('停止同步'),
            ),
          ],
          const SizedBox(height: 8),
          const Text('应用运行期间自动同步，返回应用时检查变化。停止同步保留已有日程。系统重复日程暂不导入。'),
        ],
      ),
    );
  }
}
