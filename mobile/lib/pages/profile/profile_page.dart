import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:go_router/go_router.dart';

import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../shared/page_parts.dart';
import '../../core/config/app_config.dart';
import '../../core/network/orialis_api_client.dart';
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
        await config.clearSessionToken();
        await config.clearSessionUsername();
      }
      if (mounted) {
        setState(() {
          _username = cachedUsername;
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
    try {
      await (await _api()).logout();
    } catch (_) {
      // A local logout should still succeed when the server is unavailable.
      await ref.read(appConfigProvider).clearSessionToken();
    }
    await ref.read(appConfigProvider).clearSessionUsername();
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
    await ref.read(appConfigProvider).setServerUrl(value);
    if (!mounted) return;
    setState(() {
      _serverUrl = value;
      _serverState = '检测中…';
    });
    _checkServer();
  }

  @override
  Widget build(BuildContext context) => OrialisPageScaffold(
    title: '我的',
    body: ListView(
      children: [
        ContentStack(
          gap: 24,
          children: [
            LuminaSurface(
              child: ContentStack(
                children: [
                  Text(
                    'Orialis',
                    style: LuminaTheme.of(context).textTheme.headlineMedium,
                  ),
                  const QuietLabel('留住想法，安排生活。'),
                  OrialisListRow(
                    title: _loadingSession ? '正在检查账户…' : _username ?? '未登录',
                    subtitle: _username == null ? '本地可用，登录后可跨设备同步' : '已登录',
                    leading: const LuminaIcon(LuminaIcons.person),
                    onTap: _loadingSession
                        ? null
                        : _username == null
                        ? _openAuth
                        : null,
                  ),
                  if (_username != null)
                    LuminaButton(
                      primary: false,
                      onPressed: _logout,
                      child: const Text('退出登录'),
                    ),
                ],
              ),
            ),
            OrialisSection(
              title: '连接与同步',
              child: ContentStack(
                children: [
                  OrialisListRow(
                    title: '服务器',
                    subtitle: '$_serverUrl · $_serverState',
                    leading: const LuminaIcon(LuminaIcons.server),
                    trailing: const LuminaIcon(LuminaIcons.chevronRight),
                    onTap: _editServerUrl,
                  ),
                  OrialisListRow(
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
                ],
              ),
            ),
            FutureBuilder<String>(
              future: _deviceId,
              builder: (_, s) => OrialisListRow(
                title: '当前设备',
                subtitle: s.data ?? '正在初始化…',
                leading: const LuminaIcon(LuminaIcons.devices),
              ),
            ),
            const QuietLabel('外观跟随系统 · Lumina 光构'),
          ],
        ),
      ],
    ),
  );
}

class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key});

  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _register = false;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.length < 3 || password.length < 8) {
      setState(() => _error = '用户名至少 3 个字符，密码至少 8 个字符');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final config = ref.read(appConfigProvider);
      final api = OrialisApiClient(
        baseUrl: await config.serverUrl(),
        deviceId: await config.deviceId(),
        config: config,
      );
      if (_register) {
        await api.register(username: username, password: password);
      } else {
        await api.login(username: username, password: password);
      }
      await config.setSessionUsername(username);
      if (mounted) context.pop(true);
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (mounted) {
        setState(() => _error = status == 409 ? '用户名已存在' : '登录信息不正确或服务器暂不可用');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '操作失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) => OrialisPageScaffold(
    title: _register ? '注册账户' : '登录账户',
    leading: LuminaIconButton(
      tooltip: '返回',
      icon: const LuminaIcon(LuminaIcons.back),
      onPressed: () => context.pop(),
    ),
    body: ListView(
      children: [
        ContentStack(
          gap: 20,
          children: [
            const SizedBox(height: 20),
            Text(
              _register ? '从这里开始' : '欢迎回来',
              style: LuminaTheme.of(context).textTheme.headlineMedium,
            ),
            const QuietLabel('同步你的任务、日程和消息，本地内容始终保留。'),
            LuminaTextField(
              controller: _usernameController,
              label: '用户名',
              textInputAction: TextInputAction.next,
            ),
            LuminaTextField(
              controller: _passwordController,
              label: '密码',
              obscureText: true,
              onSubmitted: (_) {
                if (!_submitting) _submit();
              },
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: LuminaTheme.of(context).colors.danger),
              ),
            LuminaButton(
              onPressed: _submitting ? null : _submit,
              child: Text(
                _submitting
                    ? '处理中…'
                    : _register
                    ? '注册并登录'
                    : '登录',
              ),
            ),
            LuminaButton(
              primary: false,
              onPressed: _submitting
                  ? null
                  : () => setState(() {
                      _register = !_register;
                      _error = null;
                    }),
              child: Text(_register ? '已有账户？去登录' : '还没有账户？去注册'),
            ),
          ],
        ),
      ],
    ),
  );
}
