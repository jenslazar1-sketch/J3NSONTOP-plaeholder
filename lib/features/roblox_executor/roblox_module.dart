import 'package:flutter/material.dart';

import '../../core/platform/capabilities.dart';
import '../../core/tools/tool_definition.dart';
import 'presentation/executor_page.dart';

final FeatureModule robloxModule = FeatureModule(
  id: 'roblox_executor',
  tools: [
    ToolDefinition(
      id: ExecutorPage.id,
      name: 'Roblox Executor',
      section: ToolSection.devTools,
      description: 'Free Roblox script executor — attach, execute Lua scripts, built-in script hub. No key system.',
      icon: Icons.sports_esports,
      keywords: const [
        'roblox',
        'executor',
        'exploit',
        'lua',
        'script',
        'inject',
        'attach',
        'hack',
        'cheat',
        'speed',
        'fly',
        'noclip',
        'esp',
      ],
      platforms: const {AppPlatform.windows},
      builder: (context) => const ExecutorPage(),
    ),
  ],
);
