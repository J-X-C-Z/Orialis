import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show LinearProgressIndicator;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../app/design/design_components.dart';
import '../../pages/shared/page_parts.dart';
import 'web_service.dart';

class WebServiceBrowser extends StatefulWidget {
  const WebServiceBrowser({required this.service, super.key});
  final WebService service;
  @override
  State<WebServiceBrowser> createState() => _WebServiceBrowserState();
}

class _WebServiceBrowserState extends State<WebServiceBrowser> {
  WebViewController? _controller;
  int _progress = 0;
  String? _error;
  bool _canBack = false;
  bool _leaving = false;
  bool get _supported =>
      !kIsWeb &&
      [
        TargetPlatform.macOS,
        TargetPlatform.iOS,
        TargetPlatform.android,
      ].contains(defaultTargetPlatform);

  @override
  void initState() {
    super.initState();
    if (_supported) _initialize();
  }

  Future<void> _initialize() async {
    try {
      final controller = WebViewController();
      _controller = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) {
            if (mounted) setState(() => _progress = value);
          },
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                _error = null;
                _progress = 0;
              });
            }
          },
          onPageFinished: (_) async {
            final canBack = await controller.canGoBack();
            if (mounted) {
              setState(() {
                _canBack = canBack;
                _progress = 100;
              });
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && mounted) {
              setState(() {
                _error = '页面未能加载，请检查服务或连接后重试';
                _progress = 100;
              });
            }
          },
          onNavigationRequest: (request) =>
              WebService.parseUrl(request.url) == null
              ? NavigationDecision.prevent
              : NavigationDecision.navigate,
        ),
      );
      await controller.loadRequest(WebService.parseUrl(widget.service.url)!);
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _error = '内嵌页面未能启动，可在浏览器中打开');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) showLuminaMessage(context, '操作未能完成，请重试');
    }
  }

  Future<void> _back() async {
    final controller = _controller;
    if (controller != null && await controller.canGoBack()) {
      await controller.goBack();
      final canBack = await controller.canGoBack();
      if (mounted) setState(() => _canBack = canBack);
    } else if (mounted) {
      setState(() => _leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  Future<void> _home() async {
    await _controller?.loadRequest(WebService.parseUrl(widget.service.url)!);
  }

  Future<void> _external() async {
    final current = await _controller?.currentUrl() ?? widget.service.url;
    final uri = WebService.parseUrl(current);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) showLuminaMessage(context, '浏览器未能打开，请复制地址后重试');
    }
  }

  Future<void> _menu() async {
    final action = await showLuminaSheet<String>(
      context: context,
      builder: (context) => ContentStack(
        children: [
          for (final entry in {
            'external': '在浏览器中打开',
            'copy': '复制地址',
            'home': '返回服务首页',
            'close': '返回 Web 服务',
          }.entries)
            LuminaButton(
              primary: false,
              onPressed: () => Navigator.pop(context, entry.key),
              child: Text(entry.value),
            ),
        ],
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'external':
        await _run(_external);
      case 'copy':
        await _run(() async {
          await Clipboard.setData(
            ClipboardData(
              text: await _controller?.currentUrl() ?? widget.service.url,
            ),
          );
          if (mounted) showLuminaMessage(context, '地址已复制');
        });
      case 'home':
        await _run(_home);
      case 'close':
        setState(() => _leaving = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _leaving,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _run(_back);
    },
    child: DesktopLayoutScope(
      child: OrialisPageScaffold(
        title: widget.service.name,
        padding: EdgeInsets.zero,
        leading: LuminaIconButton(
          tooltip: _canBack ? '网页后退' : '返回 Web 服务',
          icon: const LuminaIcon(LuminaIcons.back),
          onPressed: () => _run(_back),
        ),
        actions: [
          LuminaIconButton(
            tooltip: '刷新',
            icon: const LuminaIcon(LuminaIcons.sync),
            onPressed: _controller == null
                ? null
                : () => _run(() async {
                    setState(() => _error = null);
                    await _controller!.reload();
                  }),
          ),
          LuminaIconButton(
            tooltip: '更多',
            icon: const LuminaIcon(LuminaIcons.more),
            onPressed: _menu,
          ),
        ],
        body: Column(
          children: [
            if (_progress < 100 && _supported && _error == null)
              LinearProgressIndicator(value: _progress / 100),
            Expanded(
              child: !_supported || _error != null
                  ? Center(
                      child: ContentStack(
                        children: [
                          Text(_error ?? '此平台请使用浏览器打开'),
                          if (_supported)
                            LuminaButton(
                              onPressed: () => _run(() async {
                                setState(() => _error = null);
                                if (_controller == null) {
                                  await _initialize();
                                } else {
                                  await _home();
                                }
                              }),
                              child: const Text('重试'),
                            ),
                          LuminaButton(
                            primary: false,
                            onPressed: () => _run(_external),
                            child: const Text('在浏览器中打开'),
                          ),
                        ],
                      ),
                    )
                  : _controller == null
                  ? const SizedBox.shrink()
                  : WebViewWidget(controller: _controller!),
            ),
          ],
        ),
      ),
    ),
  );
}
