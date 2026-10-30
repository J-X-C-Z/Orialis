import '../../../app/design/mobile_motion.dart';

import 'dart:io';

import 'package:flutter/material.dart'
    show
        Icons,
        IconButton,
        Material,
        MaterialPageRoute,
        MaterialType,
        RefreshIndicator;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/design/lumina_compat.dart';
import '../../chat/presentation/safe_markdown.dart';
import '../data/memory_repository.dart';
import '../domain/memory_record.dart';

class MemoryPage extends StatefulWidget {
  const MemoryPage({
    super.key,
    this.repository,
    this.onAnalyze,
    this.desktop = false,
  });
  final bool desktop;
  final MemoryRepository? repository;
  final Future<void> Function(MemoryRecord)? onAnalyze;

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> with WidgetsBindingObserver {
  late final repository = widget.repository ?? MemoryRepository();
  final search = TextEditingController();
  List<MemoryRecord>? records;
  MemoryStatus? status;
  Map<String, dynamic> shortcuts = defaultMemoryShortcuts;
  String? error;
  int generation = 0;
  String categoryFilter = 'all';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    repository.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    repository.removeListener(_load);
    if (widget.repository == null) repository.dispose();
    search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final request = ++generation;
    try {
      final nextStatus = await repository.status();
      final nextShortcuts =
          widget.desktop && nextStatus.supported && nextStatus.captureSupported
          ? await repository.getShortcuts()
          : shortcuts;
      final next = nextStatus.supported
          ? await repository.list()
          : <MemoryRecord>[];
      if (!mounted || request != generation) return;
      setState(() {
        status = nextStatus;
        if (nextShortcuts['screen'] is Map &&
            nextShortcuts['selection'] is Map) {
          shortcuts = nextShortcuts;
        }
        records = next;
        error = null;
      });
    } catch (_) {
      if (mounted && request == generation) {
        setState(() {
          records = null;
          error = '记忆未能读取，请确认已登录后重试';
        });
      }
    }
  }

  Future<void> _refresh() async {
    await repository.sync();
    if (mounted) await _load();
  }

  Future<void> _open(MemoryRecord record) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _MemoryDetailPage(
          record: record,
          repository: repository,
          onAnalyze: widget.onAnalyze,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _captureSettings() async {
    try {
      if (widget.desktop) {
        await repository.openCaptureSettings();
        return;
      }
      final current = await repository.status();
      if (!mounted) return;
      final openSettings = await showLuminaDialog<bool>(
        context: context,
        builder: (context) => LuminaDialog(
          title: current.silentCaptureEnabled ? '辅助截屏已启用' : '免重复确认截屏',
          content: Text(
            current.silentCaptureSupported
                ? '${current.silentCaptureEnabled ? '快捷键将直接保存屏幕。' : '在系统中启用一次「Orialis 辅助截屏」后，快捷键无需逐次确认截屏。'}'
                      '\n\n仅在你点击快捷键时读取屏幕与可见文字，保存后停留在原应用。未启用时继续使用系统截屏确认。'
                : '这台手机使用系统截屏方式，每次截屏仍需系统确认。保存后会停留在原应用。',
          ),
          actions: [
            LuminaButton(
              primary: false,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('关闭'),
            ),
            if (current.silentCaptureSupported)
              LuminaButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(current.silentCaptureEnabled ? '管理授权' : '打开系统设置'),
              ),
          ],
        ),
      );
      if (openSettings == true) await repository.openCaptureSettings();
    } catch (_) {
      if (mounted) showLuminaMessage(context, '截屏设置暂时无法打开，请稍后重试');
    }
  }

  Future<void> _shortcutSettings() async {
    var suspended = false;
    try {
      await repository.setShortcutRecording(true);
      suspended = true;
      if (!mounted) return;
      await showLuminaDialog<void>(
        context: context,
        builder: (_) =>
            _MemoryShortcutsDialog(repository: repository, initial: shortcuts),
      );
    } on PlatformException catch (error) {
      if (mounted) showLuminaMessage(context, error.message ?? '快捷键设置未能打开');
    } finally {
      if (suspended) {
        try {
          await repository.setShortcutRecording(false);
        } on PlatformException catch (error) {
          if (mounted) {
            showLuminaMessage(context, error.message ?? '快捷键未能恢复，请重新设置');
          }
        }
      }
      if (mounted) await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = records
        ?.where(
          (record) =>
              record.matches(search.text) ||
              [record.summary, record.videoSummary].any(
                (text) =>
                    responseUiPlainText(text ?? '')
                        .toLowerCase()
                        .contains(search.text.trim().toLowerCase()),
              ),
        )
        .where((record) => categoryFilter == 'all' || record.category == 'ai')
        .toList();
    return OrialisPageScaffold(
      padding: EdgeInsets.zero,
      title: '屏幕记忆',
      subtitle: '把正在看的内容，留给以后的自己',
      leading: widget.desktop
          ? null
          : LuminaIconButton(
              tooltip: '返回',
              icon: const LuminaIcon(LuminaIcons.back),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
      actions: [
        if (widget.desktop &&
            status?.supported == true &&
            status?.captureSupported == true)
          LuminaIconButton(
            tooltip: '记录屏幕',
            icon: const Icon(Icons.screenshot_monitor),
            onPressed: () async {
              try {
                await repository.capture();
              } on PlatformException catch (error) {
                if (!context.mounted) return;
                showLuminaMessage(context, error.message ?? '屏幕未能记录，请检查系统授权');
              }
            },
          ),

        if (status?.supported == true && status?.captureSupported == true)
          LuminaIconButton(
            tooltip: '截屏设置',
            icon: const Icon(Icons.tune),
            onPressed: _captureSettings,
          ),
        LuminaIconButton(
          tooltip: '刷新记忆',
          icon: const LuminaIcon(LuminaIcons.sync),
          onPressed: _refresh,
        ),
      ],
      body: Builder(
        builder: (context) => OrialisContentTransition(
          changeKey: categoryFilter,
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: LuminaPageHeaderInset.of(context) + 12,
                bottom: MediaQuery.paddingOf(context).bottom + 40,
              ),
              itemCount: 1 + (filtered?.length ?? 0),
              itemBuilder: (context, index) {
                if (index > 0) {
                  final record = filtered![index - 1];
                  final preview = _preview(record.summary);
                  final sourceUrl = record.primarySourceUrl;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: LuminaListRow(
                      title: record.title,
                      subtitle:
                          '${_source(record)} · ${_time(record.createdAt)}\n${_analysisLabel(record.analysisStatus)}',
                      detail: record.category == 'ai' || preview.isNotEmpty
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (record.category == 'ai')
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: LuminaTheme.of(context)
                                          .colors
                                          .accentSoft,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 2,
                                      ),
                                      child: Text(
                                        'AI',
                                        style: LuminaTheme.of(context)
                                            .textTheme
                                            .labelSmall,
                                      ),
                                    ),
                                  ),
                                if (preview.isNotEmpty) ...[
                                  if (record.category == 'ai')
                                    const SizedBox(height: 6),
                                  Text(
                                    preview,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: LuminaTheme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ],
                              ],
                            )
                          : null,
                      leading: SizedBox(
                        width: 48,
                        height: 64,
                        child: _MemoryImage(
                          path: record.imagePath,
                          thumbnail: true,
                        ),
                      ),
                      trailing: Material(
                        type: MaterialType.transparency,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (sourceUrl != null)
                              IconButton(
                                tooltip: record.hasVideoSource
                                    ? '打开原视频'
                                    : '打开原链接',
                                onPressed: () =>
                                    _launchSourceUrl(context, sourceUrl),
                                icon: const Icon(Icons.open_in_new),
                              ),
                            const LuminaIcon(LuminaIcons.chevronRight),
                          ],
                        ),
                      ),
                      onTap: () => _open(record),
                    ),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LuminaTextField(
                      controller: search,
                      hint: '搜索标题、内容或链接',
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 16),
                    Material(
                      type: MaterialType.transparency,
                      child: Wrap(
                        spacing: 8,
                        children: [
                          LuminaChip(
                            label: const Text('全部'),
                            selected: categoryFilter == 'all',
                            onSelected: (_) =>
                                setState(() => categoryFilter = 'all'),
                          ),
                          LuminaChip(
                            label: const Text('AI'),
                            selected: categoryFilter == 'ai',
                            onSelected: (_) =>
                                setState(() => categoryFilter = 'ai'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (error != null) ...[
                      Text(error!),
                      LuminaButton(onPressed: _load, child: const Text('重试')),
                    ] else if (status == null)
                      const Text('正在读取记忆…')
                    else if (!status!.supported)
                      Text(
                        widget.desktop
                            ? '当前电脑尚不支持屏幕捕获。'
                            : '屏幕记忆需要支持截屏的 Android 手机。',
                      )
                    else ...[
                      if (widget.desktop) ...[
                        Text(
                          '全局快捷键：${memoryShortcutLabel(shortcuts['screen'] as Map)} 记录屏幕 · ${memoryShortcutLabel(shortcuts['selection'] as Map)} 记录选中文字',
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: LuminaButton(
                            primary: false,
                            onPressed: _shortcutSettings,
                            child: const Text('自定义快捷键'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text('保持 Orialis 运行即可使用；首次使用请按系统提示授权。'),
                        const SizedBox(height: 12),
                      ],
                      if (filtered!.isEmpty)
                        Text(
                          search.text.isEmpty
                              ? categoryFilter == 'ai'
                                    ? '还没有 AI 记忆，相关内容会自动归入这里。'
                                    : widget.desktop
                                    ? '还没有记忆。使用快捷键记录屏幕或选中的文字，保存后自动后台理解。'
                                    : '还没有记忆。从控制中心截屏，或将图文、链接分享到「Orialis 记忆」。'
                              : '没有找到匹配的记忆',
                        ),
                    ],
                    const SizedBox(height: 8),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _MemoryDetailPage extends StatefulWidget {
  const _MemoryDetailPage({
    required this.record,
    required this.repository,
    this.onAnalyze,
  });
  final MemoryRecord record;
  final MemoryRepository repository;
  final Future<void> Function(MemoryRecord)? onAnalyze;
  @override
  State<_MemoryDetailPage> createState() => _MemoryDetailPageState();
}

class _MemoryDetailPageState extends State<_MemoryDetailPage> {
  late MemoryRecord record = widget.record;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    widget.repository.addListener(_reload);
  }

  @override
  void dispose() {
    widget.repository.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final updated = await widget.repository.read(record.id);
      if (mounted) setState(() => record = updated);
    } catch (_) {
      // A deleted record is closed by its delete action; leave on-screen text intact on temporary read errors.
    }
  }

  Future<void> _perform(Future<void> Function() operation) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await operation();
    } catch (_) {
      if (mounted) showLuminaMessage(context, '操作未完成，请重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> _confirm(String title, String content, String action) async =>
      await showLuminaDialog<bool>(
        context: context,
        builder: (context) => LuminaDialog(
          title: title,
          content: Text(content),
          actions: [
            LuminaButton(
              primary: false,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            LuminaButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _analyze() async {
    await _perform(() async {
      await widget.onAnalyze!(record);
      final updated = await widget.repository.read(record.id);
      if (mounted) setState(() => record = updated);
    });
  }

  Future<void> _edit() async {
    final title = TextEditingController(text: record.title);
    final notes = TextEditingController(text: record.notes);
    final fields = await showLuminaDialog<Map<String, Object?>>(
      context: context,
      builder: (context) => LuminaDialog(
        title: '编辑记忆',
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LuminaTextField(controller: title, label: '标题', maxLength: 200),
              const SizedBox(height: 16),
              LuminaTextField(
                controller: notes,
                label: '我的笔记',
                minLines: 3,
                maxLines: 8,
                maxLength: 20000,
              ),
            ],
          ),
        ),
        actions: [
          LuminaButton(
            primary: false,
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          LuminaButton(
            onPressed: () => Navigator.pop(context, <String, Object?>{
              'title': title.text.trim().isEmpty
                  ? record.title
                  : title.text.trim(),
              'notes': notes.text,
            }),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // Wait for the dialog transition before disposing its field controllers.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    title.dispose();
    notes.dispose();
    if (fields == null || !mounted) return;
    await _perform(() async {
      final updated = await widget.repository.update(record.id, fields);
      if (mounted) setState(() => record = updated);
    });
  }

  Future<void> _delete() async {
    if (!await _confirm('删除这条记忆？', '将从本账号的记忆列表移除，并同步到其他设备。本机原始副本会保留。', '删除')) {
      return;
    }
    if (!mounted) return;
    await _perform(() async {
      await widget.repository.delete(record.id);
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _openUrl(String url) async {
    await _launchSourceUrl(context, url);
  }

  @override
  Widget build(BuildContext context) => OrialisPageScaffold(
    padding: EdgeInsets.zero,
    title: record.title,
    subtitle: '${_source(record)} · ${_time(record.createdAt)}',
    leading: LuminaIconButton(
      tooltip: '返回',
      icon: const LuminaIcon(LuminaIcons.back),
      onPressed: () => Navigator.maybePop(context),
    ),
    body: Builder(
      builder: (context) => ListView(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: LuminaPageHeaderInset.of(context) + 12,
          bottom: MediaQuery.paddingOf(context).bottom + 40,
        ),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (widget.onAnalyze != null &&
                  record.analysisStatus != 'completed')
                LuminaButton(
                  onPressed: busy || record.analysisStatus == 'analyzing'
                      ? null
                      : _analyze,
                  child: Text(
                    busy
                        ? '正在处理…'
                        : record.analysisStatus == 'failed'
                        ? '重试理解'
                        : record.analysisStatus == 'analyzing'
                        ? '正在理解…'
                        : '开始理解',
                  ),
                ),
              if (widget.onAnalyze != null &&
                  record.videoStatus == 'unavailable')
                LuminaButton(
                  primary: false,
                  onPressed: busy ? null : _analyze,
                  child: Text(busy ? '正在处理…' : '重试视频理解'),
                ),
              if (record.primarySourceUrl != null)
                LuminaButton(
                  onPressed: busy
                      ? null
                      : () => _openUrl(record.primarySourceUrl!),
                  child: Text(record.hasVideoSource ? '打开原视频' : '打开原链接'),
                ),
              LuminaButton(
                primary: false,
                onPressed: busy ? null : _edit,
                child: const Text('编辑笔记'),
              ),
              LuminaButton(
                primary: false,
                onPressed: busy ? null : _delete,
                child: const Text('删除记忆'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(_analysisLabel(record.analysisStatus)),
          const SizedBox(height: 8),
          Text(
            record.cloudSyncError == 'pending' || record.cloudVersion == null
                ? '已保存在本机，等待云同步'
                : record.cloudSyncError ?? '已同步到云端',
          ),
          if (record.analysisStatus == 'failed') ...[
            const SizedBox(height: 12),
            Text(record.analysisError ?? '上次分析未完成，原始记忆仍保存在本机，可以重新分析。'),
          ],
          if (record.summary != null) ...[
            const SizedBox(height: 20),
            if (LuminaGlassTitleScope.of(context))
              const LuminaCardHeader(title: '内容摘要')
            else
              const Text('内容摘要'),
            const SizedBox(height: 8),
            SafeMarkdownView(source: record.summary!, allowResponseUi: true),
          ],
          if (record.videoStatus == 'analyzed' ||
              record.videoStatus == 'unavailable') ...[
            const SizedBox(height: 20),
            if (LuminaGlassTitleScope.of(context))
              const LuminaCardHeader(title: '视频理解')
            else
              const Text('视频理解'),
            const SizedBox(height: 8),
            if (record.videoStatus == 'analyzed')
              SafeMarkdownView(
                allowResponseUi: true,
                source: record.videoSummary?.trim().isNotEmpty == true
                    ? record.videoSummary!
                    : '视频已理解，但没有可显示的摘要。',
              )
            else ...[
              Text(
                '${record.videoError?.trim().isNotEmpty == true ? record.videoError! : '暂时无法获取视频内容。'}\n截图、分享文案和原始链接仍可查看。',
              ),
            ],
          ],
          if (record.notes.isNotEmpty) ...[
            const SizedBox(height: 20),
            if (LuminaGlassTitleScope.of(context))
              const LuminaCardHeader(title: '我的笔记')
            else
              const Text('我的笔记'),
            const SizedBox(height: 8),
            LuminaSelectableText(record.notes),
          ],
          const SizedBox(height: 20),
          if (LuminaGlassTitleScope.of(context))
            const LuminaCardHeader(title: '捕获到的链接')
          else
            const Text('捕获到的链接'),
          if (record.urls.isEmpty)
            const Text('这次未获取到链接。可在原应用通过「分享 → Orialis 记忆」保存原始链接。'),
          for (final url in record.urls)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LuminaSurface(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LuminaSelectableText(url),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        LuminaButton(
                          primary: false,
                          onPressed: () => _openUrl(url),
                          child: const Text('打开链接'),
                        ),
                        LuminaButton(
                          primary: false,
                          onPressed: () => _perform(() async {
                            await Clipboard.setData(ClipboardData(text: url));
                            if (context.mounted) {
                              showLuminaMessage(context, '链接已复制');
                            }
                          }),
                          child: const Text('复制链接'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (record.imagePath != null) ...[
            const SizedBox(height: 20),
            if (LuminaGlassTitleScope.of(context))
              const LuminaCardHeader(title: '原始截图')
            else
              const Text('原始截图'),
            const SizedBox(height: 8),
            _MemoryImage(
              key: const ValueKey('memory-original-screenshot'),
              path: record.imagePath,
            ),
          ],
          const SizedBox(height: 20),
          if (LuminaGlassTitleScope.of(context))
            const LuminaCardHeader(title: '原始内容')
          else
            const Text('原始内容'),
          const SizedBox(height: 8),
          const Text('这里保留实际收到的截图、分享文案和链接，不代表已获取笔记或视频全文。'),
          const SizedBox(height: 8),
          LuminaSelectableText(
            [record.visibleText, record.sharedText ?? '']
                    .where((text) => text.isNotEmpty)
                    .toSet()
                    .join('\n\n')
                    .trim()
                    .isEmpty
                ? '未获取到可读文字，可通过截图进行分析。'
                : [
                    record.visibleText,
                    record.sharedText ?? '',
                  ].where((text) => text.isNotEmpty).toSet().join('\n\n'),
          ),
        ],
      ),
    ),
  );
}

class _MemoryImage extends StatelessWidget {
  const _MemoryImage({required this.path, this.thumbnail = false, super.key});
  final String? path;
  final bool thumbnail;
  @override
  Widget build(BuildContext context) {
    final fallback = Center(
      child: LuminaIcon(thumbnail ? LuminaIcons.file : LuminaIcons.image),
    );
    if (path == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.file(
        File(path!),
        fit: thumbnail ? BoxFit.cover : BoxFit.contain,
        cacheWidth: thumbnail ? 144 : 1080,
        semanticLabel: '保存的屏幕截图',
        errorBuilder: (_, _, _) => thumbnail
            ? fallback
            : const Padding(
                padding: EdgeInsets.all(20),
                child: Text('截图文件无法读取，文字和链接仍可使用。'),
              ),
      ),
    );
  }
}

String _source(MemoryRecord record) => record.sourceLabel.isNotEmpty
    ? record.sourceLabel
    : record.sourcePackage.isNotEmpty
    ? record.sourcePackage
    : '分享内容';

Future<void> _launchSourceUrl(BuildContext context, String url) async {
  try {
    if (!MemoryRecord.isWebUrl(url) ||
        !await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        )) {
      if (context.mounted) showLuminaMessage(context, '链接未能打开，可以复制后使用');
    }
  } catch (_) {
    if (context.mounted) showLuminaMessage(context, '链接未能打开，可以复制后使用');
  }
}

String _preview(String? summary) {
  final lines = responseUiPlainText(summary ?? '').trim().split('\n');
  if (lines.first.trim().startsWith(RegExp(r'#{1,6}\s'))) lines.removeAt(0);
  return lines
      .skipWhile((line) => line.trim().isEmpty)
      .takeWhile((line) => line.trim().isNotEmpty)
      .map((line) => line.trim())
      .join(' ');
}

String _analysisLabel(String? status) => switch (status) {
  'pending' => '等待 Azure Hermes 理解',
  'analyzing' => 'Azure Hermes 正在理解',
  'completed' => 'Azure Hermes 已整理',
  'failed' => '理解未完成，可重试',
  _ => '已保存在本机',
};

String _time(DateTime date) {
  final local = date.toLocal();
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${pad(local.month)}-${pad(local.day)} ${pad(local.hour)}:${pad(local.minute)}';
}

class _MemoryShortcutsDialog extends StatefulWidget {
  const _MemoryShortcutsDialog({
    required this.repository,
    required this.initial,
  });
  final MemoryRepository repository;
  final Map<String, dynamic> initial;
  @override
  State<_MemoryShortcutsDialog> createState() => _MemoryShortcutsDialogState();
}

class _MemoryShortcutsDialogState extends State<_MemoryShortcutsDialog> {
  late Map<String, dynamic> shortcuts = {
    for (final entry in widget.initial.entries)
      entry.key: Map<String, dynamic>.from(entry.value as Map),
  };
  final focus = FocusNode();
  String? recording;
  String? error;
  bool saving = false;

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (recording == null || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => recording = null);
      return KeyEventResult.handled;
    }
    final key = event.logicalKey.keyLabel.toUpperCase();
    final keyboard = HardwareKeyboard.instance;
    if (!RegExp(r'^[A-Z0-9]$').hasMatch(key)) return KeyEventResult.handled;
    if (!keyboard.isMetaPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isControlPressed) {
      setState(() => error = '请同时按住 ⌘、⌥ 或 ⌃ 中的至少一个键');
      return KeyEventResult.handled;
    }
    setState(() {
      shortcuts[recording!] = {
        'key': key,
        'command': keyboard.isMetaPressed,
        'option': keyboard.isAltPressed,
        'control': keyboard.isControlPressed,
        'shift': keyboard.isShiftPressed,
      };
      recording = null;
      error = null;
    });
    return KeyEventResult.handled;
  }

  Future<void> _save() async {
    if (saving) return;
    if (memoryShortcutLabel(shortcuts['screen'] as Map) ==
        memoryShortcutLabel(shortcuts['selection'] as Map)) {
      setState(() => error = '两项快捷键不能相同');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.repository.setShortcuts(shortcuts);
      if (mounted) Navigator.pop(context);
    } on PlatformException catch (failure) {
      if (mounted) setState(() => error = failure.message ?? '快捷键已被占用，请选择其他组合');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focus,
    onKeyEvent: _key,
    child: LuminaDialog(
      title: '记忆快捷键',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('点击一项后按下组合键，使用字母或数字，并包含 ⌘、⌥ 或 ⌃。设置期间暂停记忆全局快捷键。'),
          const SizedBox(height: 12),
          for (final entry in const {
            'screen': '记录屏幕',
            'selection': '记录选中文字',
          }.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: LuminaButton(
                key: ValueKey('memory-shortcut-${entry.key}'),
                primary: recording == entry.key,
                onPressed: saving
                    ? null
                    : () {
                        setState(() {
                          recording = entry.key;
                          error = null;
                        });
                        focus.requestFocus();
                      },
                child: Text(
                  '${entry.value}：${recording == entry.key ? '请按下组合键…' : memoryShortcutLabel(shortcuts[entry.key] as Map)}',
                ),
              ),
            ),
          if (error != null) Text(error!),
        ],
      ),
      actions: [
        LuminaButton(
          primary: false,
          onPressed: saving
              ? null
              : () => setState(() {
                  shortcuts = {
                    for (final entry in defaultMemoryShortcuts.entries)
                      entry.key: Map<String, dynamic>.from(entry.value),
                  };
                  recording = null;
                  error = null;
                }),
          child: const Text('恢复默认'),
        ),
        LuminaButton(
          primary: false,
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        LuminaButton(
          onPressed: saving || recording != null ? null : _save,
          child: Text(saving ? '保存中…' : '保存'),
        ),
      ],
    ),
  );
}
