import '../../../core/commands/terminal_command.dart';
import 'basic_commands.dart';
import 'help_command.dart';
import 'history_command.dart';
import 'open_command.dart';
import 'skull_command.dart';
import 'theme_command.dart';
import 'tools_command.dart';
import 'ws_command.dart';

/// Commands contributed by the terminal feature itself. Other features add
/// their own through `FeatureModule.commands`.
const List<TerminalCommand> kBuiltinCommands = [
  HelpCommand(),
  ToolsCommand(),
  OpenCommand(),
  HistoryCommand(),
  ThemeCommand(),
  WsCommand(),
  ClearCommand(),
  EchoCommand(),
  AboutCommand(),
  DateCommand(),
  SkullCommand(),
];
