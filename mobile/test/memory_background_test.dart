import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/network/orialis_api_client.dart';
import 'package:orialis_mobile/features/chat/data/agent_chat_service.dart';
import 'package:orialis_mobile/features/memory/application/memory_background.dart';
import 'package:orialis_mobile/features/memory/data/memory_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Config extends AppConfig {
  @override
  Future<String?> sessionToken() async => 'private-test-session';
  @override
  Future<String?> sessionUsername() async => 'one';
  @override
  Future<String> serverUrl() async => 'https://unused.invalid';
  @override
  Future<String> desktopDatabaseName() async => 'account-one';
}

class _Api extends OrialisApiClient {
  _Api() : super(baseUrl: 'https://unused.invalid', deviceId: 'test');
  int submissions = 0;
  Completer<void>? gate;
  void Function()? onSubmit;
  Map<String, dynamic>? result;
  @override
  Future<Map<String, dynamic>?> memoryAnalysis(String id) async => result;
  @override
  Future<Map<String, dynamic>> createMemoryAnalysis({
    required String id,
    required String content,
    String? imageBase64,
    List<String> sourceUrls = const [],
  }) async {
    submissions++;
    onSubmit?.call();
    await gate?.future;
    return result = {
      'id': id,
      'status': 'completed',
      'content': '# 后台记忆\n\n已在不显示界面的情况下完成。',
      'category': 'ai',
      'videoStatus': 'none',
    };
  }
}

class _Agents extends AgentChatService {
  _Agents(super.config, this.api);
  final _Api api;
  @override
  Future<OrialisApiClient> client() async => api;
  @override
  Future<List<ChatAgentDevice>> devices() async => [
    ChatAgentDevice(id: azureDeviceId, platform: 'linux', online: true),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const inboxChannel = MethodChannel('test/backgroundInbox');
  const lifecycle = MethodChannel('test/backgroundLifecycle');
  final binding = TestDefaultBinaryMessengerBinding.instance;
  late String nativeScope;
  late Map<String, Object?> record;
  late List<String> inboxCalls;
  late List<Map<Object?, Object?>> finishes;
  late _Api api;
  late bool networkScopeCurrent;
  late int networkScopeChecks;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    nativeScope = sha256.convert(utf8.encode('account-one')).toString();
    record = {
      'id': 'captured-one',
      'createdAt': '2026-10-25T00:00:00Z',
      'title': '截图',
      'visibleText': '一个AI视频',
      'urls': <String>[],
      'analysisStatus': 'pending',
    };
    inboxCalls = [];
    finishes = [];
    api = _Api();
    networkScopeCurrent = true;
    networkScopeChecks = 0;
    final pinnedScope = nativeScope;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(inboxChannel, (
      call,
    ) async {
      inboxCalls.add(call.method);
      if (call.method == 'takePendingRoute') return null;
      if (nativeScope != pinnedScope ||
          call.method == 'setScope' &&
              (call.arguments as Map)['scope'] != pinnedScope) {
        throw PlatformException(code: 'memory_scope_changed');
      }
      switch (call.method) {
        case 'status':
          return {'supported': true};
        case 'setScope':
          return null;
        case 'list':
          return [record];
        case 'read':
          return record;
        case 'update':
          final expected = (call.arguments as Map)['expectedAnalysisRequestId'];
          if (expected != null &&
              (record['analysisRequestId'] ?? '') != expected) {
            throw PlatformException(code: 'memory_analysis_changed');
          }
          record.addAll(
            Map<String, Object?>.from((call.arguments as Map)['fields'] as Map),
          );
          return record;
        default:
          throw StateError('Unexpected UI/native call: ${call.method}');
      }
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(lifecycle, (
      call,
    ) async {
      if (call.method == 'isCurrent') {
        networkScopeChecks++;
        return networkScopeCurrent;
      }
      expect(call.method, 'complete');
      finishes.add(Map<Object?, Object?>.from(call.arguments as Map));
      return null;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(inboxChannel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(lifecycle, null);
  });

  Future<void> run({Duration budget = const Duration(seconds: 1)}) {
    final config = _Config();
    return runMemoryBackground(
      config: config,
      repository: MemoryRepository(channel: inboxChannel),
      agents: _Agents(config, api),
      lifecycle: lifecycle,
      budget: budget,
    );
  }

  test('headless entry drains the same inbox without asking for a capture or route', () async {
    final scope = nativeScope;
    await run();
    expect(api.submissions, 1);
    expect(record['analysisStatus'], 'completed');
    expect(record['category'], 'ai');
    expect(nativeScope, scope);
    expect(inboxCalls, isNot(contains('capture')));
    expect(finishes.single, {'completed': true, 'retry': false});
  });

  for (final unclaimed in [null, '']) {
    test(
      'headless analysis claims a null or empty native ID: $unclaimed',
      () async {
        record['analysisRequestId'] = unclaimed;
        await run();
        expect(api.submissions, 1);
        expect(record['analysisRequestId'], 'memory-v2-captured-one');
        expect(record['analysisStatus'], 'completed');
        expect(finishes.single, {'completed': true, 'retry': false});
      },
    );
  }

  test(
    'a changed account aborts before reading or uploading its inbox',
    () async {
      nativeScope = 'other-account';
      await run();
      expect(api.submissions, 0);
      expect(inboxCalls, isNot(contains('read')));
      expect(record['analysisStatus'], 'pending');
      expect(nativeScope, 'other-account');
      expect(finishes.single, {'completed': false, 'retry': false});
    },
  );

  test('native account revocation is checked before the background HTTP client is used', () async {
    networkScopeCurrent = false;
    await runMemoryBackground(
      config: _Config(),
      repository: MemoryRepository(channel: inboxChannel),
      lifecycle: lifecycle,
      budget: const Duration(seconds: 1),
    );
    expect(networkScopeChecks, greaterThan(0));
    expect(record['analysisStatus'], 'pending');
    expect(record['summary'], isNull);
  });

  test('a stopped account cannot receive a late completed result', () async {
    api.onSubmit = () => nativeScope = 'new-account';
    await run();
    expect(api.submissions, 1);
    expect(record['analysisStatus'], 'analyzing');
    expect(record['summary'], isNull);
    expect(nativeScope, 'new-account');
  });

  test(
    'the execution budget releases the engine and keeps the stable pending job',
    () async {
      final gate = api.gate = Completer<void>();
      await run(budget: const Duration(milliseconds: 40));
      expect(finishes.single, {'completed': false, 'retry': true});
      expect(record['analysisStatus'], 'analyzing');
      expect(record['analysisRequestId'], 'memory-v2-captured-one');
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(record['summary'], isNull);
    },
  );
}
