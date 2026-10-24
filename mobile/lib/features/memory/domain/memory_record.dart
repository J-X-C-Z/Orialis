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
  });

  final String id, sourcePackage, sourceLabel, visibleText, title, notes;
  final DateTime createdAt;
  final List<String> urls;
  final String? imagePath, sharedText, summary, analysisStatus, analysisError;
  final String? analysisConversationId, analysisMessageId;

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
      ...urls,
    ].any((value) => value.toLowerCase().contains(needle));
  }

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
  };
}
