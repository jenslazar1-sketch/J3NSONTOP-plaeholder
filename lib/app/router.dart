import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/tools/tool_definition.dart';
import '../features/activity/activity_screen.dart';
import '../features/home/home_screen.dart';
import '../features/intro/intro_screen.dart';
import '../features/settings/about_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/app_shell.dart';
import '../features/shell/destinations.dart';
import '../features/shell/section_hub.dart';

/// Builds the router. The intro is shown only when [showIntro] is true at
/// cold start (or explicitly replayed via `/intro?replay=1`); it never plays
/// again on ordinary navigation or app resume.
GoRouter buildRouter({required bool showIntro}) {
  NoTransitionPage<void> page(Widget child, GoRouterState state) =>
      NoTransitionPage<void>(key: state.pageKey, child: child);

  return GoRouter(
    initialLocation: showIntro ? '/intro' : '/',
    routes: [
      GoRoute(
        path: '/intro',
        pageBuilder: (context, state) => NoTransitionPage<void>(
          key: state.pageKey,
          child: IntroScreen(
            replay: state.uri.queryParameters['replay'] == '1',
            onFinished: () => context.go('/'),
          ),
        ),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(location: state.uri.toString(), child: child),
        routes: [
          GoRoute(path: '/', pageBuilder: (c, s) => page(const HomeScreen(), s)),
          for (final section in ToolSection.values)
            if (section != ToolSection.system)
              GoRoute(path: section.route, pageBuilder: (c, s) => page(SectionPage(section: section), s)),
          GoRoute(path: '/tools', pageBuilder: (c, s) => page(const AllToolsPage(), s)),
          GoRoute(path: '/activity', pageBuilder: (c, s) => page(const ActivityScreen(), s)),
          GoRoute(path: '/settings', pageBuilder: (c, s) => page(const SettingsScreen(), s)),
          GoRoute(path: '/about', pageBuilder: (c, s) => page(const AboutScreen(), s)),
          GoRoute(path: '/terminal', redirect: (c, s) => kTerminalRoute),
          // Tool pages are rendered by the shell's ToolHost (kept alive);
          // the route itself only carries the id.
          GoRoute(path: '/tool/:id', pageBuilder: (c, s) => page(const SizedBox.shrink(), s)),
        ],
      ),
    ],
  );
}
