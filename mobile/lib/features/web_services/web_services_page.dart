import 'package:flutter/services.dart';
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../../pages/shared/page_parts.dart';
import 'web_service.dart';
import 'web_service_browser.dart';
import 'web_service_launcher.dart';

class WebServicesPage extends ConsumerStatefulWidget {
  const WebServicesPage({super.key});
  @override
  ConsumerState<WebServicesPage> createState() => _WebServicesPageState();
}

class _WebServicesPageState extends ConsumerState<WebServicesPage> {
  WebServiceStore? _store;
  List<WebService>? _services;
  String? _error;
  String? _starting;
  final _launcher = WebServiceLauncher();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final store = WebServiceStore(await SharedPreferences.getInstance());
      final services = await store.load(desktop: ref.read(desktopModeProvider));
      if (mounted) {
        setState(() {
          _store = store;
          _services = services;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '服务列表未能读取，请重试');
    }
  }

  Future<void> _edit(WebService service) async {
    final controller = TextEditingController(text: service.url);
    final value = await showLuminaDialog<String>(
      context: context,
      builder: (context) => LuminaDialog(
        title: '${service.name} 地址',
        content: LuminaTextField(
          controller: controller,
          label: 'Web UI 地址',
          hint: 'https://',
          keyboardType: TextInputType.url,
          autofocus: true,
        ),
        actions: [
          LuminaButton(
            primary: false,
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          LuminaButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // Dialog route may still animate out while the field is mounted.
    if (value == null || !mounted) return;
    try {
      await _store!.saveUrl(service.id, value);
      await _load();
    } on FormatException catch (error) {
      if (mounted) showLuminaMessage(context, error.message);
    } catch (_) {
      if (mounted) showLuminaMessage(context, '地址未能保存，请重试');
    }
  }

  Future<void> _open(WebService service) async {
    if (WebService.parseUrl(service.url) == null) {
      await _edit(service);
      return;
    }
    if (_starting != null || !mounted) return;
    setState(() => _starting = service.id);
    try {
      await _launcher.ensureReady(service);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => WebServiceBrowser(service: service),
        ),
      );
    } catch (error) {
      if (mounted) {
        showLuminaMessage(
          context,
          error is PlatformException
              ? error.message ?? '服务未能启动'
              : error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _starting = null);
    }
  }

  @override
  Widget build(BuildContext context) => OrialisPageScaffold(
    title: 'Web 服务',
    subtitle: '你的服务，随手可达',
    leading: ref.watch(desktopModeProvider)
        ? null
        : LuminaIconButton(
            tooltip: '返回',
            icon: const LuminaIcon(LuminaIcons.back),
            onPressed: () => context.pop(),
          ),
    body: Builder(
      builder: (context) => ListView(
        padding: EdgeInsets.only(
          top: LuminaPageHeaderInset.of(context) + 12,
          bottom: 40,
        ),
        children: [
          if (_error != null) ...[
            Text(_error!),
            LuminaButton(onPressed: _load, child: const Text('重试')),
          ] else if (_services == null)
            const QuietLabel('正在读取服务…')
          else ...[
            for (final service in _services!)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: LuminaSurface(
                  padding: const EdgeInsets.all(20),
                  child: ContentStack(
                    gap: 16,
                    children: [
                      OrialisListRow(
                        title: service.name,
                        subtitle: service.description,
                        leading: LuminaIcon(switch (service.icon) {
                          'paperclip' => LuminaIcons.folder,
                          'memory' => LuminaIcons.sparkles,
                          _ => LuminaIcons.devices,
                        }),
                        trailing: LuminaIconButton(
                          tooltip: '修改 ${service.name} 地址',
                          icon: const LuminaIcon(LuminaIcons.settings),
                          onPressed: () => _edit(service),
                        ),
                        onTap: _starting == null ? () => _open(service) : null,
                      ),
                      QuietLabel(
                        service.url.isEmpty ? '设置地址后即可打开' : service.url,
                      ),
                      LuminaButton(
                        onPressed: _starting == null
                            ? () => _open(service)
                            : null,
                        child: Text(
                          _starting == service.id
                              ? '正在启动…'
                              : service.url.isEmpty
                              ? '设置地址'
                              : '打开',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const QuietLabel('登录由各服务页面处理。电脑本地地址需要对应服务或隧道正在运行。'),
          ],
        ],
      ),
    ),
  );
}
