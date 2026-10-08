import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Locale, Material, ThemeMode;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../features/devices/application/device_center_controller.dart';
import '../features/devices/data/device_data_source.dart';
import '../core/database/app_database.dart';
import '../features/events/data/event_repository.dart';
import '../features/events/data/task_repository.dart';
import '../features/events/data/schedule_repository.dart';
import '../features/projects/data/project_repository.dart';
import '../features/chat/data/chat_repository.dart';
import '../core/realtime/mobile_realtime_client.dart';
import '../core/sync/sync_engine.dart';
import '../core/sync/sync_coordinator.dart';
import '../core/sync/desktop_local_changes.dart';
import '../features/system_integration/system_integration_controller.dart';
import 'router/app_router.dart';

import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

// Keep the installed app's Node lease independent of Device Center routes.
final nodeHeartbeatLifecycleProvider = Provider<NodeHeartbeatLifecycle?>((ref) {
  final source = ref.watch(deviceDataSourceProvider);
  if (source is! NodeApiDeviceDataSource) return null;
  final lifecycle = NodeHeartbeatLifecycle(
    source,
    config: ref.watch(appConfigProvider),
  );
  unawaited(lifecycle.resumeLocalNode());
  ref.onDispose(lifecycle.dispose);
  return lifecycle;
});

final desktopModeProvider = Provider<bool>((ref) => false);
final desktopDatabaseNameProvider = StateProvider<String>((ref) => 'orialis');

Future<void> suspendDesktopSync(WidgetRef ref) async {
  if (!ref.read(desktopModeProvider)) return;
  await ref.read(syncCoordinatorProvider).dispose();
  await ref.read(realtimeClientProvider).dispose();
}

Future<void> reloadDesktopAccount(WidgetRef ref) async {
  if (!ref.read(desktopModeProvider)) return;
  final name = await ref.read(appConfigProvider).desktopDatabaseName();
  ref.read(desktopDatabaseNameProvider.notifier).state = name;
  // Recreate connection credentials even when logging back into the same scope.
  ref.invalidate(realtimeClientProvider);
  ref.invalidate(syncEngineProvider);
  ref.invalidate(syncCoordinatorProvider);
}

final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase(
    name: ref.watch(desktopModeProvider)
        ? ref.watch(desktopDatabaseNameProvider)
        : 'orialis',
  );
  ref.onDispose(database.close);
  return database;
});

final appConfigProvider = Provider<AppConfig>((ref) => AppConfig());

final systemIntegrationProvider = Provider<SystemIntegrationController?>((ref) {
  if (ref.watch(desktopModeProvider) ||
      kIsWeb ||
      defaultTargetPlatform != TargetPlatform.android) {
    return null;
  }
  final controller = SystemIntegrationController(
    database: ref.watch(databaseProvider),
    config: ref.watch(appConfigProvider),
  );
  ref.onDispose(() => unawaited(controller.dispose()));
  return controller;
});

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

class AppearanceModeController extends StateNotifier<ThemeMode> {
  AppearanceModeController(this._config) : super(ThemeMode.system) {
    unawaited(_load());
  }

  final AppConfig _config;
  int _revision = 0;

  Future<void> _load() async {
    final saved = await _config.appearanceMode();
    if (mounted && _revision == 0) {
      state = ThemeMode.values.firstWhere(
        (mode) => mode.name == saved,
        orElse: () => ThemeMode.system,
      );
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    final previous = state;
    final revision = ++_revision;
    state = mode;
    try {
      await _config.setAppearanceMode(mode.name);
    } catch (_) {
      if (mounted && revision == _revision) state = previous;
      rethrow;
    }
  }
}

final appearanceModeProvider =
    StateNotifierProvider<AppearanceModeController, ThemeMode>(
      (ref) => AppearanceModeController(ref.watch(appConfigProvider)),
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
    includeChat: !ref.watch(desktopModeProvider),
    requireSession: ref.watch(desktopModeProvider),
  );
});

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return ChatRepository(database: ref.watch(databaseProvider));
});

final realtimeClientProvider = Provider<MobileRealtimeClient>((ref) {
  final desktop = ref.watch(desktopModeProvider);
  final client = MobileRealtimeClient(
    config: ref.watch(appConfigProvider),
    platform: desktop ? 'macos' : 'android',
    clientName: desktop ? 'orialis_desktop' : 'orialis_mobile',
    advertisedCapabilities: desktop
        ? const {}
        : MobileRealtimeClient.clientCapabilities,
  );
  ref.onDispose(client.dispose);
  return client;
});

final syncCoordinatorProvider = Provider<SyncCoordinator>((ref) {
  final coordinator = SyncCoordinator(
    sync: ref.watch(syncEngineProvider).syncOnce,
    realtime: ref.watch(realtimeClientProvider),
    chatRepository: ref.watch(desktopModeProvider)
        ? null
        : ref.watch(chatRepositoryProvider),
    localChanges: ref.watch(desktopModeProvider)
        ? watchDesktopLocalChanges(ref.watch(databaseProvider))
        : null,
    onChatMessage: ref.watch(desktopModeProvider)
        ? null
        : (payload) async {
            await ref
                .read(systemIntegrationProvider)
                ?.notifyChatMessage(payload);
          },
    onScheduleUpdate: ref.watch(desktopModeProvider)
        ? null
        : (payload) async {
            await ref
                .read(systemIntegrationProvider)
                ?.notifyScheduleUpdate(payload);
          },
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
  late final _router = buildRouter(desktop: ref.read(desktopModeProvider));
  SystemIntegrationController? _systemIntegration;
  bool? _lastPerformanceMode;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(ref.read(syncCoordinatorProvider).start());
    final system = ref.read(systemIntegrationProvider);
    _systemIntegration = system;
    system?.onRoute = (route) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _router.go(route);
      });
      WidgetsBinding.instance.scheduleFrame();
    };
    if (system != null) unawaited(system.start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(syncCoordinatorProvider).requestSync());
      final system = ref.read(systemIntegrationProvider);
      if (system != null) unawaited(system.refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _systemIntegration?.onRoute = null;
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(nodeHeartbeatLifecycleProvider);
    ref.listen(syncCoordinatorProvider, (previous, next) {
      unawaited(next.start());
    });
    final highPerformanceMode = ref.watch(highPerformanceModeProvider);
    final appearanceMode = ref.watch(appearanceModeProvider);
    final brightness = switch (appearanceMode) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system => MediaQuery.platformBrightnessOf(context),
    };
    LuminaBlurPolicy.instance.ensureFrameWatcher();
    if (_lastPerformanceMode != highPerformanceMode) {
      _lastPerformanceMode = highPerformanceMode;
      LuminaBlurPolicy.instance.configure(
        highPerformanceMode
            ? LuminaBlurConfig.highPerformanceChrome
            : LuminaBlurConfig.flowingGlass,
      );
    }
    return WidgetsApp.router(
      title: 'Orialis',
      debugShowCheckedModeBanner: false,
      color: const Color(0xFF476F82),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      builder: (context, child) => LuminaTheme(
        brightness: brightness,
        highPerformanceMode: highPerformanceMode,
        data: LuminaThemeData(liquidGlass: ref.watch(desktopModeProvider)),
        child: Builder(
          builder: (context) => DefaultTextStyle(
            style: LuminaTheme.of(context).textTheme.bodyMedium,
            child: AnnotatedRegion<SystemUiOverlayStyle>(
              value: brightness == Brightness.dark
                  ? SystemUiOverlayStyle.light
                  : SystemUiOverlayStyle.dark,
              child: Material(
                color: LuminaTheme.of(context).colors.paper,
                textStyle: LuminaTheme.of(context).textTheme.bodyMedium,
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
      routerConfig: _router,
    );
  }
}
