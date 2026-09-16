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

  Future<Map<String, dynamic>> createMessage({
    required String conversationId,
    required String id,
    required String content,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/v1/conversations/${Uri.encodeComponent(conversationId)}/messages',
      data: {'id': id, 'content': content},
      options: Options(headers: {'Idempotency-Key': id}),
    );
    return response.data ?? <String, dynamic>{};
  }
}
