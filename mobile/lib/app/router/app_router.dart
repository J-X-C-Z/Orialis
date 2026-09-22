import '../design/design_components.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../../pages/calendar/calendar_page.dart';
import '../../pages/chat/chat_page.dart';
import '../../pages/events/events_page.dart';
import '../../pages/profile/profile_page.dart';
import '../../pages/shell/orialis_shell.dart';
import '../../pages/today/today_page.dart';
import '../../pages/projects/projects_page.dart';

GoRouter buildRouter() {
  return GoRouter(
    initialLocation: '/today',
    routes: [
      GoRoute(path: '/auth', builder: (_, _) => const AuthPage()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            OrialisShell(navigationShell: navigationShell),
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
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/chat',
                builder: (_, _) => Consumer(
                  builder: (context, ref, _) =>
                      ChatPage(repository: ref.watch(chatRepositoryProvider)),
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
              GoRoute(
                path: '/projects',
                builder: (_, _) => const ProjectsPage(),
              ),
            ],
          ),
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
