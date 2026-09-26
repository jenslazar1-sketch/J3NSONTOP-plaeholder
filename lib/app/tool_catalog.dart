import '../core/tools/tool_definition.dart';
import '../core/tools/tool_registry.dart';
import '../features/asset_lab/asset_lab_module.dart';
import '../features/config_lab/config_lab_module.dart';
import '../features/dev_tools/dev_tools_module.dart';
import '../features/file_tools/file_tools_module.dart';
import '../features/frida_tools/frida_module.dart';
import '../features/mods/mods_module.dart';
import '../features/roblox_executor/roblox_module.dart';
import '../features/terminal/terminal_module.dart';
import '../features/workspaces/workspaces_module.dart';

/// The only place that knows every feature. Adding a feature module here
/// wires its tools into navigation, search, the palette and the terminal.
List<FeatureModule> allFeatureModules() => [
  workspacesModule,
  modsModule,
  configLabModule,
  assetLabModule,
  fileToolsModule,
  devToolsModule,
  fridaModule,
  robloxModule,
  terminalModule,
];

ToolRegistry buildToolRegistry() => ToolRegistry(allFeatureModules());
