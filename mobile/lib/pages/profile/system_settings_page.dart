import '../../features/calendar_sync/calendar_sync_settings.dart';

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app.dart';
import '../../features/chat/domain/chat_transcript.dart';
import '../../features/system_integration/system_widget_catalog.dart';

import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show OrialisPageScaffold;

import '../chat/chat_page.dart' show agentChatServiceProvider;
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

  int? get _widgetCount {
    final value = _status['widgetCount'];
    return value is num ? value.toInt() : int.tryParse('$value');
  }

  bool? get _pinWidgetSupported => switch (_status['pinWidgetSupported']) {
    final bool value => value,
    _ => null,
  };

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
    if (mounted) setState(() => _busy = true);
    try {
      final system = ref.read(systemIntegrationProvider);
      Map<Object?, Object?> status = const {};
      if (system != null) {
        await system.start();
        await system.refresh();
        status = await system.status() ?? const {};
      }
      if (mounted) setState(() => _status = status);
    } catch (_) {
      if (mounted) setState(() => _status = const {});
    } finally {
      if (mounted) setState(() => _busy = false);
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

  Future<bool> _previewChatNotification() async {
    final system = ref.read(systemIntegrationProvider);
    if (system == null) return false;
    final repository = ref.read(chatRepositoryProvider);
    final service = ref.read(agentChatServiceProvider);
    final conversations = await repository.watchConversations().first;
    for (final conversation in conversations) {
      final target = await service.target(conversation.id);
      if (!service.isAllowedTarget(target)) continue;
      final messages = (await repository.watchMessages(conversation.id).first)
          .where(
            (message) =>
                message.role == 'assistant' && isVisibleChatMessage(message),
          )
          .toList();
      if (messages.isEmpty) continue;
      return system.notifyChatMessage({
        'notificationId': 'test-${DateTime.now().microsecondsSinceEpoch}',
        'messageId': messages.last.id,
        'conversationId': conversation.id,
        'role': 'assistant',
        'sender': 'Orialis 测试消息',
        'content': messages.last.content,
        'createdAt': messages.last.createdAt,
        'replyToMessageId': messages.last.replyToMessageId,
      }, testEvent: true);
    }
    if (mounted) {
      showLuminaMessage(context, '请先在 Mac 或 Azure 的 Hermes 会话中产生一条消息');
    }
    return false;
  }

  Future<void> _requestWidget(SystemWidgetDefinition widget) async {
    final system = ref.read(systemIntegrationProvider);
    if (system == null || !system.supported || _busy) return;
    await _run(() async {
      final requested = await system.requestPinWidget(kind: widget.kind);
      if (!mounted) return;
      showLuminaMessage(
        context,
        requested == true
            ? '请在桌面确认添加${widget.title}（${widget.size}）'
            : '未能打开一键添加。请长按桌面 → 小部件 → Android小组件/全部小组件 → Orialis，再选择${widget.title}（${widget.size}）。小米/HyperOS 的入口名称可能略有不同。',
      );
    });
  }

  LuminaIcons _iconForGroup(SystemWidgetGroup group) => switch (group.title) {
    '今日' => LuminaIcons.today,
    '任务' => LuminaIcons.tasks,
    '日程' => LuminaIcons.calendar,
    _ => LuminaIcons.sparkles,
  };

  @override
  Widget build(BuildContext context) {
    final system = ref.watch(systemIntegrationProvider);
    final notification = _status['notificationsEnabled'] == true;
    final exact = _status['exactAlarmsEnabled'] == true;
    final androidSupported = system?.supported == true;
    final pinWidgetSupported = _pinWidgetSupported;
    final widgetCount = _widgetCount;
    final canPin = androidSupported && !_busy && pinWidgetSupported != false;
    final focus =
        _status['focusPermission'] == true &&
        _status['focusBusinessConfigured'] == true;
    return OrialisPageScaffold(
      padding: EdgeInsets.zero,
      title: '系统提醒与小组件',
      leading: LuminaIconButton(
        tooltip: '返回',
        icon: const LuminaIcon(LuminaIcons.back),
        onPressed: () => context.pop(),
      ),
      body: Builder(
        builder: (context) => ListView(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: LuminaPageHeaderInset.of(context) + 12,
            bottom: MediaQuery.paddingOf(context).bottom + 24,
          ),
          children: [
            ContentStack(
              gap: 24,
              children: [
                const CalendarSyncSettings(),
                LuminaSection(
                  title: '系统展示',
                  child: ContentStack(
                    children: [
                      LuminaListRow(
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
                        '任务需要截止日期、具体时间和提醒设置。日程按所设提前时间提醒；系统日历同步可在上方单独启用。',
                      ),
                    ],
                  ),
                ),
                LuminaSection(
                  title: '提醒',
                  child: ContentStack(
                    children: [
                      LuminaListRow(
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
                      LuminaListRow(
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
                                final sent = await _previewChatNotification();
                                if (context.mounted) {
                                  showLuminaMessage(
                                    context,
                                    sent ? '测试聊天通知已发送，点击可打开会话消息' : '测试聊天通知未能发送',
                                  );
                                }
                              }),
                        child: const Text('发送测试聊天通知'),
                      ),
                    ],
                  ),
                ),
                LuminaSection(
                  title: '桌面小组件',
                  child: ContentStack(
                    children: [
                      LuminaListRow(
                        title: '已添加小组件',
                        subtitle: _busy
                            ? '正在读取系统状态…'
                            : widgetCount == null
                            ? '暂时无法读取，返回此页可重试'
                            : '当前桌面已添加 $widgetCount 个 Orialis 小组件',
                        trailing: Text(
                          _busy ? '读取中' : '${widgetCount ?? '—'}',
                          style: LuminaTheme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      LuminaListRow(
                        title: '应用内固定',
                        subtitle: _busy
                            ? '正在确认系统固定能力…'
                            : !androidSupported
                            ? '当前平台不支持 Android 桌面小组件'
                            : pinWidgetSupported == null
                            ? '也可在桌面的小部件列表中手动添加'
                            : pinWidgetSupported
                            ? '支持一键打开系统的固定流程'
                            : '不支持一键固定，请按下方步骤手动添加',
                        trailing: _StatusBadge(
                          label: _busy
                              ? '读取中'
                              : !androidSupported
                              ? '不支持'
                              : pinWidgetSupported == null
                              ? '未知'
                              : pinWidgetSupported
                              ? '支持'
                              : '手动',
                          available:
                              androidSupported && pinWidgetSupported != false,
                        ),
                      ),
                      if (androidSupported &&
                          !_busy &&
                          pinWidgetSupported == false)
                        const QuietLabel(
                          '长按桌面 → 小部件 → Android小组件/全部小组件 → Orialis，再选择需要的尺寸。小米/HyperOS 的入口名称可能略有不同。',
                        )
                      else
                        const QuietLabel(
                          '可先添加到桌面。登录并开启系统展示后，即可显示你的任务和日程；快捷入口无需登录。',
                        ),
                    ],
                  ),
                ),
                for (final group in systemWidgetCatalog)
                  LuminaSection(
                    title: group.title,
                    trailing: Text(
                      '${group.widgets.length} 款',
                      style: LuminaTheme.of(context).textTheme.bodySmall,
                    ),
                    child: ContentStack(
                      children: [
                        QuietLabel(group.description),
                        for (final widget in group.widgets)
                          LuminaListRow(
                            title: widget.title,
                            subtitle: widget.description,
                            detail: Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: _WidgetSizeBadge(widget.size),
                            ),
                            leading: LuminaIcon(_iconForGroup(group)),
                            trailing: LuminaIconButton(
                              tooltip: '添加${widget.title} ${widget.size} 小组件',
                              icon: const LuminaIcon(LuminaIcons.add),
                              onPressed: canPin
                                  ? () => _requestWidget(widget)
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  ),
                LuminaSection(
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

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.available});

  final String label;
  final bool available;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    return LuminaSurface(
      color: available ? theme.colors.accentSoft : theme.colors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Text(label, style: theme.textTheme.labelMedium),
    );
  }
}

class _WidgetSizeBadge extends StatelessWidget {
  const _WidgetSizeBadge(this.size);

  final String size;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    return LuminaSurface(
      color: theme.colors.accentSoft,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Text(size, style: theme.textTheme.labelMedium),
    );
  }
}
