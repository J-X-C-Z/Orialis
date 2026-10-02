import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/design/lumina_compat.dart';
import '../core/config/app_config.dart';
import '../core/network/orialis_api_client.dart';
import 'news_data.dart';
import 'news_pages.dart';

final newsAppearanceProvider =
    StateNotifierProvider<_NewsAppearanceController, ThemeMode>(
      (ref) => _NewsAppearanceController(ref.watch(newsConfigProvider)),
    );

class _NewsAppearanceController extends StateNotifier<ThemeMode> {
  _NewsAppearanceController(this.config) : super(ThemeMode.system) {
    _load();
  }
  final AppConfig config;

  Future<void> _load() async {
    final saved = await config.appearanceMode();
    state = ThemeMode.values.firstWhere(
      (mode) => mode.name == saved,
      orElse: () => ThemeMode.system,
    );
  }

  Future<void> setMode(ThemeMode mode) async {
    state = mode;
    await config.setAppearanceMode(mode.name);
  }
}

class OrialisNewsApp extends ConsumerWidget {
  const OrialisNewsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(newsAppearanceProvider);
    final brightness = switch (mode) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness,
    };
    return LuminaTheme(
      brightness: brightness,
      data: const LuminaThemeData(),
      child: MaterialApp(
        title: 'Orialis 资讯',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
        darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        themeMode: mode,
        builder: (context, child) => Material(
          color: LuminaTheme.of(context).colors.paper,
          child: child ?? const SizedBox.shrink(),
        ),
        home: const NewsHomePage(),
      ),
    );
  }
}

class NewsHomePage extends StatefulWidget {
  const NewsHomePage({super.key});

  @override
  State<NewsHomePage> createState() => _NewsHomePageState();
}

enum DesktopNewsSection { aiHot, github, project }

class DesktopNewsPage extends StatefulWidget {
  const DesktopNewsPage({required this.section, super.key});
  final DesktopNewsSection section;

  @override
  State<DesktopNewsPage> createState() => _DesktopNewsPageState();
}

class _DesktopNewsPageState extends State<DesktopNewsPage> {
  int _refreshGeneration = 0;

  @override
  Widget build(BuildContext context) => LuminaPageScaffold(
    title: switch (widget.section) {
      DesktopNewsSection.aiHot => 'AI Hot',
      DesktopNewsSection.github => 'GitHub',
      DesktopNewsSection.project => 'Project',
    },
    leading: const _NewsBrandLogo(),
    actions: [
      IconButton(
        tooltip: '刷新',
        onPressed: () => setState(() => _refreshGeneration++),
        icon: const Icon(Icons.refresh_rounded),
      ),
    ],
    body: KeyedSubtree(
      key: ValueKey(_refreshGeneration),
      child: switch (widget.section) {
        DesktopNewsSection.aiHot => const AihotPage(),
        DesktopNewsSection.github => const GithubPage(),
        DesktopNewsSection.project => const ProjectsNewsPage(),
      },
    ),
  );
}

class _NewsHomePageState extends State<NewsHomePage> {
  int _selected = 0;
  int _refreshGeneration = 0;

  @override
  Widget build(BuildContext context) => Localizations.override(
    context: context,
    delegates: GlobalMaterialLocalizations.delegates,
    child: LuminaPageScaffold(
      title: 'Orialis 资讯',
      leading: const _NewsBrandLogo(),
      subtitle: const [
        'AI 世界今天发生了什么？',
        '开源世界今天有什么值得关注？',
        '我的项目今天发生了什么？',
      ][_selected],
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: () => setState(() => _refreshGeneration++),
          icon: const Icon(Icons.refresh_rounded),
        ),
        IconButton(
          tooltip: '账号与服务地址',
          onPressed: DesktopLayoutScope.of(context)
              ? () => context.go('/profile')
              : () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const NewsAccountPage(),
                    ),
                  );
                  if (mounted) setState(() => _refreshGeneration++);
                },
          icon: const Icon(Icons.account_circle_outlined),
        ),
      ],
      body: LayoutBuilder(
        builder: (context, constraints) {
          final destinations = _newsDestinations;
          final pages = IndexedStack(
            index: _selected,
            key: ValueKey(_refreshGeneration),
            children: const [AihotPage(), GithubPage(), ProjectsNewsPage()],
          );
          if (constraints.maxWidth >= 840) {
            return Row(
              children: [
                LuminaNavigationRail(
                  destinations: destinations
                      .map(
                        (destination) => NavigationRailDestination(
                          icon: destination.icon,
                          selectedIcon: destination.selectedIcon,
                          label: Text(destination.label),
                        ),
                      )
                      .toList(),
                  selectedIndex: _selected,
                  onDestinationSelected: (value) =>
                      setState(() => _selected = value),
                  extended: true,
                ),
                const SizedBox(width: 18),
                Expanded(child: pages),
              ],
            );
          }
          if (DesktopLayoutScope.of(context)) {
            return Column(
              children: [
                Expanded(child: pages),
                _NewsNavigation(
                  selected: _selected,
                  onSelected: (value) => setState(() => _selected = value),
                ),
              ],
            );
          }
          return pages;
        },
      ),
      bottomActions:
          DesktopLayoutScope.of(context) ||
              MediaQuery.sizeOf(context).width >= 840
          ? null
          : _NewsNavigation(
              selected: _selected,
              onSelected: (value) => setState(() => _selected = value),
            ),
    ),
  );
}

const _newsDestinations = <NavigationDestination>[
  NavigationDestination(
    icon: Icon(Icons.auto_awesome_outlined),
    selectedIcon: Icon(Icons.auto_awesome_rounded),
    label: 'AIHOT',
  ),
  NavigationDestination(
    icon: Icon(Icons.code_outlined),
    selectedIcon: Icon(Icons.code_rounded),
    label: 'GitHub',
  ),
  NavigationDestination(
    icon: Icon(Icons.work_outline_rounded),
    selectedIcon: Icon(Icons.work_rounded),
    label: 'Projects',
  ),
];

class NewsAccountPage extends ConsumerStatefulWidget {
  const NewsAccountPage({super.key});
  @override
  ConsumerState<NewsAccountPage> createState() => _NewsAccountPageState();
}

class _NewsAccountPageState extends ConsumerState<NewsAccountPage> {
  final _serverController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _ready = false;
  bool _busy = false;
  String? _error;
  String? _serverError;
  String? _username;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = ref.read(newsConfigProvider);
    final server = await config.serverUrl();
    final username = await config.sessionUsername();
    final token = await config.sessionToken();
    if (!mounted) return;
    setState(() {
      _serverController.text = server;
      _username = token == null ? null : username;
      _ready = true;
    });
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final config = ref.read(newsConfigProvider);
      final url = _validatedServerUrl(_serverController.text);
      await config.setServerUrl(url);
      final client = OrialisApiClient(
        baseUrl: url,
        deviceId: await config.deviceId(),
        config: config,
      );
      await client.login(
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      );
      await config.setSessionUsername(_usernameController.text.trim());
      if (!mounted) return;
      setState(() {
        _username = _usernameController.text.trim();
        _passwordController.clear();
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('登录成功')));
    } catch (error) {
      if (mounted) setState(() => _error = _authError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    final config = ref.read(newsConfigProvider);
    await config.clearSessionToken();
    await config.clearSessionUsername();
    if (mounted) setState(() => _username = null);
  }

  Future<void> _saveServerAddress() async {
    final config = ref.read(newsConfigProvider);
    late final String next;
    try {
      next = _validatedServerUrl(_serverController.text);
    } on FormatException catch (error) {
      setState(() => _serverError = error.message);
      return;
    }
    final current = await config.serverUrl();
    if (current != next && await config.sessionToken() != null) {
      await config.clearSessionToken();
      await config.clearSessionUsername();
      if (mounted) setState(() => _username = null);
    }
    await config.setServerUrl(next);
    if (mounted) {
      setState(() {
        _serverController.text = next;
        _serverError = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('服务地址已保存')));
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LuminaPageScaffold(
    title: '账号与服务',
    leading: IconButton(
      tooltip: '返回',
      onPressed: () => Navigator.of(context).maybePop(),
      icon: const Icon(Icons.arrow_back_rounded),
    ),
    body: !_ready
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: EdgeInsets.only(
              top: LuminaPageHeaderInset.of(context) + 12,
              bottom: 24,
            ),
            children: [
              LuminaSection(
                title: 'Orialis 服务',
                trailing: const _NewsBrandLogo(size: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    TextField(
                      key: const ValueKey('news-server-url'),
                      controller: _serverController,
                      keyboardType: TextInputType.url,
                      onChanged: (_) {
                        if (_serverError != null) {
                          setState(() => _serverError = null);
                        }
                      },
                      decoration: const InputDecoration(
                        labelText: '服务地址',
                        hintText: 'https://orialis.example.com',
                      ),
                    ),
                    if (_serverError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          _serverError!,
                          style: TextStyle(
                            color: LuminaTheme.of(context).colors.danger,
                          ),
                        ),
                      ),
                    TextButton(
                      onPressed: _busy ? null : _saveServerAddress,
                      child: const Text('保存服务地址'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              LuminaSection(
                title: '外观',
                child: LuminaThemeModeSelector(
                  value: ref.watch(newsAppearanceProvider),
                  onChanged: (mode) =>
                      ref.read(newsAppearanceProvider.notifier).setMode(mode),
                ),
              ),
              const SizedBox(height: 18),
              LuminaSection(
                title: '登录状态',
                child: _username == null
                    ? Column(
                        children: [
                          TextField(
                            controller: _usernameController,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(labelText: '用户名'),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _passwordController,
                            obscureText: true,
                            onSubmitted: (_) => _busy ? null : _login(),
                            decoration: const InputDecoration(labelText: '密码'),
                          ),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  color: LuminaTheme.of(context).colors.danger,
                                ),
                              ),
                            ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.icon(
                              onPressed: _busy ? null : _login,
                              icon: _busy
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.login_rounded),
                              label: const Text('登录'),
                            ),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('已登录为 $_username'),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _logout,
                            icon: const Icon(Icons.logout_rounded),
                            label: const Text('退出登录'),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 12),
              Text(
                '项目报告按登录账号隔离。更换账号后，资讯缓存也会按账号分开。',
                style: LuminaTheme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
  );
}

String _authError(Object error) {
  if (error is FormatException) return error.message;
  if (error is Exception) return '登录失败，请检查服务地址、账号和网络后重试。';
  return error.toString();
}

String _validatedServerUrl(String value) {
  final candidate = value.trim();
  final uri = Uri.tryParse(candidate);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
      uri.host.isEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('请输入有效的 HTTP(S) 服务地址');
  }
  return candidate.replaceFirst(RegExp(r'/+$'), '');
}

class _NewsBrandLogo extends StatelessWidget {
  const _NewsBrandLogo({this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/branding/orialis-news.png',
    width: size,
    height: size,
    semanticLabel: 'Orialis News',
  );
}

class _NewsNavigation extends StatelessWidget {
  const _NewsNavigation({required this.selected, required this.onSelected});
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => LuminaNavigationBar(
    destinations: _newsDestinations,
    selectedIndex: selected,
    onDestinationSelected: onSelected,
  );
}
