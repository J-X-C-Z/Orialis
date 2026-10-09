import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show DesktopLayoutScope, OrialisPageScaffold;
import '../core/config/app_config.dart';
import '../core/network/orialis_api_client.dart';
import '../pages/shared/mobile_navigation.dart';
import 'news_data.dart';
import 'news_pages.dart';
import 'news_motion.dart';

final newsAppearanceProvider =
    StateNotifierProvider<_NewsAppearanceController, ThemeMode>(
      (ref) => _NewsAppearanceController(ref.watch(newsConfigProvider)),
    );

final newsHighPerformanceModeProvider =
    StateNotifierProvider<_NewsHighPerformanceModeController, bool>(
      (ref) =>
          _NewsHighPerformanceModeController(ref.watch(newsConfigProvider)),
    );

class _NewsHighPerformanceModeController extends StateNotifier<bool> {
  _NewsHighPerformanceModeController(this.config) : super(true) {
    _load();
  }

  final AppConfig config;
  int _revision = 0;

  Future<void> _load() async {
    final saved = await config.highPerformanceMode();
    if (mounted && _revision == 0) state = saved;
  }

  Future<void> setEnabled(bool value) async {
    final previous = state;
    final revision = ++_revision;
    state = value;
    try {
      await config.setHighPerformanceMode(value);
    } catch (_) {
      if (mounted && revision == _revision) state = previous;
      rethrow;
    }
  }
}

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
      highPerformanceMode: ref.watch(newsHighPerformanceModeProvider),
      data: const LuminaThemeData(),
      child: MaterialApp(
        title: 'Orialis 资讯',
        debugShowCheckedModeBanner: false,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
        themeMode: mode,
        builder: (context, child) => LuminaMaterialBridge(
          child: DefaultTextStyle(
            style: LuminaTheme.of(context).textTheme.bodyMedium,
            child: IconTheme(
              data: IconThemeData(color: LuminaTheme.of(context).colors.muted),
              child: AnnotatedRegion<SystemUiOverlayStyle>(
                value: brightness == Brightness.dark
                    ? SystemUiOverlayStyle.light
                    : SystemUiOverlayStyle.dark,
                child: Material(
                  color: LuminaTheme.of(context).colors.paper,
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            ),
          ),
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
      LuminaIconButton(
        tooltip: '刷新',
        onPressed: () => setState(() => _refreshGeneration++),
        icon: const Icon(Icons.refresh_rounded),
      ),
    ],
    body: NewsRefreshScope(
      generation: _refreshGeneration,
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
  final _refreshGenerations = [0, 0, 0];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final desktop = DesktopLayoutScope.of(context);
    final page = OrialisPageScaffold(
      title: const ['AI 热点', 'GitHub', '项目资讯'][_selected],
      leading: wide || desktop
          ? const _NewsBrandLogo()
          : LuminaIconButton(
              tooltip: '刷新',
              onPressed: () => setState(() => _refreshGenerations[_selected]++),
              icon: const LuminaIcon(LuminaIcons.sync),
            ),
      actions: [
        if (wide || desktop)
          LuminaIconButton(
            tooltip: '刷新',
            onPressed: () => setState(() => _refreshGenerations[_selected]++),
            icon: const LuminaIcon(LuminaIcons.sync),
          ),
        LuminaIconButton(
          tooltip: '账号与服务地址',
          onPressed: desktop
              ? () => context.go('/profile')
              : () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const NewsAccountPage(),
                    ),
                  );
                },
          icon: const LuminaIcon(LuminaIcons.person),
        ),
      ],
      body: Builder(
        builder: (context) {
          final pages = LuminaBranchTransition(
            index: _selected,
            children: [
              for (var i = 0; i < 3; i++)
                NewsRefreshScope(
                  generation: _refreshGenerations[i],
                  child: const [
                    AihotPage(),
                    GithubPage(),
                    ProjectsNewsPage(),
                  ][i],
                ),
            ],
          );
          if (wide) {
            return Row(
              children: [
                LuminaNavigationRail(
                  destinations: _newsDestinations(context)
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
          if (desktop) {
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
    );
    if (wide || desktop) return page;
    return OrialisMobileNavigationOverlay(
      destinations: _newsDestinations(context),
      selectedIndex: _selected,
      onDestinationSelected: (value) => setState(() => _selected = value),
      child: page,
    );
  }
}

List<NavigationDestination> _newsDestinations(BuildContext context) {
  final colors = LuminaTheme.of(context).colors;
  const labels = ['AI 热点', 'GitHub', '项目'];
  const icons = [
    LuminaIcons.sparkles,
    LuminaIcons.terminal,
    LuminaIcons.folder,
  ];
  return [
    for (var i = 0; i < labels.length; i++)
      NavigationDestination(
        icon: LuminaIcon(icons[i], color: colors.muted),
        selectedIcon: LuminaIcon(icons[i], color: colors.accent),
        label: labels[i],
      ),
  ];
}

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
      showLuminaMessage(context, '登录成功');
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
      showLuminaMessage(context, '服务地址已保存');
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
    leading: LuminaIconButton(
      tooltip: '返回',
      onPressed: () => Navigator.of(context).maybePop(),
      icon: const LuminaIcon(LuminaIcons.back),
    ),
    body: Builder(
      builder: (context) => !_ready
          ? const Center(child: LuminaProgress())
          : ListView(
              padding: EdgeInsets.only(
                top: LuminaPageHeaderInset.of(context) + 12,
                bottom:
                    MediaQuery.viewInsetsOf(context).bottom +
                    MediaQuery.paddingOf(context).bottom +
                    24,
              ),
              children: [
                LuminaSection(
                  title: 'Orialis 服务',
                  trailing: const _NewsBrandLogo(size: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      LuminaTextField(
                        key: const ValueKey('news-server-url'),
                        controller: _serverController,
                        keyboardType: TextInputType.url,
                        onChanged: (_) {
                          if (_serverError != null) {
                            setState(() => _serverError = null);
                          }
                        },
                        label: '服务地址',
                        hint: 'https://orialis.example.com',
                        enabled: !_busy,
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
                      LuminaButton(
                        primary: false,
                        onPressed: _busy ? null : _saveServerAddress,
                        child: const Text('保存服务地址'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                LuminaSection(
                  title: '外观',
                  child: Column(
                    children: [
                      LuminaThemeModeSelector(
                        value: ref.watch(newsAppearanceProvider),
                        onChanged: (mode) => ref
                            .read(newsAppearanceProvider.notifier)
                            .setMode(mode),
                      ),
                      const SizedBox(height: 12),
                      LuminaListRow(
                        title: '高性能模式',
                        subtitle: '优先流畅滚动，关闭后使用更细腻的阴影效果',
                        trailing: LuminaSwitch(
                          key: const ValueKey('news-high-performance-mode'),
                          value: ref.watch(newsHighPerformanceModeProvider),
                          onChanged: (value) async {
                            try {
                              await ref
                                  .read(
                                    newsHighPerformanceModeProvider.notifier,
                                  )
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
                const SizedBox(height: 18),
                LuminaSection(
                  title: '登录状态',
                  child: _username == null
                      ? Column(
                          children: [
                            LuminaTextField(
                              controller: _usernameController,
                              textInputAction: TextInputAction.next,
                              label: '用户名',
                              enabled: !_busy,
                            ),
                            const SizedBox(height: 10),
                            LuminaTextField(
                              controller: _passwordController,
                              obscureText: true,
                              onSubmitted: (_) => _busy ? null : _login(),
                              label: '密码',
                              enabled: !_busy,
                              textInputAction: TextInputAction.done,
                            ),
                            if (_error != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  _error!,
                                  style: TextStyle(
                                    color: LuminaTheme.of(
                                      context,
                                    ).colors.danger,
                                  ),
                                ),
                              ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: LuminaButton(
                                onPressed: _busy ? null : _login,
                                icon: _busy
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: LuminaProgress(),
                                      )
                                    : const Icon(Icons.login_rounded),
                                child: const Text('登录'),
                              ),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('已登录为 $_username'),
                            const SizedBox(height: 12),
                            LuminaButton(
                              primary: false,
                              onPressed: _logout,
                              icon: const LuminaIcon(LuminaIcons.logout),
                              child: const Text('退出登录'),
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
    destinations: _newsDestinations(context),
    selectedIndex: selected,
    onDestinationSelected: onSelected,
  );
}
