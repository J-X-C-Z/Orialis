import 'dart:async';

import 'package:flutter/services.dart';
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
import 'design/lumina_blur.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase();
  ref.onDispose(database.close);
  return database;
});

final appConfigProvider = Provider<AppConfig>((ref) => AppConfig());

class HighPerformanceModeController extends StateNotifier<bool> {
  HighPerformanceModeController(this._config) : super(true) {
    unawaited(_load());
  }

  final AppConfig _config;
  int _revision = 0;

  Future<void> _load() async {
    final saved = await _config.highPerformanceMode();
    if (mounted && _revision == 0) state = saved;
  }

  Future<void> setEnabled(bool value) async {
    final previous = state;
    final revision = ++_revision;
    state = value;
    try {
      await _config.setHighPerformanceMode(value);
    } catch (_) {
      if (mounted && revision == _revision) state = previous;
      rethrow;
    }
  }
}

final highPerformanceModeProvider =
    StateNotifierProvider<HighPerformanceModeController, bool>(
      (ref) => HighPerformanceModeController(ref.watch(appConfigProvider)),
    );

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
  late final _router = buildRouter();
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
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final highPerformanceMode = ref.watch(highPerformanceModeProvider);
    // Frame-time watcher may auto-downgrade BlurL → BlurM → BlurS on weak devices.
    LuminaBlurPolicy.instance.ensureFrameWatcher();
    // High-performance chrome keeps a live frost (BlurL). Never leave it on
    // legacy σ=18 or fully disabled after a stale policy.
    if (LuminaBlurPolicy.instance.chrome.level == LuminaBlurLevel.blurXS &&
        highPerformanceMode) {
      LuminaBlurPolicy.instance.useHighPerformanceChrome();
    }
    return WidgetsApp.router(
      title: 'Orialis',
      debugShowCheckedModeBanner: false,
      color: const Color(0xFF476F82),
      builder: (context, child) => LuminaTheme(
        brightness: MediaQuery.platformBrightnessOf(context),
        highPerformanceMode: highPerformanceMode,
        child: Builder(
          builder: (context) => DefaultTextStyle(
            style: LuminaTheme.of(context).textTheme.bodyMedium,
            child: AnnotatedRegion<SystemUiOverlayStyle>(
              value: MediaQuery.platformBrightnessOf(context) == Brightness.dark
                  ? SystemUiOverlayStyle.light
                  : SystemUiOverlayStyle.dark,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
      routerConfig: _router,
    );
  }
}
