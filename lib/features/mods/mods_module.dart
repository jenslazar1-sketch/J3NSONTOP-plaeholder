import 'package:flutter/material.dart';

import '../../core/platform/capabilities.dart';
import '../../core/tools/tool_definition.dart';
import 'presentation/builder_page.dart';
import 'presentation/inspector_page.dart';
import 'presentation/manager_page.dart';
import 'presentation/mods_controller.dart';
import 'profiles_command.dart';

/// Mods: package library, profiles, dependency resolution, journaled apply
/// with backups and rollback, package inspector and builder.
final FeatureModule modsModule = FeatureModule(
  id: 'mods',
  tools: [
    ToolDefinition(
      id: kModsManagerId,
      name: 'Mod Manager',
      section: ToolSection.mods,
      description: 'Library, load-order profiles, dependency checks, apply plans with backups, rollback and journals.',
      icon: Icons.extension,
      keywords: const [
        'mods',
        'mod manager',
        'profile',
        'profiles',
        'load order',
        'library',
        'j3mod',
        'apply',
        'rollback',
        'restore',
        'backup',
        'journal',
        'dependencies',
        'conflicts',
        'overlap',
      ],
      requiredCapabilities: const {Capability.importFiles},
      builder: (_) => const ModsManagerPage(),
    ),
    ToolDefinition(
      id: kModsInspectorId,
      name: 'Mod Package Inspector',
      section: ToolSection.mods,
      description: 'Check any .j3mod without importing it: archive safety, manifest rules, file mapping and issues.',
      icon: Icons.manage_search,
      keywords: const ['inspect', 'validate', 'j3mod', 'package', 'manifest', 'mod', 'zip', 'check'],
      builder: (_) => const ModInspectorPage(),
    ),
    ToolDefinition(
      id: kModsBuilderId,
      name: 'Mod Package Builder',
      section: ToolSection.mods,
      description: 'Create a .j3mod from workspace or device files with live manifest validation.',
      icon: Icons.construction,
      keywords: const ['build', 'create', 'pack', 'package', 'j3mod', 'manifest', 'mod', 'author'],
      builder: (_) => const ModBuilderPage(),
    ),
  ],
  landings: [SectionLanding(ToolSection.mods, (_) => const ModsManagerPage())],
  commands: const [ProfilesCommand()],
);
