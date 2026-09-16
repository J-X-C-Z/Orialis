import 'package:dio/dio.dart';

import '../config/app_config.dart';

class SessionResponse {
  const SessionResponse({
    required this.userId,
    required this.accessToken,
    required this.expiresAt,
  });

  final String userId;
  final String accessToken;
  final DateTime expiresAt;

  factory SessionResponse.fromJson(Map<String, dynamic> json) {
    return SessionResponse(
      userId: json['userId'] as String,
      accessToken: json['accessToken'] as String,
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
  }
}

class AttachmentUpload {
  const AttachmentUpload({
    required this.path,
    required this.name,
    required this.mimeType,
  });

  final String path;
  final String name;
  final String mimeType;
}

class OrialisApiClient {
  OrialisApiClient({
    required this.baseUrl,
    required this.deviceId,
    AppConfig? config,
  }) : _config = config ?? AppConfig(),
       _dio = Dio(
         BaseOptions(
           baseUrl: baseUrl,
           connectTimeout: const Duration(seconds: 4),
           receiveTimeout: const Duration(seconds: 8),
           headers: {'X-Orialis-Device-Id': deviceId},
         ),
       ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await _config.sessionToken();
          if (token != null) {
            options.headers['Authorization'] = 'Session $token';
          }
          handler.next(options);
        },
      ),
    );
  }

  final String baseUrl;
  final String deviceId;
  final AppConfig _config;
  final Dio _dio;

  Future<SessionResponse> register({
    required String username,
    required String password,
  }) => _authenticate('/api/v1/auth/register', username, password);

  Future<SessionResponse> login({
    required String username,
    required String password,
  }) => _authenticate('/api/v1/auth/login', username, password);

  Future<Map<String, dynamic>> session() async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/v1/auth/session',
    );
    return response.data ?? <String, dynamic>{};
  }

  Future<void> logout() async {
    try {
      await _dio.post<void>('/api/v1/auth/logout');
    } finally {
      await _config.clearSessionToken();
    }
  }

  Future<SessionResponse> _authenticate(
    String path,
    String username,
    String password,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(
      path,
      data: {'username': username, 'password': password},
    );
    final result = SessionResponse.fromJson(response.data ?? const {});
    await _config.setSessionToken(result.accessToken);
    return result;
  }

  Future<Map<String, dynamic>> health() async {
    final response = await _dio.get<Map<String, dynamic>>('/api/v1/health');
    return response.data ?? <String, dynamic>{};
  }

  Future<List<Map<String, dynamic>>> listConversations() async {
    final response = await _dio.get<List<dynamic>>('/api/v1/conversations');
    return (response.data ?? const [])
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();
  }

  Future<Map<String, dynamic>> createConversation({
    required String title,
    String? id,
    String? mutationId,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/v1/conversations',
      data: {
        'title': title,
        ...?id == null ? null : {'id': id},
      },
      options: mutationId == null
          ? null
          : Options(headers: {'Idempotency-Key': mutationId}),
    );
    return response.data ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>> renameConversation(
    String id,
    String title,
    String mutationId,
  ) async {
    final response = await _dio.patch<Map<String, dynamic>>(
      '/api/v1/conversations/${Uri.encodeComponent(id)}',
      data: {'title': title},
      options: Options(headers: {'Idempotency-Key': mutationId}),
    );
    return response.data ?? <String, dynamic>{};
  }

  Future<void> deleteConversation(String id, String mutationId) async {
    await _dio.delete<void>(
      '/api/v1/conversations/${Uri.encodeComponent(id)}',
      options: Options(headers: {'Idempotency-Key': mutationId}),
    );
  }

  /// Canonical Schedule naming. The legacy methods below remain for old
  /// callers and currently use the backwards-compatible server route.
  Future<Map<String, dynamic>> createSchedule(
    Map<String, dynamic> payload,
    String mutationId,
  ) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/v1/schedules',
        data: payload,
        options: Options(headers: {'Idempotency-Key': mutationId}),
      );
      return response.data ?? <String, dynamic>{};
    } on DioException catch (error) {
      if (error.response?.statusCode != 404) rethrow;
      return createCalendarEvent(payload, mutationId);
    }
  }

  Future<List<Map<String, dynamic>>> listSchedules() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/v1/schedules',
      );
      return _items(response.data);
    } on DioException catch (error) {
      if (error.response?.statusCode != 404) rethrow;
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/v1/calendar-events',
      );
      return _items(response.data);
    }
  }

  List<Map<String, dynamic>> _items(Map<String, dynamic>? data) {
    return (data?['items'] as List<dynamic>? ?? const [])
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();
  }

  Future<Map<String, dynamic>> updateSchedule(
    String id,
    Map<String, dynamic> payload,
    String mutationId,
  ) async {
    try {
      final response = await _dio.patch<Map<String, dynamic>>(
        '/api/v1/schedules/${Uri.encodeComponent(id)}',
        data: payload,
        options: Options(headers: {'Idempotency-Key': mutationId}),
      );
      return response.data ?? <String, dynamic>{};
    } on DioException catch (error) {
      if (error.response?.statusCode != 404) rethrow;
      return updateCalendarEvent(id, payload, mutationId);
    }
  }

  Future<void> deleteSchedule(String id, String mutationId) async {
    try {
      await _dio.delete<void>(
        '/api/v1/schedules/${Uri.encodeComponent(id)}',
        options: Options(headers: {'Idempotency-Key': mutationId}),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode != 404) rethrow;
      await deleteCalendarEvent(id, mutationId);
    }
  }

  Future<Map<String, dynamic>> createTask(
    Map<String, dynamic> payload,
    String mutationId,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/v1/tasks',
      data: payload,
      options: Options(headers: {'Idempotency-Key': mutationId}),
    );
    return response.data ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>> updateTask(
    String id,
    Map<String, dynamic> payload,
    String mutationId,
  ) async {
    final response = await _dio.patch<Map<String, dynamic>>(
      '/api/v1/tasks/$id',
      data: payload,
      options: Options(headers: {'Idempotency-Key': mutationId}),
    );
    return response.data ?? <String, dynamic>{};
  }

  Future<void> deleteTask(String id, String mutationId) async {
    await _dio.delete<void>(
      '/api/v1/tasks/$id',
      options: Options(headers: {'Idempotency-Key': mutationId}),
    );
  }

  Future<Map<String, dynamic>> createCalendarEvent(
    Map<String, dynamic> payload,
    String mutationId,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/v1/calendar-events',
      data: payload,
      options: Options(headers: {'Idempotency-Key': mutationId}),
    );
    return response.data ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>> updateCalendarEvent(
    String id,
    Map<String, dynamic> payload,
    String mutationId,
  ) async {
    final response = await _dio.patch<Map<String, dynamic>>(
      '/api/v1/calendar-events/$id',
      data: payload,
      options: Options(headers: {'Idempotency-Key': mutationId}),
    );
    return response.data ?? <String, dynamic>{};
  }

  Future<void> deleteCalendarEvent(String id, String mutationId) async {
    await _dio.delete<void>(
      '/api/v1/calendar-events/$id',
      options: Options(headers: {'Idempotency-Key': mutationId}),
    );
  }

  Future<Map<String, dynamic>> syncEvents({required int after}) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/v1/sync/events',
      queryParameters: {'after': after},
    );
    return response.data ?? <String, dynamic>{};
  }

  Future<List<Map<String, dynamic>>> listMessages(String conversationId) async {
    final response = await _dio.get<List<dynamic>>(
      '/api/v1/conversations/${Uri.encodeComponent(conversationId)}/messages',
    );
    return (response.data ?? const [])
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();
  }

  Future<List<Map<String, dynamic>>> uploadAttachments({
    required String conversationId,
    required List<AttachmentUpload> files,
    String? idempotencyKey,
  }) async {
    final form = FormData();
    for (final file in files) {
      form.files.add(
        MapEntry(
          'files',
          await MultipartFile.fromFile(
            file.path,
            filename: file.name,
            contentType: DioMediaType.parse(file.mimeType),
          ),
        ),
      );
    }
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/v1/conversations/${Uri.encodeComponent(conversationId)}/attachments',
      data: form,
      options: idempotencyKey == null
          ? null
          : Options(headers: {'Idempotency-Key': idempotencyKey}),
    );
    return (response.data?['items'] as List<dynamic>? ?? const [])
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();
  }

  Future<Map<String, dynamic>> createMessage({
    required String conversationId,
    required String id,
    required String content,
    List<Map<String, dynamic>> attachments = const [],
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/v1/conversations/${Uri.encodeComponent(conversationId)}/messages',
      data: {'id': id, 'content': content, 'attachments': attachments},
      options: Options(headers: {'Idempotency-Key': id}),
    );
    return response.data ?? <String, dynamic>{};
  }
}
