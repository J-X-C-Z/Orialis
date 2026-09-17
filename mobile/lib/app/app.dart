import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../core/database/app_database.dart';
import '../features/events/data/event_repository.dart';
import '../features/events/data/task_repository.dart';
import '../features/events/data/schedule_repository.dart';
import '../features/projects/data/project_repository.dart';
import '../features/chat/data/chat_repository.dart';
import '../core/realtime/mobile_realtime_client.dart';
import '../core/sync/sync_engine.dart';
import '../core/sync/sync_coordinator.dart';
import 'router/app_router.dart';
import 'design/app_theme.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase();
  ref.onDispose(database.close);
  return database;
});

final appConfigProvider = Provider<AppConfig>((ref) => AppConfig());

final eventRepositoryProvider = Provider<EventRepository>((ref) {
  return EventRepository(
    database: ref.watch(databaseProvider),
    config: ref.watch(appConfigProvider),
  );
});

final taskRepositoryProvider = Provider<TaskRepository>(
  (ref) => TaskRepository(delegate: ref.watch(eventRepositoryProvider)),
);

final scheduleRepositoryProvider = Provider<ScheduleRepository>(
  (ref) => ScheduleRepository(delegate: ref.watch(eventRepositoryProvider)),
);

final projectRepositoryProvider = Provider<ProjectRepository>(
  (ref) => ProjectRepository(ref.watch(databaseProvider)),
);

final syncEngineProvider = Provider<SyncEngine>((ref) {
  return SyncEngine(
    database: ref.watch(databaseProvider),
    config: ref.watch(appConfigProvider),
  );
});

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return ChatRepository(database: ref.watch(databaseProvider));
});

final realtimeClientProvider = Provider<MobileRealtimeClient>((ref) {
  final client = MobileRealtimeClient(config: ref.watch(appConfigProvider));
  ref.onDispose(client.dispose);
  return client;
});

final syncCoordinatorProvider = Provider<SyncCoordinator>((ref) {
  final coordinator = SyncCoordinator(
    sync: ref.watch(syncEngineProvider).syncOnce,
    realtime: ref.watch(realtimeClientProvider),
    chatRepository: ref.watch(chatRepositoryProvider),
  );
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

class OrialisApp extends ConsumerStatefulWidget {
  const OrialisApp({super.key});

  @override
  ConsumerState<OrialisApp> createState() => _OrialisAppState();
}

class _OrialisAppState extends ConsumerState<OrialisApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(ref.read(syncCoordinatorProvider).start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(syncCoordinatorProvider).requestSync());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Orialis',
      debugShowCheckedModeBanner: false,
      theme: buildOrialisTheme(),
      routerConfig: buildRouter(),
    );
  }
}
