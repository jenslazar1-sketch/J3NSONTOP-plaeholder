import 'package:flutter/material.dart';

import '../../core/platform/capabilities.dart';
import '../../core/tools/tool_definition.dart';
import 'presentation/adb_manager_page.dart';
import 'presentation/frida_console_page.dart';
import 'presentation/gadget_injector_page.dart';
import 'presentation/live_mod_page.dart';
import 'presentation/script_library_page.dart';

final FeatureModule fridaModule = FeatureModule(
  id: 'frida_tools',
  tools: [
    ToolDefinition(
      id: AdbManagerPage.id,
      name: 'ADB Manager',
      section: ToolSection.devTools,
      description: 'Connect to Android devices, manage packages, logcat, shell and port forwarding.',
      icon: Icons.adb,
      keywords: const ['adb', 'android', 'device', 'logcat', 'shell', 'usb', 'debug', 'packages', 'install'],
      platforms: const {AppPlatform.windows, AppPlatform.linux},
      builder: (context) => const AdbManagerPage(),
    ),
    ToolDefinition(
      id: FridaConsolePage.id,
      name: 'Frida Console',
      section: ToolSection.devTools,
      description: 'Attach to processes, run Frida scripts, inspect running apps in real time.',
      icon: Icons.memory,
      keywords: const ['frida', 'hook', 'inject', 'process', 'attach', 'spawn', 'script', 'console', 'dynamic'],
      platforms: const {AppPlatform.windows, AppPlatform.linux},
      builder: (context) => const FridaConsolePage(),
    ),
    ToolDefinition(
      id: GadgetInjectorPage.id,
      name: 'Gadget Injector',
      section: ToolSection.devTools,
      description: 'Inject Frida gadget into APK and IPA files for persistent instrumentation.',
      icon: Icons.vaccines,
      keywords: const ['gadget', 'inject', 'apk', 'ipa', 'frida', 'patch', 'repack', 'smali', 'dylib'],
      platforms: const {AppPlatform.windows, AppPlatform.linux},
      builder: (context) => const GadgetInjectorPage(),
    ),
    ToolDefinition(
      id: ScriptLibraryPage.id,
      name: 'Frida Scripts',
      section: ToolSection.devTools,
      description: 'Pre-built Frida script library: discovery, hooking, memory, modding and spawner templates.',
      icon: Icons.library_books,
      keywords: const ['script', 'library', 'template', 'hook', 'scan', 'memory', 'mod', 'spawner', 'ssl', 'bypass'],
      platforms: const {AppPlatform.android, AppPlatform.ios, AppPlatform.windows, AppPlatform.linux},
      builder: (context) => const ScriptLibraryPage(),
    ),
    ToolDefinition(
      id: LiveModPage.id,
      name: 'Live AI Mod Engine',
      section: ToolSection.devTools,
      description: 'AI-powered live game modding: scan, hook and modify running games with generated Frida scripts.',
      icon: Icons.auto_awesome,
      keywords: const ['ai', 'mod', 'live', 'game', 'hack', 'modify', 'scan', 'hook', 'value', 'cheat', 'engine'],
      platforms: const {AppPlatform.windows, AppPlatform.linux},
      builder: (context) => const LiveModPage(),
    ),
  ],
);
