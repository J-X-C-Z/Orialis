import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WebService {
  const WebService({
    required this.id,
    required this.name,
    required this.description,
    required this.url,
    required this.icon,
  });
  final String id, name, description, url, icon;

  WebService withUrl(String value) => WebService(
    id: id,
    name: name,
    description: description,
    url: value,
    icon: icon,
  );

  static Uri? parseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri;
  }
}

class WebServiceStore {
  WebServiceStore(this.preferences, {this.scope});
  final SharedPreferences preferences;
  final String? scope;
  static String key(String id, {String? scope}) => scope == null
      ? 'web_service_url_v1_$id'
      : 'web_service_url_v2_${jsonEncode([scope, id])}';

  Future<List<WebService>> load({required bool desktop}) async {
    final json = jsonDecode(
      await rootBundle.loadString('assets/config/web_services.json'),
    ) as List;
    return json.map((value) {
      final data = value as Map<String, dynamic>;
      final id = data['id'] as String;
      return WebService(
        id: id,
        name: data['name'] as String,
        description: data['description'] as String,
        icon: data['icon'] as String,
        url:
            preferences.getString(key(id, scope: scope)) ??
            (desktop ? data['desktopUrl'] as String? : null) ??
            data['url'] as String,
      );
    }).toList();
  }

  Future<void> saveUrl(String id, String value) async {
    final uri = WebService.parseUrl(value);
    if (uri == null) {
      throw const FormatException('请输入完整的 http 或 https 地址，不包含账号密码');
    }
    if (!await preferences.setString(key(id, scope: scope), uri.toString())) {
      throw StateError('地址未能保存');
    }
  }
}
