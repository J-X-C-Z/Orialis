import '../design/design_components.dart';
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
import '../../pages/projects/projects_page.dart';
import '../../features/devices/presentation/device_center_page.dart';
import '../../features/wear/wear_connection_page.dart';
import '../../pages/profile/system_settings_page.dart';
import '../../news/news_app.dart';
import '../../features/web_services/web_services_page.dart';

GoRouter buildRouter({bool desktop = false}) {
  return GoRouter(
    initialLocation: '/today',
    routes: [
      GoRoute(path: '/auth', builder: (_, _) => const AuthPage()),
      if (!desktop)
        GoRoute(path: '/system', builder: (_, _) => const SystemSettingsPage()),
      if (!desktop)
        GoRoute(path: '/wear', builder: (_, _) => const WearConnectionPage()),
      GoRoute(path: '/devices', builder: (_, _) => const DeviceCenterPage()),
      if (!desktop)
        GoRoute(path: '/projects', builder: (_, _) => const ProjectsPage()),
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
              GoRoute(path: '/today', builder: (_, _) => const TodayPage()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/events', builder: (_, _) => const EventsPage()),
            ],
          ),
          if (desktop)
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/projects',
                  builder: (_, _) => const ProjectsPage(),
                ),
              ],
            ),
          if (!desktop)
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/chat',
                  builder: (context, state) => Consumer(
                    builder: (context, ref, _) {
                      final conversationId =
                          state.uri.queryParameters['conversationId'] ??
                          'default';
                      return ChatPage(
                        key: ValueKey(conversationId),
                        repository: ref.watch(chatRepositoryProvider),
                        conversationId: conversationId,
                        messageId: state.uri.queryParameters['messageId'],
                      );
                    },
                  ),
                ),
              ],
            ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/calendar',
                builder: (_, _) => const CalendarPage(),
                routes: [
                  GoRoute(
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
              GoRoute(path: '/profile', builder: (_, _) => const ProfilePage()),
            ],
          ),
          if (desktop) ...[
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/news/aihot',
                  builder: (_, _) =>
                      const DesktopNewsPage(section: DesktopNewsSection.aiHot),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/news/github',
                  builder: (_, _) =>
                      const DesktopNewsPage(section: DesktopNewsSection.github),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/news/project',
                  builder: (_, _) => const DesktopNewsPage(
                    section: DesktopNewsSection.project,
                  ),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/services',
                  builder: (_, _) => const WebServicesPage(),
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
