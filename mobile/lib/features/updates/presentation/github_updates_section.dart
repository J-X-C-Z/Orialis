import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/pages/shared/page_parts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../github_update_service.dart';

class GithubUpdatesSection extends StatefulWidget {
  const GithubUpdatesSection({super.key});

  @override
  State<GithubUpdatesSection> createState() => _GithubUpdatesSectionState();
}

class _GithubUpdatesSectionState extends State<GithubUpdatesSection> {
  final _service = GithubUpdateService();
  String _installedVersion = '…';
  String? _message;
  GithubReleaseUpdate? _update;
  bool _checking = false;
  bool _downloading = false;
  double? _progress;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _service.installedVersion().then((version) {
        if (mounted) setState(() => _installedVersion = version);
      });
    }
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _message = null;
      _update = null;
    });
    try {
      final update = await _service.checkForUpdate();
      if (!mounted) return;
      setState(() {
        _update = update;
        _message = update == null ? '当前已是最新版本' : '发现新版本 ${update.version}';
      });
    } catch (_) {
      if (mounted) setState(() => _message = '暂时无法读取 GitHub 版本信息，请稍后重试');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _download() async {
    final update = _update;
    if (update == null) return;
    setState(() {
      _downloading = true;
      _progress = 0;
      _message = '正在下载并校验安装包…';
    });
    try {
      await _service.downloadAndInstall(
        update,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() => _progress = total > 0 ? received / total : null);
        },
      );
      if (mounted) setState(() => _message = '安装程序已打开，请确认安装 Orialis 更新');
    } on UpdateInstallPermissionException {
      if (mounted) {
        setState(() => _message = '请在系统设置中允许 Orialis 安装此来源的应用，然后再次点击安装');
      }
    } catch (_) {
      if (mounted) setState(() => _message = '下载或校验失败，请检查网络后重试');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _openRelease() async {
    final uri =
        _update?.releaseUrl ??
        Uri.parse('https://github.com/J-X-C-Z/Orialis/releases/latest');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    return LuminaSection(
      title: '软件更新',
      child: ContentStack(
        gap: 12,
        children: [
          QuietLabel('当前版本 $_installedVersion · 更新来自 Orialis GitHub Release'),
          if (_message != null) QuietLabel(_message!),
          if (_downloading) LinearProgressIndicator(value: _progress),
          if (_update != null && !_downloading) ...[
            if (_update!.notes.trim().isNotEmpty)
              Text(
                _update!.notes.trim(),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
            LuminaButton(onPressed: _download, child: const Text('下载并安装')),
          ],
          if (_update == null && !_checking)
            LuminaButton(
              primary: false,
              onPressed: _checking ? null : _check,
              child: const Text('检查 GitHub 更新'),
            ),
          if (_update != null)
            TextButton(
              onPressed: _openRelease,
              child: const Text('查看 GitHub 发行说明'),
            ),
          if (_checking) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
