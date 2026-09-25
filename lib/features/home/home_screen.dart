import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/j3_spacing.dart';
import 'home_favorites.dart';
import 'home_hero.dart';
import 'home_panels.dart';
import 'home_status.dart';

/// The dashboard: hero, live system status with real counts, quick
/// actions, favourites, recents, sections and platform capabilities.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final pad = c.maxWidth >= J3Breakpoints.medium ? J3Space.pagePaddingWide : J3Space.pagePadding;
        final content = math.min(c.maxWidth - pad.horizontal, J3Size.maxContentWidth);
        const gap = SizedBox(height: J3Space.lg);

        final statusRow = content >= 920
            ? const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: SystemStatusPanel()),
                  SizedBox(width: J3Space.lg),
                  Expanded(flex: 2, child: QuickActionsPanel()),
                ],
              )
            : const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [SystemStatusPanel(), gap, QuickActionsPanel()],
              );

        final recentCols = content >= 1080 ? 3 : (content >= 680 ? 2 : 1);

        return Scrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            controller: _scroll,
            padding: pad,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: J3Size.maxContentWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const HomeHero(),
                    gap,
                    statusRow,
                    gap,
                    const FavoritesPanel(),
                    gap,
                    ColumnsLayout(
                      cols: recentCols,
                      children: const [RecentToolsPanel(), RecentWorkspacesPanel(), RecentActivityPanel()],
                    ),
                    gap,
                    const SectionsPanel(),
                    gap,
                    const PlatformPanel(),
                    const SizedBox(height: J3Space.xxl),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
