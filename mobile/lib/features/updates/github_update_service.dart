import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class GithubReleaseUpdate {
  const GithubReleaseUpdate({
    required this.version,
    required this.releaseUrl,
    required this.downloadUrl,
    required this.sha256,
    required this.size,
    required this.notes,
  });

  final String version;
  final Uri releaseUrl;
  final Uri downloadUrl;
  final String sha256;
  final int size;
  final String notes;
}

class GithubUpdateService {
  GithubUpdateService({Dio? dio}) : _dio = dio ?? Dio();

  static const _installChannel = MethodChannel('top.jxcz.orialis/updates');
  static const _releaseApi =
      'https://api.github.com/repos/J-X-C-Z/Orialis/releases/latest';
  final Dio _dio;

  Future<String> installedVersion() async =>
      await _installChannel.invokeMethod<String>('getInstalledVersion') ?? '';

  Future<GithubReleaseUpdate?> checkForUpdate() async {
    final localVersionString = await installedVersion();
    final response = await _dio.get<Object?>(
      _releaseApi,
      options: Options(
        headers: const {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'User-Agent': 'Orialis-Android-Updater',
        },
        receiveTimeout: const Duration(seconds: 20),
      ),
    );
    final release = response.data;
    if (release is! Map<String, dynamic> || release['draft'] == true) {
      throw const FormatException('GitHub 返回的版本信息无效');
    }

    final tag = release['tag_name'];
    final releaseHtml = release['html_url'];
    final assets = release['assets'];
    if (tag is! String || releaseHtml is! String || assets is! List) {
      throw const FormatException('GitHub 发布内容缺少必要信息');
    }
    final remoteVersion = _versionParts(tag);
    final localVersion = _versionParts(localVersionString);
    if (remoteVersion == null || localVersion == null) {
      throw const FormatException('版本号格式无法识别');
    }
    if (_compareVersions(remoteVersion, localVersion) <= 0) return null;

    final asset = assets.whereType<Map<String, dynamic>>().where((asset) {
      final name = asset['name'];
      return name is String &&
          name == 'Orialis-${remoteVersion.join('.')}-arm64.apk';
    }).firstOrNull;
    if (asset == null) throw const FormatException('此版本没有 Android arm64 安装包');

    final download = asset['browser_download_url'];
    final digest = asset['digest'];
    final size = asset['size'];
    final releaseUri = Uri.tryParse(releaseHtml);
    final downloadUri = download is String ? Uri.tryParse(download) : null;
    final expectedDigest = digest is String
        ? RegExp(r'^sha256:([a-fA-F0-9]{64})$').firstMatch(digest)?.group(1)
        : null;
    if (releaseUri == null ||
        releaseUri.scheme != 'https' ||
        releaseUri.host != 'github.com' ||
        downloadUri == null ||
        downloadUri.scheme != 'https' ||
        downloadUri.host != 'github.com' ||
        !downloadUri.path.startsWith('/J-X-C-Z/Orialis/releases/download/') ||
        expectedDigest == null ||
        size is! int ||
        size <= 0 ||
        size > 500 * 1024 * 1024) {
      throw const FormatException('GitHub 安装包地址或校验信息无效');
    }

    return GithubReleaseUpdate(
      version: remoteVersion.join('.'),
      releaseUrl: releaseUri,
      downloadUrl: downloadUri,
      sha256: expectedDigest.toLowerCase(),
      size: size,
      notes: release['body'] is String ? release['body'] as String : '',
    );
  }

  Future<void> downloadAndInstall(
    GithubReleaseUpdate update, {
    required void Function(int received, int total) onProgress,
  }) async {
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/orialis-${update.version}-arm64.apk');
    if (await file.exists()) await file.delete();
    try {
      await _dio.download(
        update.downloadUrl.toString(),
        file.path,
        deleteOnError: true,
        onReceiveProgress: onProgress,
        options: Options(
          headers: const {'User-Agent': 'Orialis-Android-Updater'},
          receiveTimeout: const Duration(minutes: 5),
        ),
      );
      if (await file.length() != update.size) {
        throw const FormatException('下载文件大小与 GitHub 记录不一致');
      }
      final actualDigest = (await sha256.bind(file.openRead()).first)
          .toString();
      if (actualDigest != update.sha256) {
        throw const FormatException('安装包 SHA-256 校验失败');
      }
      final result = await _installChannel.invokeMethod<String>('installApk', {
        'path': file.path,
      });
      if (result == 'permissionRequired') {
        throw const UpdateInstallPermissionException();
      }
      if (result != 'opened') {
        throw PlatformException(code: 'install_failed');
      }
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  List<int>? _versionParts(String value) {
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+[0-9]+)?$')
        .firstMatch(value.trim());
    if (match == null) return null;
    return [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
  }

  int _compareVersions(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      final compared = a[i].compareTo(b[i]);
      if (compared != 0) return compared;
    }
    return 0;
  }
}

class UpdateInstallPermissionException implements Exception {
  const UpdateInstallPermissionException();
}
