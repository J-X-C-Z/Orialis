import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/config/app_config.dart';
import '../../chat/data/agent_chat_service.dart';
import '../data/memory_repository.dart';
import 'memory_analyzer.dart';
import 'memory_coordinator.dart';

/// Uses the same secure session and stable analysis IDs as the visible app.
Future<void> runMemoryBackground({
  AppConfig? config,
  MemoryRepository? repository,
  AgentChatService? agents,
  MethodChannel lifecycle = const MethodChannel(
    'top.jxcz.orialis/memoryBackground',
  ),
  Duration budget = const Duration(seconds: 330),
}) async {
  MemoryRepository? inbox;
  AgentChatService? service;
  MemoryCoordinator? coordinator;
  var completed = false;
  var retry = false;
  try {
    final preferences = await SharedPreferences.getInstance();
    await preferences.reload();
    final appConfig = config ?? AppConfig();
    inbox = repository ?? MemoryRepository();
    service = agents ?? _BackgroundAgents(appConfig, lifecycle);
    final worker = coordinator = MemoryCoordinator(
      config: appConfig,
      repository: inbox,
      analyzer: MemoryAnalyzer(repository: inbox, agents: service),
    );
    await (() async {
      await worker.start();
      await worker.scan();
    })().timeout(budget);
    completed = true;
  } on PlatformException {
    // The native inbox rejects account changes; a background engine never rebinds it.
  } catch (_) {
    retry = true;
  } finally {
    coordinator?.dispose();
    service?.dispose();
    inbox?.dispose();
    await lifecycle.invokeMethod<void>('complete', {
      'completed': completed,
      'retry': retry,
    });
  }
}

class _BackgroundAgents extends AgentChatService {
  _BackgroundAgents(super.config, this.lifecycle);
  final MethodChannel lifecycle;

  @override
  Future<(String, String)> identity() async {
    if (await lifecycle.invokeMethod<bool>('isCurrent') != true) {
      throw PlatformException(code: 'memory_scope_changed');
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.reload();
    return super.identity();
  }
}
