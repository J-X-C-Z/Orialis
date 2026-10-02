import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../shared/page_parts.dart';

class SystemSettingsPage extends ConsumerStatefulWidget {
  const SystemSettingsPage({super.key});

  @override
  ConsumerState<SystemSettingsPage> createState() => _SystemSettingsPageState();
}

class _SystemSettingsPageState extends ConsumerState<SystemSettingsPage>
    with WidgetsBindingObserver {
  Map<Object?, Object?> _status = const {};
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }

  Future<void> _load() async {
    final system = ref.read(systemIntegrationProvider);
    if (system != null) {
      await system.start();
      await system.refresh();
      final status = await system.status();
      if (!mounted) return;
      setState(() {
        _status = status ?? const {};
        _busy = false;
      });
    } else if (mounted) {
      setState(() => _busy = false);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) showLuminaMessage(context, '暂时无法完成，请稍后重试');
    } finally {
      if (mounted) await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final system = ref.watch(systemIntegrationProvider);
    final notification = _status['notificationsEnabled'] == true;
    final exact = _status['exactAlarmsEnabled'] == true;
    final focus =
        _status['focusPermission'] == true &&
        _status['focusBusinessConfigured'] == true;
    return OrialisPageScaffold(
      title: '系统提醒与桌面',
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
              gap: 24,
              children: [
                OrialisSection(
                  title: '系统展示',
                  child: ContentStack(
                    children: [
                      OrialisListRow(
                        title: '开启提醒与桌面卡片',
                        subtitle: '将当前账户的任务和日程显示到系统；关闭后清除提醒和卡片内容',
                        trailing: LuminaSwitch(
                          value: system?.enabled ?? false,
                          onChanged: system == null || _busy
                              ? null
                              : (value) =>
                                    _run(() async => system.setEnabled(value)),
                        ),
                      ),
                      if (system?.enabled == true &&
                          !system!.identityCompatible)
                        const QuietLabel('请先登录。若已切换账户且本地数据归属尚未确认，系统展示会暂停。'),
                      const QuietLabel(
                        '任务需要截止日期、具体时间和提醒设置。日程按所设提前时间提醒；不会自动写入系统日历。',
                      ),
                    ],
                  ),
                ),
                OrialisSection(
                  title: '提醒',
                  child: ContentStack(
                    children: [
                      OrialisListRow(
                        title: '通知权限',
                        subtitle: notification ? '已允许' : '未允许，系统提醒暂不可见',
                        onTap: system == null || _busy
                            ? null
                            : () => _run(() async {
                                if (notification) {
                                  await system.openNotificationSettings();
                                } else {
                                  final allowed = await system
                                      .requestNotifications();
                                  if (allowed != true && context.mounted) {
                                    showLuminaMessage(
                                      context,
                                      '可在系统通知设置中允许 Orialis 提醒',
                                    );
                                    await system.openNotificationSettings();
                                  }
                                }
                              }),
                      ),
                      OrialisListRow(
                        title: '准时提醒',
                        subtitle: exact ? '已允许精确提醒' : '当前采用系统调度，省电模式可能延迟提醒',
                        onTap: system == null || _busy || exact
                            ? null
                            : () => _run(system.openExactAlarmSettings),
                      ),
                      LuminaButton(
                        primary: false,
                        onPressed:
                            system == null ||
                                _busy ||
                                !notification ||
                                !system.enabled ||
                                !system.identityCompatible
                            ? null
                            : () => _run(() async {
                                final sent = await system.previewReminder();
                                if (context.mounted) {
                                  showLuminaMessage(
                                    context,
                                    sent == true
                                        ? '测试提醒已发送，可查看通知栏'
                                        : '测试提醒未能发送',
                                  );
                                }
                              }),
                        child: const Text('发送测试提醒'),
                      ),
                    ],
                  ),
                ),
                OrialisSection(
                  title: '桌面卡片与快捷入口',
                  child: ContentStack(
                    children: [
                      const QuietLabel(
                        '今日卡片显示本地待办与日程，点击返回今日页。长按应用图标可直达今日、任务或日历。',
                      ),
                      LuminaButton(
                        primary: false,
                        onPressed:
                            system == null ||
                                _busy ||
                                !system.enabled ||
                                !system.identityCompatible
                            ? null
                            : () => _run(() async {
                                final requested = await system
                                    .requestPinWidget();
                                if (context.mounted) {
                                  showLuminaMessage(
                                    context,
                                    requested == true
                                        ? '请在桌面确认添加卡片'
                                        : '请长按桌面，在小部件中添加 Orialis 今日安排',
                                  );
                                }
                              }),
                        child: const Text('添加今日卡片'),
                      ),
                    ],
                  ),
                ),
                OrialisSection(
                  title: '小米超级岛',
                  child: QuietLabel(
                    focus
                        ? '已具备场景配置与系统权限。适用的日程提醒可显示超级岛，并在限定时间后结束。'
                        : '场景审核与调试配置完成后可启用；当前提醒使用普通通知。',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
