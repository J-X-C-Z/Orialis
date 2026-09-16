import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../core/database/app_database.dart';
import '../features/events/data/event_repository.dart';
import '../features/chat/data/chat_repository.dart';
import '../core/realtime/mobile_realtime_client.dart';
import '../core/sync/sync_engine.dart';
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
  final chatRepository = ref.watch(chatRepositoryProvider);
  final subscription = client.events.listen((event) {
    if (event.type == 'message') {
      unawaited(chatRepository.applyRemoteMessage(event.payload));
    }
  });
  ref.onDispose(subscription.cancel);
  ref.onDispose(client.dispose);
  return client;
});

class OrialisApp extends ConsumerWidget {
  const OrialisApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Orialis',
      debugShowCheckedModeBanner: false,
      theme: buildOrialisTheme(),
      routerConfig: buildRouter(),
    );
  }
}
