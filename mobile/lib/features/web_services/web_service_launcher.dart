import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'web_service.dart';

/// Only service IDs cross the bridge; web content cannot run commands.
class WebServiceLauncher {
  WebServiceLauncher({this.checkReady, this.startService});
  final Future<bool> Function(Uri)? checkReady;
  final Future<void> Function(String)? startService;
  static const _channel = MethodChannel('top.jxcz.orialis/web_services');
  final Dio _http = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 2),
      followRedirects: false,
      validateStatus: (_) => true,
    ),
  );

  Future<bool> _ready(Uri uri) async {
    if (checkReady != null) return checkReady!(uri);
    try {
      final local = ['127.0.0.1', 'localhost'].contains(uri.host);
      final probe = local && uri.port == 3100
          ? uri.replace(path: '/api/health', query: '')
          : local && uri.port == 8876
          ? uri.replace(path: '/api/state', query: '')
          : uri;
      final response = await _http.getUri<Object>(probe);
      if (local && uri.port == 3100) {
        final data = response.data;
        return data is Map &&
            data['status'] == 'ok' &&
            data['startupRecovery'] is Map &&
            data['startupRecovery']['phase'] == 'ready';
      }
      if (local && uri.port == 8876) {
        return response.statusCode == 200 &&
            response.data is Map &&
            (response.data as Map).containsKey('servers');
      }
      final code = response.statusCode ?? 0;
      return code >= 200 && code < 400 || code == 401 || code == 403;
    } catch (_) {
      return false;
    }
  }

  Future<void> ensureReady(WebService service) async {
    final uri = WebService.parseUrl(service.url);
    if (uri == null) throw const FormatException('请先设置服务地址');
    if (await _ready(uri)) return;
    // A customized remote endpoint must never start an unrelated local process.
    final defaultPort = {
      'paperclip': 3100,
      'server-monitor': 8876,
      'hindsight': 29999,
    }[service.id];
    if (!['127.0.0.1', 'localhost'].contains(uri.host) ||
        uri.port != defaultPort) {
      throw StateError('无法连接此地址，请检查服务是否已启动');
    }
    if (startService != null) {
      await startService!(service.id);
    } else {
      await _channel.invokeMethod<void>('start', {'id': service.id});
    }
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      if (await _ready(uri)) return;
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    throw StateError('服务启动超时，请检查后台服务或 SSH 连接后重试');
  }
}
