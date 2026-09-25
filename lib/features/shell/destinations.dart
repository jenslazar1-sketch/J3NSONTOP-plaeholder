import 'package:flutter/material.dart';

import '../../core/tools/tool_definition.dart';

/// A top-level navigation destination.
class NavDestination {
  const NavDestination({
    required this.label,
    required this.route,
    required this.icon,
    required this.selectedIcon,
    this.section,
    this.shortcutDigit,
  });

  final String label;
  final String route;
  final IconData icon;
  final IconData selectedIcon;
  final ToolSection? section;

  /// `Ctrl+<digit>` shortcut on desktop.
  final int? shortcutDigit;
}

const List<NavDestination> kDestinations = [
  NavDestination(
    label: 'Home',
    route: '/',
    icon: Icons.dashboard_outlined,
    selectedIcon: Icons.dashboard,
    shortcutDigit: 1,
  ),
  NavDestination(
    label: 'Workspaces',
    route: '/workspaces',
    icon: Icons.folder_open_outlined,
    selectedIcon: Icons.folder_open,
    section: ToolSection.workspaces,
    shortcutDigit: 2,
  ),
  NavDestination(
    label: 'Mods',
    route: '/mods',
    icon: Icons.extension_outlined,
    selectedIcon: Icons.extension,
    section: ToolSection.mods,
    shortcutDigit: 3,
  ),
  NavDestination(
    label: 'Config Lab',
    route: '/config',
    icon: Icons.tune_outlined,
    selectedIcon: Icons.tune,
    section: ToolSection.configLab,
    shortcutDigit: 4,
  ),
  NavDestination(
    label: 'Asset Lab',
    route: '/assets',
    icon: Icons.palette_outlined,
    selectedIcon: Icons.palette,
    section: ToolSection.assetLab,
    shortcutDigit: 5,
  ),
  NavDestination(
    label: 'File Tools',
    route: '/files',
    icon: Icons.construction_outlined,
    selectedIcon: Icons.construction,
    section: ToolSection.fileTools,
    shortcutDigit: 6,
  ),
  NavDestination(
    label: 'Developer Tools',
    route: '/dev',
    icon: Icons.code_outlined,
    selectedIcon: Icons.code,
    section: ToolSection.devTools,
    shortcutDigit: 7,
  ),
  NavDestination(
    label: 'Activity',
    route: '/activity',
    icon: Icons.monitor_heart_outlined,
    selectedIcon: Icons.monitor_heart,
    shortcutDigit: 8,
  ),
  NavDestination(
    label: 'Settings',
    route: '/settings',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
    shortcutDigit: 9,
  ),
];

/// Route of the terminal tool.
const String kTerminalRoute = '/tool/system.terminal';

/// Finds the destination that owns [location] (tools map to their section).
NavDestination? destinationFor(String location, ToolSection? toolSection) {
  if (toolSection != null) {
    for (final d in kDestinations) {
      if (d.section == toolSection) return d;
    }
    return null;
  }
  NavDestination? best;
  for (final d in kDestinations) {
    if (d.route == '/') {
      if (location == '/') best = d;
    } else if (location == d.route || location.startsWith('${d.route}/')) {
      best = d;
    }
  }
  return best;
}
