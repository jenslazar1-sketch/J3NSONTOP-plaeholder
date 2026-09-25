import 'package:flutter/widgets.dart';

import '../commands/terminal_command.dart';
import '../platform/capabilities.dart';

/// Top-level navigation sections. Tools belong to exactly one section.
enum ToolSection {
  workspaces('Workspaces', 'Projects, files, search, rename and replace', '/workspaces'),
  mods('Mods', 'Mod packages, profiles, backups and rollback', '/mods'),
  configLab('Config Lab', 'JSON, YAML, TOML, INI, CSV and save data', '/config'),
  assetLab('Asset Lab', 'Images, sprites, atlases, colours and icons', '/assets'),
  fileTools('File Tools', 'Hashes, duplicates, ZIP, logs and text cleanup', '/files'),
  devTools('Developer Tools', 'Encoders, regex, diff, HTTP and more', '/dev'),
  system('System', 'Terminal, activity and settings', '/tools');

  const ToolSection(this.label, this.tagline, this.route);
  final String label;
  final String tagline;
  final String route;
}

/// A registered built-in tool. Adding a tool only requires adding a
/// definition to its feature module; navigation, search, the command
/// palette and the terminal `open` command pick it up automatically.
@immutable
class ToolDefinition {
  const ToolDefinition({
    required this.id,
    required this.name,
    required this.section,
    required this.description,
    required this.icon,
    required this.builder,
    this.keywords = const [],
    this.platforms = const {AppPlatform.android, AppPlatform.ios, AppPlatform.windows, AppPlatform.linux},
    this.requiredCapabilities = const {},
    this.worksOffline = true,
  });

  /// Stable id: `<section>.<tool>`, e.g. `dev.base64`. Used in routes,
  /// favourites, history and presets - never rename once released.
  final String id;
  final String name;
  final ToolSection section;
  final String description;
  final List<String> keywords;
  final IconData icon;
  final Set<AppPlatform> platforms;
  final Set<Capability> requiredCapabilities;
  final bool worksOffline;

  /// Entry point. Called inside the shell's tool host.
  final WidgetBuilder builder;

  String get route => '/tool/$id';

  bool availableOn(CapabilityMatrix caps) =>
      platforms.contains(caps.platform) && caps.supportsAll(requiredCapabilities);
}

/// Custom landing page for a section (otherwise a generic tool grid).
@immutable
class SectionLanding {
  const SectionLanding(this.section, this.builder);
  final ToolSection section;
  final WidgetBuilder builder;
}

/// Everything a feature contributes to the app.
@immutable
class FeatureModule {
  const FeatureModule({required this.id, this.tools = const [], this.landings = const [], this.commands = const []});

  final String id;
  final List<ToolDefinition> tools;
  final List<SectionLanding> landings;
  final List<TerminalCommand> commands;
}
