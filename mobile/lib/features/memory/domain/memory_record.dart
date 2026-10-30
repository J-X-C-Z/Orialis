class MemoryRecord {
  const MemoryRecord({
    required this.id,
    required this.createdAt,
    required this.sourcePackage,
    required this.sourceLabel,
    required this.visibleText,
    required this.urls,
    required this.title,
    this.imagePath,
    this.sharedText,
    this.summary,
    this.notes = '',
    this.analysisStatus,
    this.analysisError,
    this.analysisConversationId,
    this.analysisMessageId,
    this.analysisRequestId,
    this.category,
    this.sourceUrl,
    this.videoStatus,
    this.videoSummary,
    this.videoError,
    this.cloudVersion,
    this.cloudRecordHash,
    this.cloudImageSha256,
    this.cloudDeletedAt,
    this.cloudSyncError,
  });

  final String id, sourcePackage, sourceLabel, visibleText, title, notes;
  final DateTime createdAt;
  final List<String> urls;
  final String? imagePath, sharedText, summary, analysisStatus, analysisError;
  final String? analysisConversationId, analysisMessageId, analysisRequestId;
  final String? category, sourceUrl, videoStatus, videoSummary, videoError;
  final String? cloudVersion,
      cloudRecordHash,
      cloudImageSha256,
      cloudDeletedAt,
      cloudSyncError;

  static bool isVideoUrl(String value) {
    final uri = Uri.tryParse(value);
    if (!isWebUrl(value) || uri == null) return false;
    final host = uri.host.toLowerCase();
    bool domain(String name) => host == name || host.endsWith('.$name');
    return domain('b23.tv') ||
        (domain('bilibili.com') && uri.path.startsWith('/video/')) ||
        domain('douyin.com') ||
        domain('kuaishou.com') ||
        domain('youtu.be') ||
        (domain('youtube.com') &&
            (uri.path == '/watch' || uri.path.startsWith('/shorts/')));
  }

  String? get primarySourceUrl {
    if (sourceUrl != null && isWebUrl(sourceUrl!)) return sourceUrl;
    return urls.where(isVideoUrl).firstOrNull ?? urls.firstOrNull;
  }

  bool get hasVideoSource =>
      primarySourceUrl != null && isVideoUrl(primarySourceUrl!);

  factory MemoryRecord.fromMap(Map<Object?, Object?> map) {
    final id = map['id'];
    final createdAt = map['createdAt'];
    if (id is! String || id.isEmpty || createdAt is! String) {
      throw const FormatException('记忆记录格式不正确');
    }
    String text(String key) => map[key] is String ? map[key] as String : '';
    String? optional(String key) => text(key).isEmpty ? null : text(key);
    final links = map['urls'];
    return MemoryRecord(
      id: id,
      createdAt: DateTime.parse(createdAt).toUtc(),
      sourcePackage: text('sourcePackage'),
      sourceLabel: text('sourceLabel'),
      visibleText: text('visibleText'),
      urls: List.unmodifiable(
        links is List ? links.whereType<String>().where(isWebUrl) : <String>[],
      ),
      title: text('title').trim().isEmpty ? '屏幕记忆' : text('title'),
      imagePath: optional('imagePath'),
      sharedText: optional('sharedText'),
      summary: optional('summary'),
      notes: text('notes'),
      analysisStatus: optional('analysisStatus'),
      analysisError: optional('analysisError'),
      analysisConversationId: optional('analysisConversationId'),
      analysisMessageId: optional('analysisMessageId'),
      analysisRequestId: optional('analysisRequestId'),
      category: ['ai', 'other'].contains(optional('category'))
          ? optional('category')
          : null,
      sourceUrl:
          optional('sourceUrl') != null && isWebUrl(optional('sourceUrl')!)
          ? optional('sourceUrl')
          : null,
      videoStatus: optional('videoStatus'),
      videoSummary: optional('videoSummary'),
      videoError: optional('videoError'),
      cloudVersion: optional('cloudVersion'),
      cloudRecordHash: optional('cloudRecordHash'),
      cloudImageSha256: optional('cloudImageSha256'),
      cloudDeletedAt: optional('cloudDeletedAt'),
      cloudSyncError: optional('cloudSyncError'),
    );
  }

  static bool isWebUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  bool matches(String query) {
    final needle = query.trim().toLowerCase();
    return [
      title,
      summary ?? '',
      notes,
      visibleText,
      sharedText ?? '',
      sourceLabel,
      sourcePackage,
      videoSummary ?? '',
      sourceUrl ?? '',
      ...urls,
    ].any((value) => value.toLowerCase().contains(needle));
  }

  Map<String, Object?> toCloudMap({String? imageSha256}) => {
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'sourcePackage': sourcePackage,
    'sourceLabel': sourceLabel,
    'visibleText': visibleText,
    'sharedText': sharedText,
    'urls': urls,
    'title': title,
    'summary': summary,
    'notes': notes,
    'analysisStatus': analysisStatus,
    'analysisError': analysisError,
    'analysisRequestId': analysisRequestId,
    'category': category,
    'sourceUrl': sourceUrl,
    'videoStatus': videoStatus,
    'videoSummary': videoSummary,
    'videoError': videoError,
    'imageSha256': imageSha256 ?? cloudImageSha256,
  };

  Map<String, Object?> toMap() => {
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'sourcePackage': sourcePackage,
    'sourceLabel': sourceLabel,
    'visibleText': visibleText,
    'urls': urls,
    'title': title,
    'imagePath': imagePath,
    'sharedText': sharedText,
    'summary': summary,
    'notes': notes,
    'analysisStatus': analysisStatus,
    'analysisError': analysisError,
    'analysisConversationId': analysisConversationId,
    'analysisMessageId': analysisMessageId,
    'analysisRequestId': analysisRequestId,
    'category': category,
    'sourceUrl': sourceUrl,
    'videoStatus': videoStatus,
    'videoSummary': videoSummary,
    'videoError': videoError,
    'cloudVersion': cloudVersion,
    'cloudRecordHash': cloudRecordHash,
    'cloudImageSha256': cloudImageSha256,
    'cloudDeletedAt': cloudDeletedAt,
    'cloudSyncError': cloudSyncError,
  };
}
