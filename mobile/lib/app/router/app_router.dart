import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show OrialisPageScaffold;
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../../pages/calendar/calendar_page.dart';
import '../../pages/chat/chat_page.dart';
import '../../pages/events/events_page.dart';
import '../../pages/profile/profile_page.dart';
import '../../pages/shell/orialis_shell.dart';
import '../../pages/shell/desktop_shell.dart';
import '../../pages/today/today_page.dart';
import '../../pages/shared/page_parts.dart';
import '../../pages/projects/projects_page.dart';
import '../../features/devices/presentation/device_center_page.dart';
import '../../features/wear/wear_connection_page.dart';
import '../../features/memory/presentation/memory_page.dart';
import '../../pages/profile/system_settings_page.dart';
import '../../news/news_app.dart';
import '../../features/web_services/web_services_page.dart';

StatefulShellBranch _chatBranch() => StatefulShellBranch(
  routes: [
    _animatedRoute(
      path: '/chat',
      builder: (context, state) => Consumer(
        builder: (context, ref, _) {
          final conversationId =
              state.uri.queryParameters['conversationId'] ?? 'default';
          return ChatPage(
            key: ValueKey((
              ref.watch(desktopDatabaseNameProvider),
              conversationId,
            )),
            repository: ref.watch(chatRepositoryProvider),
            conversationId: conversationId,
            messageId: state.uri.queryParameters['messageId'],
            shareId: state.uri.queryParameters['shareId'],
          );
        },
      ),
    ),
  ],
);

GoRouter buildRouter({bool desktop = false}) {
  return GoRouter(
    initialLocation: '/today',
    routes: [
      _animatedRoute(path: '/auth', builder: (_, _) => const AuthPage()),
      if (!desktop)
        _animatedRoute(
          path: '/memory',
          builder: (_, _) => Consumer(
            builder: (context, ref, _) => MemoryPage(
              key: ValueKey(ref.watch(desktopDatabaseNameProvider)),
              repository: ref.watch(memoryRepositoryProvider),
              onAnalyze: (record) async {
                await ref.read(memoryCoordinatorProvider)?.retry(record);
              },
            ),
          ),
        ),
      if (!desktop)
        _animatedRoute(
          path: '/system',
          builder: (_, _) => const SystemSettingsPage(),
        ),
      if (!desktop)
        _animatedRoute(
          path: '/wear',
          builder: (_, _) => const WearConnectionPage(),
        ),
      _animatedRoute(
        path: '/devices',
        builder: (_, _) => const DeviceCenterPage(),
      ),
      if (!desktop)
        _animatedRoute(
          path: '/projects',
          builder: (_, _) => const ProjectsPage(),
        ),
      StatefulShellRoute(
        navigatorContainerBuilder: (context, shell, children) =>
            LuminaBranchTransition(
              index: shell.currentIndex,
              children: children,
            ),
        builder: (context, state, navigationShell) => desktop
            ? DesktopShell(navigationShell: navigationShell)
            : OrialisShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              _animatedRoute(
                path: '/today',
                builder: (_, _) => desktop
                    ? const TodayPage()
                    : const OrialisCompactTypography(child: TodayPage()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              _animatedRoute(
                path: '/events',
                builder: (_, _) => desktop
                    ? const EventsPage()
                    : const OrialisCompactTypography(child: EventsPage()),
              ),
            ],
          ),
          if (desktop)
            StatefulShellBranch(
              routes: [
                _animatedRoute(
                  path: '/projects',
                  builder: (_, _) => const ProjectsPage(),
                ),
              ],
            ),
          if (!desktop) _chatBranch(),
          StatefulShellBranch(
            routes: [
              _animatedRoute(
                path: '/calendar',
                builder: (_, _) => const CalendarPage(),
                routes: [
                  _animatedRoute(
                    path: 'schedule/:id',
                    builder: (_, state) => CalendarPage(
                      initialScheduleId: state.pathParameters['id'],
                      initialDate: DateTime.tryParse(
                        state.uri.queryParameters['date'] ?? '',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              _animatedRoute(
                path: '/profile',
                builder: (_, _) => const ProfilePage(),
              ),
            ],
          ),
          if (desktop) ...[
            StatefulShellBranch(
              routes: [
                _animatedRoute(
                  path: '/news/aihot',
                  builder: (_, _) =>
                      const DesktopNewsPage(section: DesktopNewsSection.aiHot),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                _animatedRoute(
                  path: '/news/github',
                  builder: (_, _) =>
                      const DesktopNewsPage(section: DesktopNewsSection.github),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                _animatedRoute(
                  path: '/news/project',
                  builder: (_, _) => const DesktopNewsPage(
                    section: DesktopNewsSection.project,
                  ),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                _animatedRoute(
                  path: '/services',
                  builder: (_, _) => const WebServicesPage(),
                ),
              ],
            ),
            _chatBranch(),
            StatefulShellBranch(
              routes: [
                _animatedRoute(
                  path: '/memory',
                  builder: (_, _) => Consumer(
                    builder: (context, ref, _) => MemoryPage(
                      key: ValueKey(ref.watch(desktopDatabaseNameProvider)),
                      desktop: true,
                      repository: ref.watch(memoryRepositoryProvider),
                      onAnalyze: (record) async {
                        await ref
                            .read(memoryCoordinatorProvider)
                            ?.retry(record);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    ],
  );
}

class PlaceholderPage extends StatelessWidget {
  const PlaceholderPage({required this.title, super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return OrialisPageScaffold(
      title: title,
      body: const Center(child: Text('聊天将在下一阶段接入。')),
    );
  }
}

GoRoute _animatedRoute({
  required String path,
  required Widget Function(BuildContext, GoRouterState) builder,
  List<RouteBase> routes = const [],
}) => GoRoute(
  path: path,
  routes: routes,
  pageBuilder: (context, state) => CustomTransitionPage<void>(
    key: state.pageKey,
    transitionDuration: LuminaMotion.page,
    reverseTransitionDuration: LuminaMotion.fast,
    child: builder(context, state),
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        luminaPageTransition(context, animation, child),
  ),
);
