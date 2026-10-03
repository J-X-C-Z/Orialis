import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/design/lumina_compat.dart';
import '../features/chat/presentation/safe_markdown.dart';
import '../core/config/app_config.dart';
import 'news_data.dart';
import 'news_motion.dart';

typedef _NewsBuilder =
    Widget Function(
      BuildContext,
      List<NewsLoadResult>,
      Future<void> Function(),
    );

class _NewsRequest extends ConsumerStatefulWidget {
  const _NewsRequest({
    required this.paths,
    required this.builder,
    this.requireSession = true,
  });
  final List<String> paths;
  final bool requireSession;
  final _NewsBuilder builder;
  @override
  ConsumerState<_NewsRequest> createState() => _NewsRequestState();
}

class _NewsRequestState extends ConsumerState<_NewsRequest>
    with WidgetsBindingObserver {
  List<NewsLoadResult>? _results;
  final Map<String, NewsLoadResult> _resultsByPath = {};
  Object? _error;
  StreamSubscription<List<NewsLoadResult>>? _subscription;
  int _generation = 0;
  bool _foreground = true;
  int? _refreshGeneration;
  Future<void>? _refreshing;
  int? _refreshingGeneration;
  late final AppConfig _config;
  late final Future<void> Function() _identityChanging =
      _invalidateForIdentityChange;
  late final Future<void> Function() _identityCommitted =
      _reloadForIdentityChange;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _config = ref.read(newsConfigProvider);
    _config.addIdentityListener(_identityChanging);
    _config.addIdentityCommittedListener(_identityCommitted);
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final generation = NewsRefreshScope.of(context);
    if (_refreshGeneration != null && generation != _refreshGeneration) {
      unawaited(_refresh());
    }
    _refreshGeneration = generation;
  }

  Future<void> _invalidateForIdentityChange() async {
    _generation++;
    _resultsByPath.clear();
    final subscription = _subscription;
    _subscription = null;
    if (mounted) {
      setState(() {
        _results = null;
        _error = null;
      });
    }
    unawaited(subscription?.cancel());
  }

  Future<void> _reloadForIdentityChange() async {
    if (mounted && _foreground) _load();
  }

  @override
  void didUpdateWidget(covariant _NewsRequest oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paths.join('|') != widget.paths.join('|') ||
        oldWidget.requireSession != widget.requireSession) {
      final previous = _results;
      if (oldWidget.requireSession != widget.requireSession) {
        _resultsByPath.clear();
      }
      _results =
          previous == null || oldWidget.requireSession != widget.requireSession
          ? null
          : [
              for (final path in widget.paths)
                if (oldWidget.paths.indexOf(path) case final index
                    when index >= 0)
                  previous[index]
                else
                  _resultsByPath[path] ??
                      const NewsLoadResult(NewsLoadKind.loading),
            ];
      _error = null;
      _load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _load();
    } else {
      _generation++;
      unawaited(_subscription?.cancel());
      _subscription = null;
    }
  }

  void _remember(List<NewsLoadResult> results) {
    for (var i = 0; i < results.length; i++) {
      if (results[i].payload != null) {
        _resultsByPath[widget.paths[i]] = results[i];
      }
    }
  }

  void _load() {
    final generation = ++_generation;
    unawaited(_subscription?.cancel());
    if (!_foreground) return;
    _subscription = ref
        .read(newsRepositoryProvider)
        .watch(widget.paths, requireSession: widget.requireSession)
        .listen(
          (results) {
            if (mounted && generation == _generation) {
              setState(() {
                _remember(results);
                _results = results;
                _error = null;
              });
            }
          },
          onError: (Object error) {
            if (mounted && generation == _generation) {
              setState(() {
                _error = error;
                _results = _results
                    ?.map(
                      (result) => result.kind == NewsLoadKind.loading
                          ? NewsLoadResult(
                              NewsLoadKind.error,
                              message: error.toString(),
                            )
                          : result,
                    )
                    .toList();
              });
            }
          },
        );
  }

  Future<void> _refresh() {
    if (_refreshing != null && _refreshingGeneration == _generation) {
      return _refreshing!;
    }
    final generation = _generation;
    _refreshingGeneration = generation;
    return _refreshing = _performRefresh().whenComplete(() {
      if (_refreshingGeneration == generation) _refreshing = null;
    });
  }

  Future<void> _performRefresh() async {
    final generation = _generation;
    try {
      final results = await Future.wait(
        widget.paths.map(
          (path) => ref
              .read(newsRepositoryProvider)
              .get(path, requireSession: widget.requireSession),
        ),
      );
      if (mounted && generation == _generation) {
        setState(() {
          _remember(results);
          _results = results;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error;
          _results = _results
              ?.map(
                (result) => result.kind == NewsLoadKind.loading
                    ? NewsLoadResult(
                        NewsLoadKind.error,
                        message: error.toString(),
                      )
                    : result,
              )
              .toList();
        });
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_subscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    _config.removeIdentityListener(_identityChanging);
    _config.removeIdentityCommittedListener(_identityCommitted);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_results != null) return widget.builder(context, _results!, _refresh);
    if (_error != null) {
      return _StateCard(
        kind: NewsLoadKind.error,
        message: _error.toString(),
        onRetry: _refresh,
      );
    }
    return const _LoadingState();
  }
}

class AihotPage extends StatefulWidget {
  const AihotPage({super.key});
  @override
  State<AihotPage> createState() => _AihotPageState();
}

class _AihotPageState extends State<AihotPage> {
  String _period = 'daily';
  bool _showAllArticles = false;
  @override
  Widget build(BuildContext context) => _NewsRequest(
    paths: ['aihot/hot', 'aihot/items', 'aihot/reports/$_period'],
    builder: (context, results, refresh) {
      final hot = results[0];
      final items = results[1];
      final report = results[2];
      final events = hot.payload?.items ?? const <Map<String, dynamic>>[];
      final articles = items.payload?.items ?? const <Map<String, dynamic>>[];
      final isDesktop = DesktopLayoutScope.of(context);
      final visibleArticles = isDesktop || _showAllArticles
          ? articles
          : articles.take(5).toList();
      final reportData = report.payload?.object ?? const <String, dynamic>{};
      return RefreshIndicator(
        onRefresh: refresh,
        child: _ResponsiveContent(
          children: [
            if (_statusFor(hot) != null)
              LuminaSection(
                raised: true,
                title: '实时热点',
                child: _StateCard.fromResult(hot, onRetry: refresh),
              ),
            if (hot.payload?.stale == true)
              _UpdateNote(
                payload: hot.payload!,
                offline: hot.kind == NewsLoadKind.offline,
              ),
            if (_statusFor(hot) == null)
              _LazyNewsSection(
                title: '实时热点',
                trailing: Text(
                  '${events.length} 条',
                  style: LuminaTheme.of(context).textTheme.bodySmall,
                ),
                itemCount: events.isEmpty ? 1 : events.length,
                itemBuilder: (context, i) => events.isEmpty
                    ? const LuminaEmptyState(text: '暂无 AI 热点')
                    : _NewsItemCard(
                        item: events[i],
                        rank:
                            _int(events[i]['rank']) ??
                            _int(events[i]['ranking']) ??
                            i + 1,
                        accent: i < 3,
                        onTap: () => _openAihotEvent(context, events[i]),
                      ),
              ),
            if (_statusFor(items) != null || articles.isEmpty)
              LuminaSection(
                raised: true,
                title: '精选资讯',
                child: _statusFor(items) != null
                    ? _StateCard.fromResult(items, onRetry: refresh)
                    : const LuminaEmptyState(text: '暂无精选资讯'),
              )
            else
              _LazyNewsSection(
                title: '精选资讯',
                leading: items.payload?.stale == true
                    ? _UpdateNote(
                        payload: items.payload!,
                        offline: items.kind == NewsLoadKind.offline,
                      )
                    : null,
                itemCount: visibleArticles.length,
                itemBuilder: (context, index) => _NewsItemCard(
                  item: visibleArticles[index],
                  onTap: () => _openArticle(context, visibleArticles[index]),
                ),
                footer: !isDesktop && articles.length > 5
                    ? Align(
                        alignment: Alignment.center,
                        child: LuminaButton(
                          primary: false,
                          onPressed: () => setState(
                            () => _showAllArticles = !_showAllArticles,
                          ),
                          icon: AnimatedRotation(
                            turns: _showAllArticles ? .5 : 0,
                            duration: LuminaTheme.motionReducedOf(context)
                                ? Duration.zero
                                : LuminaMotion.standard,
                            curve: luminaEaseOut,
                            child: const Icon(Icons.expand_more_rounded),
                          ),
                          child: Text(
                            _showAllArticles
                                ? '收起精选'
                                : '展开全部 ${articles.length} 条精选',
                          ),
                        ),
                      )
                    : null,
              ),
            LuminaSection(
              raised: true,
              title: 'AI 报告',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PeriodSelector(
                    value: _period,
                    values: const {
                      'daily': '日报',
                      'weekly': '周报',
                      'monthly': '月报',
                    },
                    onChanged: (value) => setState(() => _period = value),
                  ),
                  const SizedBox(height: 16),
                  _ReportSummary(
                    result: report,
                    title:
                        _str(reportData['title']) ??
                        '${_periodLabel(_period)} AI 报告',
                    onOpen: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _ReportDetailPage(
                          title: '${_periodLabel(_period)} AI 报告',
                          path: 'aihot/reports/$_period',
                        ),
                      ),
                    ),
                    onRetry: refresh,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class GithubPage extends StatefulWidget {
  const GithubPage({super.key});
  @override
  State<GithubPage> createState() => _GithubPageState();
}

class _GithubPageState extends State<GithubPage> {
  String _period = 'daily';
  @override
  Widget build(BuildContext context) => _NewsRequest(
    paths: ['github/$_period', 'github/briefs/$_period'],
    builder: (context, results, refresh) {
      final result = results[0];
      final brief = results[1];
      final repos = result.payload?.items ?? const <Map<String, dynamic>>[];
      final directContent =
          repos.any(_isSourceRepository) ||
          brief.payload?.object['analysisStatus'] == 'not_required';
      return RefreshIndicator(
        onRefresh: refresh,
        child: _ResponsiveContent(
          children: [
            LuminaSection(
              raised: true,
              title: 'GitHub Trending',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PeriodSelector(
                    value: _period,
                    values: const {'daily': '日榜', 'weekly': '周榜'},
                    onChanged: (value) => setState(() => _period = value),
                  ),
                  if (result.payload != null)
                    _UpdateNote(
                      payload: result.payload!,
                      offline: result.kind == NewsLoadKind.offline,
                    ),
                  if (directContent)
                    _ExternalLink(
                      label: '来源：githot.dev',
                      url: _period == 'weekly'
                          ? 'https://githot.dev/weekly'
                          : 'https://githot.dev/',
                    ),
                ],
              ),
            ),
            if (_statusFor(result) != null)
              _StateCard.fromResult(result, onRetry: refresh)
            else ...[
              if (!directContent)
                LuminaSection(
                  raised: true,
                  title: 'GitHub 总览',
                  child: _GithubBriefSummary(result: brief, period: _period),
                ),
              if (repos.isEmpty)
                const LuminaEmptyState(text: '当前榜单还没有数据')
              else
                _LazyNewsSection(
                  title: '热门仓库',
                  trailing: Text(
                    '${repos.length} 条',
                    style: LuminaTheme.of(context).textTheme.bodySmall,
                  ),
                  itemCount: repos.length,
                  itemBuilder: (context, i) => _RepoCard(
                    repo: repos[i],
                    ranking: _int(repos[i]['ranking']) ?? i + 1,
                    onTap: () => _openRepository(context, repos[i]),
                  ),
                ),
            ],
          ],
        ),
      );
    },
  );
}

class _GithubBriefSummary extends StatelessWidget {
  const _GithubBriefSummary({required this.result, required this.period});
  final NewsLoadResult result;
  final String period;

  @override
  Widget build(BuildContext context) {
    if (result.kind == NewsLoadKind.loading) {
      return const _StateCard(kind: NewsLoadKind.loading);
    }
    final data = result.payload?.object ?? const <String, dynamic>{};
    final failed = _statusFor(result) != null;
    final title = _str(data['title']) ?? '${_periodLabel(period)} GitHub 总览';
    final summary = _str(data['summary']);
    final themes = data['themes'];
    final highlights = data['highlights'];
    final hasBrief = data.isNotEmpty;
    return LuminaSurface(
      depth: LuminaSurfaceDepth.recessed,
      radius: LuminaRadius.card,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: LuminaTheme.of(context).textTheme.cardTitle),
          if (result.payload?.stale == true)
            _UpdateNote(
              payload: result.payload!,
              offline: result.kind == NewsLoadKind.offline,
            ),
          if (failed || !hasBrief)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                failed ? 'AI 总览暂不可用，完整榜单仍可查看。' : '暂无 AI 总览，完整榜单仍可查看。',
                style: LuminaTheme.of(context).textTheme.bodySmall,
              ),
            ),
          if (failed && result.message != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                result.message!,
                style: LuminaTheme.of(context).textTheme.bodySmall,
              ),
            ),
          if (summary != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                summary,
                style: LuminaTheme.of(context).textTheme.bodyMedium,
              ),
            ),
          if (themes is List && themes.isNotEmpty)
            _BriefPoints(label: '本期主题', values: themes),
          if (highlights is List && highlights.isNotEmpty)
            _BriefPoints(label: '重点项目', values: highlights),
          if (_str(data['analysisStatus']) != null ||
              _str(data['source']) != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                [
                  if (_str(data['analysisStatus']) != null)
                    '分析状态 ${data['analysisStatus']}',
                  if (_str(data['source']) != null) '来源 ${data['source']}',
                ].join(' · '),
                style: LuminaTheme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _BriefPoints extends StatelessWidget {
  const _BriefPoints({required this.label, required this.values});
  final String label;
  final List<dynamic> values;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: LuminaTheme.of(context).textTheme.labelMedium.copyWith(
            color: LuminaTheme.of(context).colors.muted,
          ),
        ),
        for (final value in values)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('• ${_displayValue(value)}'),
          ),
      ],
    ),
  );
}

class ProjectsNewsPage extends StatelessWidget {
  const ProjectsNewsPage({super.key});
  @override
  Widget build(BuildContext context) => _NewsRequest(
    paths: const ['projects', 'projects/daily'],
    requireSession: true,
    builder: (context, results, refresh) {
      final projectsResult = results[0];
      final dailyResult = results[1];
      final projects =
          projectsResult.payload?.items ?? const <Map<String, dynamic>>[];
      final daily = dailyResult.payload?.object ?? const <String, dynamic>{};
      return RefreshIndicator(
        onRefresh: refresh,
        child: _ResponsiveContent(
          children: [
            if (_statusFor(projectsResult) != null)
              _StateCard.fromResult(projectsResult, onRetry: refresh)
            else
              _LazyNewsSection(
                title: '项目进展',
                trailing: Text(
                  '${_int(daily['activeProjects']) ?? projects.length} 个活跃项目',
                  style: LuminaTheme.of(context).textTheme.bodySmall,
                ),
                leading: projectsResult.payload?.stale == true
                    ? _UpdateNote(
                        payload: projectsResult.payload!,
                        offline: projectsResult.kind == NewsLoadKind.offline,
                      )
                    : null,
                itemCount: projects.isEmpty ? 1 : projects.length,
                itemBuilder: (context, index) => projects.isEmpty
                    ? const LuminaEmptyState(text: '尚未收到该账号的项目秘书报告')
                    : _ProjectCard(
                        project: projects[index],
                        onTap: () => _openProject(context, projects[index]),
                      ),
              ),
            LuminaSection(
              raised: true,
              title: '今日项目总报',
              child: _statusFor(dailyResult) != null
                  ? _StateCard.fromResult(dailyResult, onRetry: refresh)
                  : Column(
                      children: [
                        if (dailyResult.payload?.stale == true)
                          _UpdateNote(
                            payload: dailyResult.payload!,
                            offline: dailyResult.kind == NewsLoadKind.offline,
                          ),
                        _ProjectDailySummary(
                          data: daily,
                          onOpen: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const _ReportDetailPage(
                                title: '今日项目总报',
                                path: 'projects/daily',
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      );
    },
  );
}

// Slivers keep article/repository rows outside the viewport unmounted, including
// rows inside a visual section. A shrink-wrapped nested list would lay them all out.
class _LazyNewsSection extends StatefulWidget {
  const _LazyNewsSection({
    this.title,
    this.trailing,
    this.leading,
    this.footer,
    required this.itemCount,
    required this.itemBuilder,
  });
  final String? title;
  final Widget? trailing;
  final Widget? leading;
  final Widget? footer;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  State<_LazyNewsSection> createState() => _LazyNewsSectionState();
}

class _LazyNewsSectionState extends State<_LazyNewsSection> {
  late bool _expanded =
      widget.title == null ||
      LuminaCardMemory.expanded('section:${widget.title}');

  void _toggle() {
    setState(() => _expanded = !_expanded);
    LuminaCardMemory.save('section:${widget.title}', _expanded);
  }

  @override
  Widget build(BuildContext context) {
    final titled = widget.title != null;
    final rows = SliverMainAxisGroup(
      slivers: [
        if (widget.leading != null) SliverToBoxAdapter(child: widget.leading!),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: titled ? 16 : 0),
          sliver: SliverList.builder(
            itemCount: widget.itemCount,
            itemBuilder: widget.itemBuilder,
          ),
        ),
        if (widget.footer != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: widget.footer,
            ),
          ),
      ],
    );
    if (!titled) return rows;
    return LuminaCardHost(
      child: DecoratedSliver(
        decoration: LuminaCardDecoration.of(
          context,
          title: widget.title,
          shoulder: true,
          shoulderTrailingSpace: widget.trailing == null ? 26 : 90,
        ),
        sliver: SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: LuminaCardHeader(
                  title: widget.title!,
                  trailing: widget.trailing,
                  expanded: _expanded,
                  onTitleTap: _toggle,
                ),
              ),
            ),
            NewsSliverReveal(
              visible: _expanded,
              sliver: SliverPadding(
                padding: const EdgeInsets.only(
                  top: LuminaCardMetrics.titleToContent,
                  bottom: 16,
                ),
                sliver: rows,
              ),
            ),
            SliverToBoxAdapter(
              child: LuminaReveal(
                visible: !_expanded,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                  child: Text(
                    LuminaLocalizations.of(context).collapsed,
                    style: LuminaTheme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResponsiveContent extends StatelessWidget {
  const _ResponsiveContent({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => CustomScrollView(
    physics: const AlwaysScrollableScrollPhysics(),
    slivers: [
      SliverPadding(
        padding: EdgeInsets.only(top: LuminaPageHeaderInset.of(context) + 12),
      ),
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SliverToBoxAdapter(child: SizedBox(height: 20)),
        if (children[i] is _LazyNewsSection)
          children[i]
        else
          SliverToBoxAdapter(child: children[i]),
      ],
      SliverPadding(
        padding: EdgeInsets.only(
          bottom:
              LuminaNavigationInset.of(context) +
              MediaQuery.paddingOf(context).bottom +
              20,
        ),
      ),
    ],
  );
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();
  @override
  Widget build(BuildContext context) {
    final placeholder = LuminaTheme.of(
      context,
    ).colors.muted.withValues(alpha: 0.14);
    return ListView(
      padding: EdgeInsets.only(
        top: LuminaPageHeaderInset.of(context) + 12,
        bottom:
            LuminaNavigationInset.of(context) +
            MediaQuery.paddingOf(context).bottom +
            20,
      ),
      children: [
        for (var card = 0; card < 3; card++)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: LuminaSurface(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SkeletonBar(width: 112, color: placeholder),
                  const SizedBox(height: 12),
                  _SkeletonBar(width: double.infinity, color: placeholder),
                  const SizedBox(height: 8),
                  _SkeletonBar(width: 220, color: placeholder),
                  if (card == 0) ...[
                    const SizedBox(height: 14),
                    _SkeletonBar(width: double.infinity, color: placeholder),
                    const SizedBox(height: 8),
                    _SkeletonBar(width: 164, color: placeholder),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _SkeletonBar extends StatelessWidget {
  const _SkeletonBar({required this.width, required this.color});
  final double width;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: 10,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(6),
    ),
  );
}

NewsLoadKind? _statusFor(NewsLoadResult result) => switch (result.kind) {
  NewsLoadKind.data ||
  NewsLoadKind.empty ||
  NewsLoadKind.offline => result.payload != null ? null : result.kind,
  _ => result.kind,
};

class _StateCard extends StatelessWidget {
  const _StateCard({required this.kind, this.message, this.onRetry});
  factory _StateCard.fromResult(
    NewsLoadResult result, {
    Future<void> Function()? onRetry,
  }) => _StateCard(
    kind: _statusFor(result) ?? NewsLoadKind.error,
    message: result.message ?? result.payload?.error,
    onRetry: onRetry,
  );
  final NewsLoadKind kind;
  final String? message;
  final Future<void> Function()? onRetry;
  @override
  Widget build(BuildContext context) {
    if (kind == NewsLoadKind.loading) {
      return const LuminaSurface(
        child: Padding(padding: EdgeInsets.all(16), child: Text('正在加载…')),
      );
    }
    final title = switch (kind) {
      NewsLoadKind.offline => '离线内容',
      NewsLoadKind.needsSession => '需要登录',
      NewsLoadKind.empty => '暂无内容',
      _ => '暂时无法加载',
    };
    return LuminaSurface(
      depth: LuminaSurfaceDepth.recessed,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              kind == NewsLoadKind.offline
                  ? Icons.wifi_off_rounded
                  : Icons.info_outline_rounded,
              color: LuminaTheme.of(context).colors.muted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: LuminaTheme.of(context).textTheme.cardTitle,
                  ),
                  if (message != null)
                    Text(
                      message == 'no published cache is available'
                          ? '暂未发布资讯，稍后刷新即可。'
                          : message!,
                      style: LuminaTheme.of(context).textTheme.bodySmall,
                    ),
                  if (onRetry != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: LuminaButton(
                        primary: false,
                        onPressed: onRetry,
                        child: const Text('重试'),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpdateNote extends StatelessWidget {
  const _UpdateNote({required this.payload, this.offline = false});
  final NewsPayload payload;
  final bool offline;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 12),
    child: Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      children: [
        if (payload.stale)
          Icon(
            offline ? Icons.cloud_off_outlined : Icons.history_rounded,
            size: 15,
          ),
        if (payload.stale) const SizedBox(width: 5),
        Text(
          payload.stale
              ? offline
                    ? '离线缓存 · '
                    : '缓存内容 · '
              : '更新于 ',
          style: LuminaTheme.of(context).textTheme.bodySmall,
        ),
        Text(
          _date(payload.updatedAt),
          style: LuminaTheme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}

class _NewsItemCard extends StatelessWidget {
  const _NewsItemCard({
    required this.item,
    this.rank,
    this.accent = false,
    this.onTap,
  });
  final Map<String, dynamic> item;
  final int? rank;
  final bool accent;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final title = _str(item['title']) ?? _str(item['name']) ?? '未命名热点';
    final summary = _str(item['summary']) ?? _str(item['description']);
    final heat = _str(item['heat']) ?? _str(item['score']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LuminaSurface(
        depth: LuminaSurfaceDepth.recessed,
        onTap: onTap,
        radius: 16,
        liquidGlass: false,

        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (rank != null)
                  Text(
                    '#$rank  ',
                    style: LuminaTheme.of(context).textTheme.labelMedium
                        .copyWith(color: LuminaTheme.of(context).colors.accent),
                  ),
                Expanded(
                  child: Text(
                    title,
                    maxLines: accent ? 3 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: LuminaTheme.of(context).textTheme.cardTitle,
                  ),
                ),
                if (heat != null)
                  Text(
                    heat,
                    style: LuminaTheme.of(context).textTheme.labelMedium,
                  ),
              ],
            ),
            if (summary != null)
              Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Text(
                  summary,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: LuminaTheme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                if (_str(item['category']) != null)
                  _MetaLabel(_str(item['category'])!),
                if (_str(item['source']) != null)
                  _MetaLabel(_str(item['source'])!),
                if (_str(item['publishedAt']) != null ||
                    _str(item['createdAt']) != null)
                  _MetaLabel(
                    _date(
                      DateTime.tryParse(
                        (_str(item['publishedAt']) ?? _str(item['createdAt']))!,
                      ),
                    ),
                  ),
                if (_int(item['sourceCount']) != null)
                  _MetaLabel('${item['sourceCount']} 个来源'),
                if (_str(item['trend']) != null)
                  _MetaLabel('趋势 ${item['trend']}'),
                if (_str(item['status']) != null)
                  _MetaLabel('状态 ${item['status']}'),
                if (_str(item['latestUpdate']) != null)
                  _MetaLabel('最新进展 ${item['latestUpdate']}'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RepoCard extends StatelessWidget {
  const _RepoCard({
    required this.repo,
    required this.ranking,
    required this.onTap,
  });
  final Map<String, dynamic> repo;
  final int ranking;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final owner = _str(repo['owner']) ?? '';
    final name = _str(repo['name']) ?? _str(repo['repository']) ?? 'repository';
    final repository = name.contains('/') ? name : '$owner/$name';
    final title = _str(repo['sourceTitle']) ?? repository;
    final summary =
        _str(repo['sourceSummary']) ??
        (_isSourceRepository(repo) ? null : _str(repo['summary'])) ??
        _str(repo['description']);
    final topics = repo['sourceTopics'] ?? repo['topics'];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LuminaSurface(
        depth: LuminaSurfaceDepth.recessed,
        radius: 16,
        liquidGlass: false,

        onTap: onTap,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '#$ranking  ',
                  style: LuminaTheme.of(context).textTheme.labelMedium.copyWith(
                    color: LuminaTheme.of(context).colors.accent,
                  ),
                ),
                Expanded(
                  child: Text(
                    title,
                    maxLines: ranking <= 3 ? 3 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: LuminaTheme.of(context).textTheme.cardTitle,
                  ),
                ),
              ],
            ),
            if (summary != null)
              Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Text(
                  summary,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: LuminaTheme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                if (title != repository) _MetaLabel(repository),
                if (_str(repo['language']) != null)
                  _MetaLabel(_str(repo['language'])!),
                _MetaLabel('★ ${_number(repo['stars']) ?? '—'}'),
                if (_number(repo['starsInPeriod']) != null)
                  _MetaLabel('+${_number(repo['starsInPeriod'])} 本期'),
              ],
            ),
            if (topics is List && topics.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    for (final topic in topics.whereType<String>())
                      _MetaLabel(topic),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.project, required this.onTap});
  final Map<String, dynamic> project;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final name = _str(project['name']) ?? _str(project['project']) ?? '项目';
    final updates =
        _int(project['updatesToday']) ?? _int(project['updateCount']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LuminaSurface(
        depth: LuminaSurfaceDepth.recessed,
        radius: 16,
        liquidGlass: false,
        onTap: onTap,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    style: LuminaTheme.of(context).textTheme.cardTitle,
                  ),
                ),
                if (updates != null) _MetaLabel('$updates 项更新'),
                const LuminaIcon(LuminaIcons.chevronRight),
              ],
            ),
            if (_str(project['summary']) != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _str(project['summary'])!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: LuminaTheme.of(context).textTheme.bodySmall,
                ),
              ),
            if (project['completed'] is List)
              _BulletPreview(label: '完成', values: project['completed']),
            if (project['inProgress'] is List)
              _BulletPreview(label: '进行中', values: project['inProgress']),
            if (project['issues'] is List)
              _BulletPreview(label: '问题', values: project['issues']),
          ],
        ),
      ),
    );
  }
}

class _BulletPreview extends StatelessWidget {
  const _BulletPreview({required this.label, required this.values});
  final String label;
  final dynamic values;
  @override
  Widget build(BuildContext context) {
    final list = values is List ? (values as List).take(2).toList() : const [];
    if (list.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        '$label · ${list.map((e) => e.toString()).join(' · ')}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: LuminaTheme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class _ReportSummary extends StatelessWidget {
  const _ReportSummary({
    required this.result,
    required this.title,
    required this.onOpen,
    required this.onRetry,
  });
  final NewsLoadResult result;
  final String title;
  final VoidCallback onOpen;
  final Future<void> Function() onRetry;
  @override
  Widget build(BuildContext context) {
    if (_statusFor(result) != null) {
      return _StateCard.fromResult(result, onRetry: onRetry);
    }
    final data = result.payload?.object ?? const {};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (result.payload?.stale == true)
          _UpdateNote(
            payload: result.payload!,
            offline: result.kind == NewsLoadKind.offline,
          ),
        _GenericReportCard(data: data, title: title, onOpen: onOpen),
      ],
    );
  }
}

class _GenericReportCard extends StatelessWidget {
  const _GenericReportCard({
    required this.data,
    required this.onOpen,
    this.title,
  });
  final Map<String, dynamic> data;
  final String? title;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final headline = title ?? _str(data['title']) ?? '今日项目总报';
    final detail =
        _str(data['summary']) ??
        _str(data['overview']) ??
        _str(data['content']);
    final counts = [
      if (_int(data['activeProjects']) != null)
        '${data['activeProjects']} 个活跃项目',
      if (_int(data['updatesToday']) != null) '${data['updatesToday']} 项进展',
      if (_int(data['completedToday']) != null) '${data['completedToday']} 项完成',
      if (_int(data['attentionCount']) != null)
        '${data['attentionCount']} 项待关注',
    ].join(' · ');
    return LuminaSurface(
      depth: LuminaSurfaceDepth.recessed,
      radius: 16,
      liquidGlass: false,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(headline, style: LuminaTheme.of(context).textTheme.cardTitle),
          if (counts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                counts,
                style: LuminaTheme.of(context).textTheme.bodySmall,
              ),
            ),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                detail,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: LuminaTheme.of(context).textTheme.bodyMedium,
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: LuminaButton(
              primary: false,
              onPressed: onOpen,
              icon: const LuminaIcon(LuminaIcons.arrowRight),
              child: const Text('查看报告'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectDailySummary extends StatelessWidget {
  const _ProjectDailySummary({required this.data, required this.onOpen});
  final Map<String, dynamic> data;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return const LuminaEmptyState(text: '尚未发布今日项目总报');
    }
    final detail =
        _str(data['summary']) ??
        _str(data['overview']) ??
        _str(data['content']);
    return LuminaSurface(
      depth: LuminaSurfaceDepth.recessed,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _str(data['title']) ?? '今日项目进展',
            style: LuminaTheme.of(context).textTheme.cardTitle,
          ),
          Text(
            [
              if (_int(data['activeProjects']) != null)
                '${data['activeProjects']} 个活跃项目',
              if (_int(data['completedToday']) != null)
                '${data['completedToday']} 项完成',
              if (_int(data['attentionCount']) != null)
                '${data['attentionCount']} 项待关注',
            ].join(' · '),
            style: LuminaTheme.of(context).textTheme.bodySmall,
          ),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(detail, maxLines: 3, overflow: TextOverflow.ellipsis),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: LuminaButton(
              primary: false,
              onPressed: onOpen,
              icon: const LuminaIcon(LuminaIcons.arrowRight),
              child: const Text('查看报告'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({
    required this.value,
    required this.values,
    required this.onChanged,
  });
  final String value;
  final Map<String, String> values;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => LuminaSegmented<String>(
    transparent: true,
    items: values,
    value: value,
    onChanged: onChanged,
  );
}

class _MetaLabel extends StatelessWidget {
  const _MetaLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text, style: LuminaTheme.of(context).textTheme.bodySmall);
}

void _openAihotEvent(BuildContext context, Map<String, dynamic> item) {
  final id = _str(item['id']) ?? _str(item['itemId']) ?? _str(item['eventId']);
  if (id == null) return;
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => _DetailPage(
        title: _str(item['title']) ?? '热点详情',
        path: 'aihot/events/${Uri.encodeComponent(id)}',
      ),
    ),
  );
}

void _openRepository(BuildContext context, Map<String, dynamic> repo) {
  final repository =
      _str(repo['repository']) ??
      _str(repo['fullName']) ??
      '${_str(repo['owner']) ?? ''}/${_str(repo['name']) ?? ''}';
  final parts = repository.split('/');
  if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) return;
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => _DetailPage(
        title: _str(repo['sourceTitle']) ?? repository,
        path:
            'github/repos/${Uri.encodeComponent(parts[0])}/${Uri.encodeComponent(parts[1])}',
      ),
    ),
  );
}

void _openProject(BuildContext context, Map<String, dynamic> project) {
  final id = _str(project['id']) ?? _str(project['projectId']);
  if (id == null) return;
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => _ProjectDetailPage(project: project, id: id),
    ),
  );
}

void _openArticle(BuildContext context, Map<String, dynamic> item) {
  final url = _str(item['url']);
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => _StaticDetailPage(
        title: _str(item['title']) ?? '资讯详情',
        data: item,
        link: url,
      ),
    ),
  );
}

class _DetailPage extends StatelessWidget {
  const _DetailPage({required this.title, required this.path});
  final String title, path;
  @override
  Widget build(BuildContext context) =>
      _DetailRequestPage(title: title, paths: [path]);
}

class _ReportDetailPage extends StatelessWidget {
  const _ReportDetailPage({required this.title, required this.path});
  final String title, path;
  @override
  Widget build(BuildContext context) =>
      _DetailRequestPage(title: title, paths: [path], requireSession: true);
}

class _ProjectDetailPage extends StatelessWidget {
  const _ProjectDetailPage({required this.project, required this.id});
  final Map<String, dynamic> project;
  final String id;
  @override
  Widget build(BuildContext context) => _DetailRequestPage(
    title: _str(project['name']) ?? '项目详情',
    paths: [
      'projects/${Uri.encodeComponent(id)}',
      'projects/${Uri.encodeComponent(id)}/reports',
    ],
    requireSession: true,
  );
}

class _DetailRequestPage extends StatelessWidget {
  const _DetailRequestPage({
    required this.title,
    required this.paths,
    this.requireSession = true,
  });
  final String title;
  final List<String> paths;
  final bool requireSession;
  @override
  Widget build(BuildContext context) => LuminaPageScaffold(
    title: title,
    leading: LuminaIconButton(
      tooltip: '返回',
      onPressed: () => Navigator.of(context).maybePop(),
      icon: const LuminaIcon(LuminaIcons.back),
    ),
    body: _NewsRequest(
      paths: paths,
      requireSession: requireSession,
      builder: (context, results, refresh) => RefreshIndicator(
        onRefresh: refresh,
        child: _ResponsiveContent(
          children: [
            for (var i = 0; i < results.length; i++)
              if (_statusFor(results[i]) != null)
                _StateCard.fromResult(results[i], onRetry: refresh)
              else if (paths[i] == 'projects/daily')
                _DataDetail(
                  data: results[i].payload?.object ?? const {},
                  title: '今日项目总报',
                  payload: results[i].payload,
                )
              else if (paths[i].endsWith('/reports'))
                _ProjectReportsDetail(
                  reports: results[i].payload?.items ?? const [],
                  payload: results[i].payload,
                  offline: results[i].kind == NewsLoadKind.offline,
                  title: paths[i] == 'projects/daily' ? '项目总报' : '项目秘书报告',
                )
              else if (paths[i].startsWith('aihot/reports/'))
                _AihotReportDetail(
                  data: results[i].payload?.object ?? const {},
                  payload: results[i].payload,
                  offline: results[i].kind == NewsLoadKind.offline,
                )
              else
                _DataDetail(
                  data:
                      results[i].payload?.object ??
                      _payloadAsObject(results[i].payload),
                  title: paths[i].contains('/reports') ? '项目日报' : null,
                  payload: results[i].payload,
                  offline: results[i].kind == NewsLoadKind.offline,
                ),
          ],
        ),
      ),
    ),
  );
}

class _AihotReportDetail extends StatelessWidget {
  const _AihotReportDetail({
    required this.data,
    required this.payload,
    required this.offline,
  });
  final Map<String, dynamic> data;
  final NewsPayload? payload;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    final lead = data['lead'];
    final sections = data['sections'];
    final flashes = data['flashes'];
    final headline = _str(data['headline']);
    final overview = _str(data['overview']);
    final dateRange = [
      _str(data['periodStart']) ?? _str(data['windowStart']),
      _str(data['periodEnd']) ?? _str(data['windowEnd']),
    ].whereType<String>().toList();
    final links = data['links'];
    final attribution = data['attribution'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (payload != null) _UpdateNote(payload: payload!, offline: offline),
        if (dateRange.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              dateRange.join(' — '),
              style: LuminaTheme.of(context).textTheme.bodySmall,
            ),
          ),
        if (lead is Map)
          _AihotReportLead(data: Map<String, dynamic>.from(lead)),
        if (headline != null)
          LuminaSection(
            title: '本期焦点',
            child: Text(
              headline,
              style: LuminaTheme.of(context).textTheme.cardTitle,
            ),
          ),
        if (overview != null)
          LuminaSection(
            title: '本期综览',
            child: SelectableText(
              overview,
              style: LuminaTheme.of(context).textTheme.bodyMedium,
            ),
          ),
        if (sections is List)
          for (var i = 0; i < sections.length; i++)
            if (sections[i] is Map)
              _AihotReportSection(
                data: Map<String, dynamic>.from(sections[i] as Map),
                index: i,
              ),
        if (flashes is List && flashes.isNotEmpty)
          LuminaSection(
            title: '快讯',
            trailing: Text(
              '${flashes.length} 条',
              style: LuminaTheme.of(context).textTheme.bodySmall,
            ),
            child: Column(
              children: [
                for (final flash in flashes)
                  if (flash is Map)
                    _AihotReportStory(data: Map<String, dynamic>.from(flash))
                  else
                    _AihotReportStory(data: {'title': flash.toString()}),
              ],
            ),
          ),
        if (links is Map)
          _AihotReportLinks(links: Map<String, dynamic>.from(links)),
        if (attribution is Map)
          _AihotReportAttribution(
            attribution: Map<String, dynamic>.from(attribution),
          ),
      ],
    );
  }
}

class _AihotReportLead extends StatelessWidget {
  const _AihotReportLead({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final title = _str(data['title']);
    final paragraph = _str(data['leadParagraph']);
    if (title == null && paragraph == null) return const SizedBox.shrink();
    return LuminaSection(
      title: '导读',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Text(title, style: LuminaTheme.of(context).textTheme.cardTitle),
          if (paragraph != null) ...[
            if (title != null) const SizedBox(height: 8),
            SelectableText(
              paragraph,
              style: LuminaTheme.of(context).textTheme.bodyMedium,
            ),
          ],
        ],
      ),
    );
  }
}

class _AihotReportSection extends StatelessWidget {
  const _AihotReportSection({required this.data, required this.index});
  final Map<String, dynamic> data;
  final int index;

  @override
  Widget build(BuildContext context) {
    final label = _str(data['label']) ?? '专题 ${index + 1}';
    final summary = _str(data['summary']);
    final items = data['items'];
    return LuminaSection(
      title: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (summary != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SelectableText(
                summary,
                style: LuminaTheme.of(context).textTheme.bodyMedium,
              ),
            ),
          if (items is List)
            for (final item in items)
              if (item is Map)
                _AihotReportStory(data: Map<String, dynamic>.from(item)),
        ],
      ),
    );
  }
}

class _AihotReportStory extends StatelessWidget {
  const _AihotReportStory({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final title = _str(data['title']) ?? _str(data['headline']);
    final summary =
        _str(data['summary']) ??
        _str(data['content']) ??
        _str(data['description']);
    final source = data['source'];
    final sourceName = source is Map ? _str(source['name']) : _str(source);
    final publishedAt = _str(data['publishedAt']);
    final links = data['links'];
    final attribution = data['attribution'];

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LuminaSurface(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null)
              Text(title, style: LuminaTheme.of(context).textTheme.cardTitle),
            if (summary != null) ...[
              if (title != null) const SizedBox(height: 7),
              SelectableText(
                summary,
                style: LuminaTheme.of(context).textTheme.bodyMedium,
              ),
            ],
            if (sourceName != null || publishedAt != null) ...[
              const SizedBox(height: 7),
              Text(
                [
                  ?sourceName,
                  if (publishedAt != null)
                    _date(DateTime.tryParse(publishedAt)),
                ].join(' · '),
                style: LuminaTheme.of(context).textTheme.bodySmall,
              ),
            ],
            if (links is Map)
              _AihotReportLinks(links: Map<String, dynamic>.from(links)),
            if (attribution is Map)
              _AihotReportAttribution(
                attribution: Map<String, dynamic>.from(attribution),
              ),
          ],
        ),
      ),
    );
  }
}

class _AihotReportLinks extends StatelessWidget {
  const _AihotReportLinks({required this.links});
  final Map<String, dynamic> links;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 4,
    children: [
      for (final entry in links.entries)
        if (entry.value is String && _httpUri(entry.value as String) != null)
          _ExternalLink(
            label: entry.key == 'original'
                ? '打开原文链接'
                : entry.key == 'aihot'
                ? '查看 AIHOT 原文'
                : '打开来源链接',
            url: entry.value as String,
          ),
    ],
  );
}

class _AihotReportAttribution extends StatelessWidget {
  const _AihotReportAttribution({required this.attribution});
  final Map<String, dynamic> attribution;

  @override
  Widget build(BuildContext context) {
    final name = _str(attribution['name']);
    final url = _str(attribution['url']);
    if (url == null || _httpUri(url) == null) {
      return name == null
          ? const SizedBox.shrink()
          : Text(name, style: LuminaTheme.of(context).textTheme.bodySmall);
    }
    return _ExternalLink(label: '来源 ${name ?? 'AIHOT'}', url: url);
  }
}

Map<String, dynamic> _payloadAsObject(NewsPayload? payload) {
  final value = payload?.data;
  if (value is List && value.isNotEmpty && value.first is Map) {
    return Map<String, dynamic>.from(value.first as Map);
  }
  return const {};
}

bool _isSourceRepository(Map<String, dynamic> repository) =>
    repository['contentOrigin'] == 'githot.dev' ||
    repository['analysisStatus'] == 'not_required' ||
    _str(repository['sourceContent']) != null;

class _RepositoryDetail extends StatelessWidget {
  const _RepositoryDetail({
    required this.data,
    this.payload,
    this.offline = false,
  });
  final Map<String, dynamic> data;
  final NewsPayload? payload;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    final repository = _str(data['repository']) ?? _str(data['fullName'])!;
    final sourceTitle = _str(data['sourceTitle']);
    final content = _str(data['sourceContent']);
    final summary =
        _str(data['sourceSummary']) ??
        (_isSourceRepository(data) ? null : _str(data['summary'])) ??
        _str(data['description']);
    final readme = _str(data['readme']);
    final topics = data['sourceTopics'] ?? data['topics'];
    final sourceUrl = _str(data['sourceUrl']);
    final repositoryUrl =
        _str(data['repositoryUrl']) ??
        _str(data['htmlUrl']) ??
        'https://github.com/$repository';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (payload != null) _UpdateNote(payload: payload!, offline: offline),
        Text(
          sourceTitle ?? repository,
          style: LuminaTheme.of(context).textTheme.cardTitle,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            if (sourceTitle != null) _MetaLabel(repository),
            if (_str(data['language']) != null)
              _MetaLabel(_str(data['language'])!),
            _MetaLabel('★ ${_number(data['stars']) ?? '—'}'),
            if (_number(data['starsInPeriod']) != null)
              _MetaLabel('+${_number(data['starsInPeriod'])} 本期'),
            if (topics is List)
              for (final topic in topics.whereType<String>()) _MetaLabel(topic),
          ],
        ),
        if (content != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: SafeMarkdownView(source: content),
          )
        else if (summary != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              summary,
              style: LuminaTheme.of(context).textTheme.bodyMedium,
            ),
          ),
        if (sourceUrl != null) _ExternalLink(label: '查看来源原文', url: sourceUrl),
        _ExternalLink(label: '打开 GitHub 仓库', url: repositoryUrl),
        if (readme != null)
          LuminaSection(
            title: 'README',
            child: SafeMarkdownView(source: readme),
          ),
        if (content == null && summary == null && readme == null)
          const LuminaEmptyState(text: '暂未提供仓库正文，可查看来源原文。', card: false),
      ],
    );
  }
}

class _DataDetail extends StatelessWidget {
  const _DataDetail({
    required this.data,
    this.title,
    this.payload,
    this.offline = false,
  });
  final Map<String, dynamic> data;
  final String? title;
  final NewsPayload? payload;
  final bool offline;
  @override
  Widget build(BuildContext context) {
    if (_str(data['repository']) != null || _str(data['fullName']) != null) {
      return _RepositoryDetail(data: data, payload: payload, offline: offline);
    }
    final timeline = newsEventTimeline(data);
    final sources = newsEventSources(data);
    final links = data['links'];
    final project = data['project'];
    final latestReport = data['latestReport'];
    final rawReports = data['rawReports'];
    final repositoryUrl = _str(data['repositoryUrl']) ?? _str(data['htmlUrl']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (payload != null) _UpdateNote(payload: payload!, offline: offline),
        if (project is Map)
          LuminaSection(
            title: '项目',
            child: _JsonContent(data: Map<String, dynamic>.from(project)),
          ),
        if (latestReport is Map)
          _ProjectReportEntry(
            wrapper: Map<String, dynamic>.from(latestReport),
            title: '最近项目秘书报告',
          ),
        if (title != null)
          LuminaSection(
            title: title!,
            child: _JsonContent(data: data),
          ),
        if (data['summary'] != null || data['digest'] != null)
          LuminaSection(
            title: '内容摘要',
            child: Text(
              _str(data['summary']) ?? _displayValue(data['digest']),
              style: LuminaTheme.of(context).textTheme.bodyMedium,
            ),
          ),
        if (timeline is List)
          LuminaSection(
            title: '时间线',
            child: Column(
              children: [
                for (final entry in timeline.whereType<Map>())
                  _TimelineEntry(item: Map<String, dynamic>.from(entry)),
              ],
            ),
          ),
        if (sources.isNotEmpty)
          LuminaSection(
            title: '来源',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final source in sources)
                  if (source is Map)
                    _ExternalLink(
                      label:
                          _str(source['name']) ??
                          _str(source['title']) ??
                          '打开来源',
                      url: _linkUrl(source),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(bottom: 7),
                      child: Text(source.toString()),
                    ),
              ],
            ),
          ),
        if (rawReports is List && rawReports.isNotEmpty)
          LuminaSection(
            title: '原始秘书报告（${rawReports.length}）',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final report in rawReports)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SelectableText(_displayValue(report)),
                  ),
              ],
            ),
          ),
        if (links is Map)
          for (final entry in links.entries)
            _ExternalLink(
              label: _linkLabel(entry.key.toString()),
              url: entry.value is String ? entry.value as String : null,
            ),
        if (repositoryUrl != null)
          _ExternalLink(label: '打开 GitHub 仓库', url: repositoryUrl),
        if (project == null && latestReport == null)
          LuminaSection(
            title: title == '项目日报' ? '项目秘书报告' : '详情',
            child: _JsonContent(data: data),
          ),
      ],
    );
  }
}

class _ProjectReportsDetail extends StatelessWidget {
  const _ProjectReportsDetail({
    required this.reports,
    required this.title,
    this.payload,
    this.offline = false,
  });
  final List<Map<String, dynamic>> reports;
  final String title;
  final NewsPayload? payload;
  final bool offline;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (payload != null) _UpdateNote(payload: payload!, offline: offline),
      if (reports.isEmpty) const LuminaEmptyState(text: '尚未收到项目秘书报告'),
      for (var i = 0; i < reports.length; i++)
        _ProjectReportEntry(wrapper: reports[i], title: '$title ${i + 1}'),
    ],
  );
}

class _ProjectReportEntry extends StatelessWidget {
  const _ProjectReportEntry({required this.wrapper, required this.title});
  final Map<String, dynamic> wrapper;
  final String title;
  @override
  Widget build(BuildContext context) {
    final reportValue = wrapper['report'];
    final report = reportValue is Map
        ? Map<String, dynamic>.from(reportValue)
        : <String, dynamic>{'content': reportValue};
    final rawReports = wrapper['rawReports'] ?? report.remove('rawReports');
    final heading =
        _str(report['title']) ?? _str(wrapper['reportDate']) ?? title;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: LuminaSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    heading,
                    style: LuminaTheme.of(context).textTheme.cardTitle,
                  ),
                ),
                if (_str(wrapper['period']) != null)
                  _MetaLabel(_str(wrapper['period'])!),
              ],
            ),
            if (_str(wrapper['source']) != null)
              Padding(
                padding: const EdgeInsets.only(top: 3, bottom: 10),
                child: Text(
                  '来源 ${wrapper['source']} · ${_str(wrapper['generatedAt']) ?? '生成时间未知'}',
                  style: LuminaTheme.of(context).textTheme.bodySmall,
                ),
              ),
            _JsonContent(data: report),
            if (rawReports is List && rawReports.isNotEmpty)
              _RawReportsDisclosure(reports: rawReports),
          ],
        ),
      ),
    );
  }
}

class _RawReportsDisclosure extends StatefulWidget {
  const _RawReportsDisclosure({required this.reports});
  final List<dynamic> reports;
  @override
  State<_RawReportsDisclosure> createState() => _RawReportsDisclosureState();
}

class _RawReportsDisclosureState extends State<_RawReportsDisclosure> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 12),
      Semantics(
        expanded: _expanded,
        child: LuminaButton(
          primary: false,
          onPressed: () => setState(() => _expanded = !_expanded),
          icon: const LuminaIcon(LuminaIcons.chevronDown),
          child: Text(
            '${_expanded ? '收起' : '展开'}原始秘书报告（${widget.reports.length}）',
          ),
        ),
      ),
      if (_expanded)
        for (final report in widget.reports)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SelectableText(_displayValue(report)),
          ),
    ],
  );
}

class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({required this.item});
  final Map<String, dynamic> item;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 70,
          child: Text(
            _str(item['time']) ??
                _date(
                  DateTime.tryParse(
                    (_str(item['createdAt']) ??
                        _str(item['publishedAt']) ??
                        ''),
                  ),
                ),
            style: LuminaTheme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: Text(
            _str(item['title']) ??
                _str(item['content']) ??
                _str(item['summary']) ??
                item.toString(),
          ),
        ),
      ],
    ),
  );
}

class _StaticDetailPage extends StatelessWidget {
  const _StaticDetailPage({required this.title, required this.data, this.link});
  final String title;
  final Map<String, dynamic> data;
  final String? link;
  @override
  Widget build(BuildContext context) => LuminaPageScaffold(
    title: title,
    leading: LuminaIconButton(
      tooltip: '返回',
      onPressed: () => Navigator.of(context).maybePop(),
      icon: const LuminaIcon(LuminaIcons.back),
    ),
    body: _ResponsiveContent(
      children: [
        _DataDetail(data: data),
        if (link != null) _ExternalLink(label: '打开原文链接', url: link),
      ],
    ),
  );
}

class _ExternalLink extends StatelessWidget {
  const _ExternalLink({required this.label, required this.url});
  final String label;
  final String? url;

  @override
  Widget build(BuildContext context) {
    final uri = _httpUri(url);
    if (uri == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: LuminaButton(
          primary: false,
          onPressed: () async {
            try {
              final opened = await launchNewsLink(url);
              if (!opened && context.mounted) {
                showLuminaMessage(context, '无法打开此链接');
              }
            } catch (_) {
              if (context.mounted) {
                showLuminaMessage(context, '无法打开此链接');
              }
            }
          },
          icon: const Icon(Icons.open_in_new_rounded),
          child: Text(label),
        ),
      ),
    );
  }
}

Future<bool> launchNewsLink(String? value) async {
  final uri = _httpUri(value);
  if (uri == null) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

Uri? _httpUri(String? value) {
  final uri = Uri.tryParse(value ?? '');
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri;
}

String? _linkUrl(Map<dynamic, dynamic> value) {
  for (final key in const [
    'url',
    'href',
    'link',
    'sourceUrl',
    'originalUrl',
    'original',
    'story',
    'repositoryUrl',
    'htmlUrl',
  ]) {
    final candidate = value[key];
    if (candidate is String && _httpUri(candidate) != null) return candidate;
  }
  return null;
}

List<dynamic>? newsEventTimeline(Map<String, dynamic> data) {
  final candidates = [
    data['timeline'],
    data['storyline'],
    data['events'],
    data['reports'],
  ];
  for (final candidate in candidates) {
    if (candidate is List && candidate.isNotEmpty) return candidate;
  }
  for (final candidate in candidates) {
    if (candidate is List) return candidate;
  }
  return null;
}

List<dynamic> newsEventSources(Map<String, dynamic> data) {
  final direct = data['sources'] ?? data['sourceNames'];
  final sources = direct is List ? [...direct] : <dynamic>[];
  final reports = data['reports'];
  if (reports is! List) return sources;
  for (final report in reports.whereType<Map>()) {
    final reportLinks = report['links'];
    final url = report['url'] is String
        ? report['url'] as String
        : reportLinks is Map
        ? _linkUrl(reportLinks)
        : null;
    final source = report['source'];
    if (source is Map) {
      final sourceMap = Map<String, dynamic>.from(source);
      if (_linkUrl(sourceMap) == null && url != null) {
        sourceMap['url'] = url;
      }
      _mergeNewsSource(sources, sourceMap);
    } else if (source is String && source.isNotEmpty) {
      _mergeNewsSource(sources, {'name': source, 'url': url});
    }
  }
  return sources;
}

void _mergeNewsSource(List<dynamic> sources, Map<String, dynamic> source) {
  final name = _str(source['name']) ?? _str(source['title']);
  final url = _linkUrl(source);
  final existingIndex = sources.indexWhere((existing) {
    if (existing is Map) {
      final existingUrl = _linkUrl(existing);
      final existingName = _str(existing['name']) ?? _str(existing['title']);
      return (url != null && existingUrl == url) ||
          (name != null && existingName == name);
    }
    return name != null && existing.toString() == name;
  });
  if (existingIndex == -1) {
    sources.add(source);
  } else if (sources[existingIndex] is! Map ||
      (_linkUrl(sources[existingIndex] as Map) == null && url != null)) {
    sources[existingIndex] = source;
  }
}

String _linkLabel(String key) => switch (key) {
  'story' => '查看 AIHOT 事件',
  'original' => '打开原文链接',
  _ => '打开来源链接',
};

class _JsonContent extends StatelessWidget {
  const _JsonContent({required this.data});
  final Map<String, dynamic> data;
  static const _hidden = {
    'id',
    'publicId',
    'itemId',
    'eventId',
    'digestUpdatedAt',
    'raw',
    'metadata',
    'sources',
    'timeline',
    'events',
    'reports',
    'storyline',
    'repositoryUrl',
    'rawReports',
  };
  @override
  Widget build(BuildContext context) {
    final readme = _str(data['readme']);
    final entries = data.entries
        .where(
          (entry) =>
              !_hidden.contains(entry.key) &&
              entry.key != 'readme' &&
              entry.value != null &&
              entry.value != '',
        )
        .toList();
    if (entries.isEmpty && readme == null) {
      return const LuminaEmptyState(text: '服务端暂未提供已整理的内容', card: false);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in entries)
          if (entry.key == 'completed' ||
              entry.key == 'inProgress' ||
              entry.key == 'decisions' ||
              entry.key == 'issues' ||
              entry.key == 'next' ||
              entry.key == 'important' ||
              entry.key == 'features' ||
              entry.key == 'useCases')
            _BulletPreview(label: _fieldLabel(entry.key), values: entry.value),
        for (final entry in entries)
          if (!{
            'completed',
            'inProgress',
            'decisions',
            'issues',
            'next',
            'important',
            'features',
            'useCases',
          }.contains(entry.key))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _fieldLabel(entry.key),
                    style: LuminaTheme.of(context).textTheme.labelMedium
                        .copyWith(color: LuminaTheme.of(context).colors.muted),
                  ),
                  const SizedBox(height: 2),
                  SelectableText(_displayValue(entry.value)),
                ],
              ),
            ),
        if (readme != null)
          LuminaSection(
            title: 'README',
            child: SafeMarkdownView(source: readme),
          ),
      ],
    );
  }
}

String? _str(dynamic value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;
int? _int(dynamic value) =>
    value is int ? value : int.tryParse(value?.toString() ?? '');
String? _number(dynamic value) => value?.toString();
String _date(DateTime? value) {
  if (value == null) return '时间未知';
  final local = value.toLocal();
  return '${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

String _periodLabel(String value) => switch (value) {
  'daily' => '日报',
  'weekly' => '周报',
  _ => '月报',
};
String _fieldLabel(String key) => switch (key) {
  'repository' => '仓库',
  'ranking' => '排名',
  'period' => '周期',
  'description' => '项目介绍',
  'language' => '语言',
  'stars' => 'Stars',
  'starsInPeriod' => '本期 Stars',
  'summary' => '摘要',
  'features' => '核心功能',
  'value' => '价值',
  'useCases' => '适用场景',
  'completed' => '已完成',
  'inProgress' => '进行中',
  'decisions' => '重要决定',
  'issues' => '问题',
  'next' => '下一步',
  'important' => '今日重点',
  'status' => '状态',
  'heat' => '热度',
  'trend' => '趋势',
  'latestUpdate' => '最新进展',
  'sourceCount' => '来源数量',
  'activeProjects' => '活跃项目',
  'updatesToday' => '今日进展',
  'completedToday' => '今日完成',
  _ => key,
};
String _displayValue(dynamic value) => value is List
    ? value.map((item) => '• $item').join('\n')
    : value is Map
    ? value.entries
          .map((e) => '${_fieldLabel(e.key.toString())}: ${e.value}')
          .join('\n')
    : value.toString();
