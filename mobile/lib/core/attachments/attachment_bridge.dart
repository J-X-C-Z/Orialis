import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

enum AttachmentStatus { pending, uploading, uploaded, failed }

class AttachmentRecord {
  const AttachmentRecord({
    required this.localPath,
    required this.name,
    required this.mimeType,
    required this.size,
    this.status = AttachmentStatus.pending,
    this.id,
    this.downloadUrl,
    this.attempts = 0,
    this.lastError,
    this.lastAttemptAt,
  });

  final String localPath;
  final String name;
  final String mimeType;
  final int size;
  final AttachmentStatus status;
  final String? id;
  final String? downloadUrl;
  final int attempts;
  final String? lastError;
  final String? lastAttemptAt;

  bool get isUploaded => status == AttachmentStatus.uploaded && id != null;

  AttachmentRecord copyWith({
    AttachmentStatus? status,
    String? id,
    String? downloadUrl,
    int? attempts,
    String? lastError,
    String? lastAttemptAt,
  }) => AttachmentRecord(
    localPath: localPath,
    name: name,
    mimeType: mimeType,
    size: size,
    status: status ?? this.status,
    id: id ?? this.id,
    downloadUrl: downloadUrl ?? this.downloadUrl,
    attempts: attempts ?? this.attempts,
    lastError: lastError,
    lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
  );

  Map<String, dynamic> toJson() => {
    'localPath': localPath,
    'name': name,
    'mimeType': mimeType,
    'size': size,
    'status': status.name,
    if (id != null) 'id': id,
    if (downloadUrl != null) 'downloadUrl': downloadUrl,
    'attempts': attempts,
    if (lastError != null) 'lastError': lastError,
    if (lastAttemptAt != null) 'lastAttemptAt': lastAttemptAt,
  };

  factory AttachmentRecord.fromJson(Map<String, dynamic> json) {
    final status = AttachmentStatus.values.firstWhere(
      (value) => value.name == json['status'],
      orElse: () => json['id'] == null
          ? AttachmentStatus.pending
          : AttachmentStatus.uploaded,
    );
    return AttachmentRecord(
      localPath: json['localPath'] as String? ?? '',
      name: json['name'] as String? ?? '文件',
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      size: (json['size'] as num?)?.toInt() ?? 0,
      status: status,
      id: json['id'] as String?,
      downloadUrl: json['downloadUrl'] as String?,
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      lastError: json['lastError'] as String?,
      lastAttemptAt: json['lastAttemptAt'] as String?,
    );
  }

  /// The message API accepts only server-issued attachment IDs. The server
  /// resolves canonical metadata and enforces ownership before persistence.
  Map<String, dynamic> toMessageJson(Map<String, dynamic> uploaded) => {
    'id': uploaded['id'] ?? id,
  };
}

class AttachmentBridge {
  AttachmentBridge({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? _defaultDirectory;

  final Future<Directory> Function() _directoryProvider;

  static Future<Directory> _defaultDirectory() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/attachments');
  }

  Future<AttachmentRecord> importFile(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) throw StateError('attachment source missing');
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    final id = const Uuid().v7();
    final name = source.uri.pathSegments.last;
    final destination = File('${directory.path}/$id-$name');
    await source.copy(destination.path);
    return AttachmentRecord(
      localPath: destination.path,
      name: name,
      mimeType: _mimeType(name),
      size: await destination.length(),
    );
  }

  Future<List<AttachmentRecord>> importFiles(Iterable<String> paths) async {
    final records = <AttachmentRecord>[];
    for (final path in paths) {
      records.add(await importFile(path));
    }
    return records;
  }

  static String _mimeType(String name) {
    final extension = name.split('.').last.toLowerCase();
    const types = {
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'pdf': 'application/pdf',
    };
    return types[extension] ?? 'application/octet-stream';
  }

  static List<AttachmentRecord> decode(String value) {
    try {
      return (jsonDecode(value) as List<dynamic>)
          .map(
            (item) => AttachmentRecord.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();
    } on Object {
      return const [];
    }
  }

  static String encode(Iterable<AttachmentRecord> records) =>
      jsonEncode(records.map((record) => record.toJson()).toList());
}
