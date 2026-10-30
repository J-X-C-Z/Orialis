import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:go_router/go_router.dart';

import '../../app/app.dart';
import '../../features/updates/presentation/github_updates_section.dart';
import 'legacy_recovery.dart';

import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show OrialisPageScaffold;

import '../shared/page_parts.dart';
import '../../core/config/app_config.dart';
import '../../core/network/orialis_api_client.dart';
import '../../core/network/unified_login.dart';
import '../../core/network/unified_login_fields.dart';
import '../../core/sync/sync_engine.dart';

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  late final Future<String> _deviceId;
  SyncState _syncState = SyncState.idle;
  String? _username;
  bool _loadingSession = true;
  String _serverUrl = AppConfig.defaultServerUrl;
  String _serverState = '检测中…';

  @override
  void initState() {
    super.initState();
    _deviceId = ref.read(appConfigProvider).deviceId();
    _loadServerUrl();
    _loadSession();
    _checkServer();
  }

  Future<OrialisApiClient> _api() async {
    final config = ref.read(appConfigProvider);
    return OrialisApiClient(
      baseUrl: await config.serverUrl(),
      deviceId: await _deviceId,
      config: config,
    );
  }

  Future<void> _loadServerUrl() async {
    final value = await ref.read(appConfigProvider).serverUrl();
    if (mounted) setState(() => _serverUrl = value);
  }

  Future<void> _loadSession() async {
    final config = ref.read(appConfigProvider);
    final token = await config.sessionToken();
    final cachedUsername = await config.sessionUsername();
    if (!mounted) return;
    if (token == null || token.isEmpty) {
      setState(() => _loadingSession = false);
      return;
    }
    try {
      final session = await (await _api()).session();
      if (mounted) {
        setState(() {
          _username = session['username'] as String;
          _loadingSession = false;
        });
      }
      await config.setSessionUsername(session['username'] as String);
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        await suspendDesktopSync(ref);
        await config.clearSessionToken();
        await config.clearSessionUsername();
        await reloadDesktopAccount(ref);
      }
      if (mounted) {
        setState(() {
          _username = error.response?.statusCode == 401 ? null : cachedUsername;
          _loadingSession = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _username = cachedUsername;
          _loadingSession = false;
        });
      }
    }
  }

  Future<void> _checkServer() async {
    try {
      await (await _api()).health();
      if (mounted) setState(() => _serverState = '在线');
    } on Object {
      if (mounted) setState(() => _serverState = '无法连接');
    }
  }

  Future<void> _logout() async {
    await suspendDesktopSync(ref);
    try {
      await (await _api()).logout();
    } catch (_) {
      // A local logout should still succeed when the server is unavailable.
      await ref.read(appConfigProvider).clearSessionToken();
    }
    await ref.read(appConfigProvider).clearSessionUsername();
    await reloadDesktopAccount(ref);
    if (mounted) setState(() => _username = null);
  }

  Future<void> _openAuth() async {
    final authenticated = await context.push<bool>('/auth');
    if (authenticated == true && mounted) {
      setState(() => _loadingSession = true);
      await _loadSession();
    }
  }

  Future<void> _editServerUrl() async {
    final controller = TextEditingController(text: _serverUrl);
    final value = await showLuminaDialog<String>(
      context: context,
      builder: (context) => LuminaDialog(
        title: '服务器地址',
        content: LuminaTextField(
          controller: controller,
          keyboardType: TextInputType.url,
          hint: 'https://orialis.jxcz.top',
        ),
        actions: [
          LuminaButton(
            primary: false,
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          LuminaButton(
            onPressed: () {
              final candidate = controller.text.trim();
              final uri = Uri.tryParse(candidate);
              if (uri == null ||
                  !{'http', 'https'}.contains(uri.scheme) ||
                  uri.host.isEmpty) {
                return;
              }
              Navigator.pop(
                context,
                candidate.replaceFirst(RegExp(r'\/$'), ''),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value == _serverUrl) return;
    await suspendDesktopSync(ref);
    if (ref.read(desktopModeProvider)) {
      await ref.read(appConfigProvider).clearSessionToken();
      await ref.read(appConfigProvider).clearSessionUsername();
    }
    await ref.read(appConfigProvider).setServerUrl(value);
    await reloadDesktopAccount(ref);
    if (!mounted) return;
    setState(() {
      _serverUrl = value;
      _serverState = '检测中…';
      if (ref.read(desktopModeProvider)) _username = null;
    });
    _checkServer();
  }

  @override
  Widget build(BuildContext context) => OrialisPageScaffold(
    padding: EdgeInsets.zero,
    title: '我的',
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
              const LegacyRecoveryNotice(allowOpen: true),
              LuminaSurface(
                child: ContentStack(
                  children: [
                    Row(
                      children: [
                        Image.asset(
                          'assets/branding/orialis-neumorphic.png',
                          width: 44,
                          height: 44,
                          excludeFromSemantics: true,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Orialis',
                            style: LuminaTheme.of(context)
                                .textTheme
                                .headlineMedium,
                          ),
                        ),
                      ],
                    ),
                    LuminaListRow(
                      title: _loadingSession ? '正在检查账户…' : _username ?? '未登录',
                      subtitle: _username == null ? '本地可用，登录后可跨设备同步' : '已登录',
                      leading: const LuminaIcon(LuminaIcons.person),
                      onTap: _loadingSession
                          ? null
                          : _username == null
                          ? _openAuth
                          : null,
                    ),
                  ],
                ),
              ),
              if (!ref.watch(desktopModeProvider))
                LuminaSection(
                  title: '常用功能',
                  child: ContentStack(
                    children: [
                      LuminaListRow(
                        title: '屏幕记忆',
                        subtitle: '快捷记录屏幕、Bilibili 链接与理解结果',
                        leading: const LuminaIcon(LuminaIcons.image),
                        trailing: const LuminaIcon(LuminaIcons.chevronRight),
                        onTap: () => context.push('/memory'),
                      ),
                      LuminaListRow(
                        title: '系统提醒与桌面',
                        subtitle: '任务提醒、今日卡片与小米超级岛',
                        leading: const LuminaIcon(LuminaIcons.devices),
                        trailing: const LuminaIcon(LuminaIcons.chevronRight),
                        onTap: () => context.push('/system'),
                      ),
                    ],
                  ),
                ),
              LuminaSection(
                title: '外观与体验',
                child: ContentStack(
                  children: [
                    const QuietLabel('外观'),
                    LuminaThemeModeSelector(
                      value: ref.watch(appearanceModeProvider),
                      systemLabel: '跟随系统',
                      lightLabel: '浅色',
                      darkLabel: '深色',
                      onChanged: (mode) async {
                        try {
                          await ref
                              .read(appearanceModeProvider.notifier)
                              .setMode(mode);
                        } catch (_) {
                          if (context.mounted) {
                            showLuminaMessage(context, '外观设置未能保存');
                          }
                        }
                      },
                    ),
                    LuminaListRow(
                      title: '高性能模式',
                      subtitle: '静态磨砂与柔和光影，优先保持滑动流畅',
                      trailing: LuminaSwitch(
                        value: ref.watch(highPerformanceModeProvider),
                        onChanged: (value) async {
                          try {
                            await ref
                                .read(highPerformanceModeProvider.notifier)
                                .setEnabled(value);
                          } catch (_) {
                            if (context.mounted) {
                              showLuminaMessage(context, '设置未能保存，请重试');
                            }
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
              LuminaSection(
                title: '设备与连接',
                child: ContentStack(
                  children: [
                    LuminaListRow(
                      title: '设备中心',
                      subtitle: '查看设备、切换当前设备并管理默认设备',
                      leading: const LuminaIcon(LuminaIcons.devices),
                      trailing: const LuminaIcon(LuminaIcons.chevronRight),
                      onTap: () => context.push('/devices'),
                    ),
                    if (!ref.watch(desktopModeProvider))
                      LuminaListRow(
                        title: '手环连接',
                        subtitle: '连接状态、互联权限与消息诊断',
                        leading: const LuminaIcon(LuminaIcons.devices),
                        trailing: const LuminaIcon(LuminaIcons.chevronRight),
                        onTap: () => context.push('/wear'),
                      ),
                    FutureBuilder<String>(
                      future: _deviceId,
                      builder: (_, s) => LuminaListRow(
                        title: '当前设备',
                        subtitle: s.data ?? '正在初始化…',
                        leading: const LuminaIcon(LuminaIcons.devices),
                      ),
                    ),
                  ],
                ),
              ),
              LuminaSection(
                title: '数据与同步',
                child: ContentStack(
                  children: [
                    LuminaListRow(
                      title: _syncState.label,
                      subtitle: _syncState.message,
                      leading: const LuminaIcon(LuminaIcons.sync),
                    ),
                    if (_syncState == SyncState.conflict)
                      const Text('本设备的修改仍保存在本地，请检查冲突后再同步。'),
                    LuminaButton(
                      onPressed: _syncState == SyncState.syncing
                          ? null
                          : () async {
                              setState(() => _syncState = SyncState.syncing);
                              final result = await ref
                                  .read(syncCoordinatorProvider)
                                  .requestSync();
                              if (mounted) {
                                setState(() {
                                  _syncState = result;
                                  _serverState = result == SyncState.offline
                                      ? '无法连接'
                                      : '已检查';
                                });
                              }
                            },
                      child: Text(
                        _syncState == SyncState.syncing ? '同步中…' : '检查并同步',
                      ),
                    ),
                    LuminaListRow(
                      title: '服务器',
                      subtitle: '$_serverUrl · $_serverState',
                      leading: const LuminaIcon(LuminaIcons.server),
                      trailing: const LuminaIcon(LuminaIcons.chevronRight),
                      onTap: _editServerUrl,
                    ),
                  ],
                ),
              ),
              if (_username != null)
                LuminaSection(
                  title: '账户',
                  child: LuminaListRow(
                    title: '退出登录',
                    leading: const LuminaIcon(LuminaIcons.person),
                    trailing: const LuminaIcon(LuminaIcons.chevronRight),
                    onTap: _logout,
                  ),
                ),
              const GithubUpdatesSection(),
              const QuietLabel('Lumina 光构'),
            ],
          ),
        ],
      ),
    ),
  );
}

class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key});

  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  UnifiedLogin? _login;
  bool _submitting = false;
  bool _needsTotp = false;
  String? _error;

  @override
  void dispose() {
    _login?.cancel();
    super.dispose();
  }

  Future<void> _submit(String username, String password, String? totp) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final config = ref.read(appConfigProvider);
    // Capture the app scope so a page disposed during account drain can resume it.
    final container = ProviderScope.containerOf(context, listen: false);
    var suspended = false;
    try {
      final server = await config.serverUrl();
      if (!mounted) return;
      final login = UnifiedLogin(baseUrl: server);
      _login = login;
      final result = await login.login(
        username: username,
        password: password,
        totp: totp,
        onConsent: (details) =>
            confirmUnifiedLoginConsent(context, details, login),
      );
      if (!mounted) return;
      if (await config.serverUrl() != server) {
        throw const FormatException('服务器已更改，请重试');
      }
      // Cancellation leaves the current account and sync running.
      suspended = true;
      await suspendDesktopSync(ref);
      if (!mounted) return;
      await config.setSessionToken(result.session.accessToken);
      await config.setSessionUsername(result.username);
      await reloadDesktopAccount(ref);
      suspended = false;
      if (mounted) context.pop(true);
    } on UnifiedLoginCancelled {
      // Cancellation is an ordinary exit; the primary button can retry.
    } on UnifiedLoginTotpRequired catch (error) {
      if (mounted) {
        setState(() {
          _needsTotp = true;
          _error = error.message;
        });
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '统一登录失败或超时，请重试');
      }
    } finally {
      if (suspended) {
        if (mounted) {
          await reloadDesktopAccount(ref);
        } else {
          final name = await config.desktopDatabaseName();
          container.read(desktopDatabaseNameProvider.notifier).state = name;
          container.invalidate(realtimeClientProvider);
          container.invalidate(syncEngineProvider);
          container.invalidate(syncCoordinatorProvider);
        }
      }
      _login = null;
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) => OrialisPageScaffold(
    padding: EdgeInsets.zero,
    title: '统一账号登录',
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
            gap: 20,
            children: [
              const SizedBox(height: 20),
              Text(
                '欢迎回来',
                style: LuminaTheme.of(context).textTheme.headlineMedium,
              ),
              QuietLabel(
                ref.watch(desktopModeProvider)
                    ? '同步任务、日程和项目。各账户本地内容分别保留。'
                    : '同步你的任务、日程和消息，本地内容始终保留。',
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(
                    color: LuminaTheme.of(context).colors.danger,
                  ),
                ),
              UnifiedLoginFields(
                onSubmit: _submit,
                busy: _submitting,
                needsTotp: _needsTotp,
              ),
              if (_submitting)
                LuminaButton(
                  primary: false,
                  onPressed: () => _login?.cancel(),
                  child: const Text('取消'),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}
