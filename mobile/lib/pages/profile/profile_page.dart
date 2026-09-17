import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:go_router/go_router.dart';

import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../../app/design/design_tokens.dart';
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
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('服务器地址'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://orialis.jxcz.top',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
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
  Widget build(BuildContext context) {
    return OrialisPageScaffold(
      title: '我的',
      subtitle: '账户、设备与同步',
      padding: EdgeInsets.zero,
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.page),
        children: [
          Text('Orialis', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 6),
          const Text(
            'V1 · Local-first',
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: AppSpacing.section),
          if (_loadingSession)
            const Card(
              child: ListTile(
                leading: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                title: Text('正在检查登录状态…'),
              ),
            )
          else if (_username == null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: const Text('未登录'),
                subtitle: const Text('登录后可在不同设备间同步你的数据'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openAuth,
              ),
            )
          else
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.person_outline),
                    ),
                    title: Text(_username!),
                    subtitle: const Text('已登录'),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _logout,
                        icon: const Icon(Icons.logout),
                        label: const Text('退出登录'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.section),
          Card(
            child: Column(
              children: [
                FutureBuilder(
                  future: _deviceId,
                  builder: (_, snapshot) => ListTile(
                    title: const Text('设备 ID'),
                    subtitle: Text(snapshot.data ?? '生成中…'),
                    leading: const Icon(Icons.devices_outlined),
                  ),
                ),
                ListTile(
                  title: const Text('服务器'),
                  subtitle: Text('$_serverUrl · $_serverState'),
                  leading: const Icon(Icons.cloud_outlined),
                  trailing: Chip(label: Text(_syncState.label)),
                  onTap: _editServerUrl,
                ),
                ListTile(
                  title: const Text('同步状态'),
                  subtitle: Text(_syncState.message),
                  leading: Icon(
                    _syncState == SyncState.conflict
                        ? Icons.shield_outlined
                        : Icons.sync,
                    color: _syncState == SyncState.conflict
                        ? AppColors.danger
                        : null,
                  ),
                ),
                ListTile(
                  title: const Text('项目'),
                  subtitle: const Text('项目、里程碑与关联任务'),
                  leading: const Icon(Icons.work_outline),
                  onTap: () => context.push('/projects'),
                ),
                if (_syncState == SyncState.conflict)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(
                      '你在本设备上的编辑仍在本地。再次同步前不会丢失这些修改。',
                      style: TextStyle(color: AppColors.danger),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: FilledButton.tonalIcon(
                    onPressed: () async {
                      setState(() => _syncState = SyncState.syncing);
                      final result = await ref
                          .read(syncCoordinatorProvider)
                          .requestSync();
                      if (mounted) {
                        setState(() {
                          _syncState = result;
                          _serverState = result == SyncState.offline
                              ? '无法连接'
                              : '在线';
                        });
                      }
                    },
                    icon: Icon(
                      _syncState == SyncState.syncing
                          ? Icons.hourglass_top
                          : Icons.sync,
                    ),
                    label: Text(
                      _syncState == SyncState.syncing ? '同步中…' : '检查并同步',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
      setState(() => _error = status == 409 ? '用户名已存在' : '登录信息不正确或服务器暂不可用');
    } catch (_) {
      setState(() => _error = '操作失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_register ? '注册 Orialis' : '登录 Orialis')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.page),
        children: [
          const SizedBox(height: 32),
          Text(
            _register ? '创建你的 Orialis 账户' : '欢迎回来',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            '账户用于安全地同步你的任务、日程和消息。',
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 28),
          TextField(
            controller: _usernameController,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: '用户名'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            obscureText: true,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(labelText: '密码'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: AppColors.danger)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: Text(_submitting ? '处理中…' : (_register ? '注册并登录' : '登录')),
          ),
          TextButton(
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
    );
  }
}
