import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/design_components.dart';
import '../../pages/shared/page_parts.dart';
import 'wear_transport.dart';
import 'wear_providers.dart';

class WearConnectionPage extends ConsumerStatefulWidget {
  const WearConnectionPage({super.key});
  @override
  ConsumerState<WearConnectionPage> createState() => _WearConnectionPageState();
}

class _WearConnectionPageState extends ConsumerState<WearConnectionPage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(() {
      if (mounted) ref.read(wearConnectionProvider.notifier).refresh();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(wearConnectionProvider.notifier).refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(wearConnectionProvider);
    final manager = ref.read(wearConnectionProvider.notifier);
    final diagnostics = state.diagnostics;
    return OrialisPageScaffold(
      title: '手环连接',
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
                LuminaSurface(
                  child: ContentStack(
                    children: [
                      Text(
                        '小米手环',
                        style: LuminaTheme.of(context).textTheme.titleLarge,
                      ),
                      Text(switch (diagnostics.availability) {
                        WearAvailability.available => '连接服务已接入',
                        WearAvailability.sdkUnavailable =>
                          '连接支持暂不可用 · 缺少厂商 SDK',
                        WearAvailability.unsupported => '当前平台尚未支持手环连接',
                      }),
                      if (diagnostics.availability ==
                          WearAvailability.sdkUnavailable)
                        const QuietLabel(
                          '已准备连接管理与消息接口；取得授权 Xiaomi Wear SDK 后才能发现手环、授权和互联。',
                        ),
                    ],
                  ),
                ),
                OrialisSection(
                  title: '连接状态',
                  child: ContentStack(
                    children: [
                      _row('Phone · 手机与手环', _presence(state.phone)),
                      _row('Orialis · 服务', _presence(state.orialis)),
                      _row('Target · 执行设备', _presence(state.target)),
                      const QuietLabel('手环 Pong 只确认消息往返；执行设备状态须由独立服务确认。'),
                    ],
                  ),
                ),
                OrialisSection(
                  title: '连接诊断',
                  child: ContentStack(
                    children: [
                      _row('互联服务', _presence(diagnostics.serviceConnection)),
                      _row(
                        '发现的手环数量',
                        diagnostics.nodeCount?.toString() ?? '未知',
                      ),
                      _row('手环应用已安装', _boolean(diagnostics.wearAppInstalled)),
                      _row('互联权限', _boolean(diagnostics.permissionsGranted)),
                      _row('互联会话', diagnostics.session == null ? '未建立' : '已建立'),
                      if (state.error ?? diagnostics.lastError
                          case final String error)
                        Text(_errorLabel(error)),
                    ],
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    LuminaButton(
                      onPressed: state.busy ? null : manager.connect,
                      child: const Text('连接 / 重连'),
                    ),
                    LuminaButton(
                      primary: false,
                      onPressed: state.busy ? null : manager.refresh,
                      child: const Text('刷新状态'),
                    ),
                    LuminaButton(
                      primary: false,
                      onPressed:
                          state.busy ||
                              diagnostics.availability !=
                                  WearAvailability.available
                          ? null
                          : manager.requestPermissions,
                      child: const Text('请求互联权限'),
                    ),
                    LuminaButton(
                      primary: false,
                      onPressed: manager.revokeSession,
                      child: const Text('断开并撤销会话'),
                    ),
                  ],
                ),
                if (diagnostics.nodeIds.isEmpty)
                  const QuietLabel('尚未发现手环。请先在小米运动健康中连接手环，并保持其在后台运行。'),
                for (final node in diagnostics.nodeIds)
                  OrialisListRow(
                    title: node,
                    subtitle: node == state.selectedNode ? '当前连接手环' : '发现的手环',
                    onTap: state.busy ? null : () => manager.selectNode(node),
                  ),
                OrialisSection(
                  title: '同步到手环',
                  child: ContentStack(
                    children: [
                      const QuietLabel('今日、事件、日历、项目与我的的数据副本；不包含聊天、附件或凭据。'),
                      if (state.snapshot case final preview?) ...[
                        Text(preview.sourceLabel),
                        _row(
                          '任务',
                          '${preview.included['tasks']} / ${preview.total['tasks']}',
                        ),
                        _row(
                          '日程',
                          '${preview.included['schedules']} / ${preview.total['schedules']}',
                        ),
                        _row(
                          '项目',
                          '${preview.included['projects']} / ${preview.total['projects']}',
                        ),
                        _row(
                          '里程碑',
                          '${preview.included['milestones']} / ${preview.total['milestones']}',
                        ),
                        _row('快照大小', '${preview.bytes} / 16384 字节'),
                        _row('读取时间', preview.updatedAt.toLocal().toString()),
                        if (preview.truncated)
                          const QuietLabel('容量有限，当前为部分内容；未收入的记录没有删除或修改。'),
                      ] else
                        const QuietLabel('先刷新内容，再同步到手环。'),
                      if (state.snapshot != null &&
                          !state.snapshot!.accountScopeVerified)
                        const QuietLabel('当前为本地预览。请登录并连接服务，读取当前账户内容后再同步。'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          LuminaButton(
                            primary: false,
                            onPressed: state.busy
                                ? null
                                : manager.refreshSnapshot,
                            child: const Text('刷新内容'),
                          ),
                          LuminaButton(
                            onPressed:
                                state.busy ||
                                    state.snapshot?.accountScopeVerified !=
                                        true ||
                                    !diagnostics.canMessageFor(
                                      state.selectedNode,
                                    )
                                ? null
                                : manager.sendCurrentSnapshot,
                            child: const Text('同步到手环'),
                          ),
                        ],
                      ),
                      const QuietLabel('同步完成表示手环已保存内容，可离线查看；不会修改手机上的任务或日程。'),
                    ],
                  ),
                ),
                OrialisSection(
                  title: '消息诊断',
                  child: ContentStack(
                    children: [
                      Text(state.delivery),
                      LuminaButton(
                        primary: false,
                        onPressed: state.busy || state.selectedNode == null
                            ? null
                            : manager.openApp,
                        child: const Text('打开手环应用'),
                      ),
                      LuminaButton(
                        onPressed:
                            state.busy ||
                                !diagnostics.canMessageFor(
                                  state.selectedNode,
                                ) ||
                                state.selectedNode == null
                            ? null
                            : manager.ping,
                        child: const Text('检查消息连接'),
                      ),
                      const QuietLabel('断开、换账户或换手环后需要重新连接和同步。'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) =>
      OrialisListRow(title: label, subtitle: value);
  String _presence(WearPresence value) => switch (value) {
    WearPresence.online => '在线',
    WearPresence.offline => '离线',
    WearPresence.unknown => '未知',
  };
  String _boolean(bool? value) => value == null
      ? '未知'
      : value
      ? '是'
      : '否';
  String _errorLabel(String code) => switch (code) {
    'sdk_unavailable' => '缺少授权 Xiaomi Wear SDK，尚不能建立连接。',
    'unsupported' => '当前平台尚未支持手环连接。',
    'response_timeout' => '等待手环响应超时，请检查连接后重试。',
    'connection_not_ready' => '手环、应用安装、权限和会话尚未全部就绪。',
    'account_scope_unverified' => '尚不能确认本地数据的账户归属，不能发送。',
    'snapshot_read_failed' => '未能读取内容快照，请刷新重试。',
    'session_changed' ||
    'session_revoked' ||
    'target_changed' => '连接作用域已改变，请重新连接。',
    _ => '连接异常：$code',
  };
}
