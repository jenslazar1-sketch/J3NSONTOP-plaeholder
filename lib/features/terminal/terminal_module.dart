import 'package:flutter/material.dart';

import '../../core/tools/tool_definition.dart';
import 'commands/builtin_commands.dart';
import 'presentation/terminal_screen.dart';
import 'presentation/terminal_session.dart';

/// The Terminal feature: an internal command interface that runs this app's
/// own registered commands. It is not a system shell and never starts OS
/// processes.
final FeatureModule terminalModule = FeatureModule(
  id: 'terminal',
  tools: [
    ToolDefinition(
      id: kTerminalToolId,
      name: 'Terminal',
      section: ToolSection.system,
      description: "Typed commands for this app's own tools. Not a system shell.",
      keywords: const ['command', 'console', 'cli', 'prompt', 'run'],
      icon: Icons.terminal,
      builder: (context) => const TerminalScreen(),
    ),
  ],
  commands: kBuiltinCommands,
);
