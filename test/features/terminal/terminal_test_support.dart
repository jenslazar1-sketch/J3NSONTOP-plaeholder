import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:j3nsontop_multitool/core/commands/terminal_command.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/core/tools/tool_definition.dart';
import 'package:j3nsontop_multitool/core/tools/tool_registry.dart';
import 'package:j3nsontop_multitool/features/terminal/presentation/terminal_session.dart';
import 'package:j3nsontop_multitool/features/terminal/terminal_module.dart';

import '../../helpers/harness.dart';

Widget _noPage(BuildContext context) => const SizedBox.shrink();

/// A few tools in different sections (one needs a desktop-only capability).
List<ToolDefinition> fakeTools() => [
  const ToolDefinition(
    id: 'dev.base64',
    name: 'Base64',
    section: ToolSection.devTools,
    description: 'Encode and decode Base64 text',
    keywords: ['encode', 'decode', 'b64'],
    icon: Icons.code,
    builder: _noPage,
  ),
  const ToolDefinition(
    id: 'files.hash',
    name: 'Hash Files',
    section: ToolSection.fileTools,
    description: 'Compute SHA-256 checksums of files',
    keywords: ['checksum', 'sha256'],
    icon: Icons.tag,
    builder: _noPage,
  ),
  const ToolDefinition(
    id: 'config.json',
    name: 'JSON Formatter',
    section: ToolSection.configLab,
    description: 'Validate and pretty-print JSON',
    keywords: ['json', 'format'],
    icon: Icons.data_object,
    builder: _noPage,
  ),
  const ToolDefinition(
    id: 'mods.apply',
    name: 'Apply Profile',
    section: ToolSection.mods,
    description: 'Apply a mod profile to a linked game folder',
    keywords: ['mods', 'profile'],
    icon: Icons.extension,
    requiredCapabilities: {Capability.inPlaceModApply},
    builder: _noPage,
  ),
];

/// A command registered by "another feature".
class FakeHashCommand extends TerminalCommand {
  const FakeHashCommand();

  @override
  String get name => 'hash';

  @override
  List<String> get aliases => const ['sha'];

  @override
  String get summary => 'Hash text';

  @override
  String get usage => 'hash <text> [--algo sha256|md5]';

  @override
  Set<String> get valueOptions => const {'algo'};

  @override
  List<CommandArg> get args => const [
    CommandArg('text', 'Text to hash'),
    CommandArg('algo', 'Algorithm', optional: true, values: ['sha256', 'md5', 'sha1']),
  ];

  @override
  List<String> get examples => const ['hash abc --algo md5'];

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async =>
      CommandResult.ok([TermLine('hash:${args.rest()}:${args.option('algo') ?? 'sha256'}')]);

  @override
  List<String> complete(CommandContext ctx, List<String> typedArgs) =>
      typedArgs.length == 2 ? const ['sha256', 'sha1', 'md5'] : const [];
}

/// Waits for [gate]; ignores cancellation (the terminal must still stop
/// waiting on Ctrl+C).
class SlowCommand extends TerminalCommand {
  SlowCommand();

  Completer<CommandResult> gate = Completer<CommandResult>();

  @override
  String get name => 'slow';

  @override
  String get summary => 'Waits until the test releases it';

  @override
  String get usage => 'slow';

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) => gate.future;
}

/// Cooperative long-running command: checks the token between steps.
class CoopCommand extends TerminalCommand {
  const CoopCommand();

  @override
  String get name => 'coop';

  @override
  String get summary => 'Loops until cancelled';

  @override
  String get usage => 'coop';

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    for (var i = 0; i < 10000; i++) {
      ctx.token.throwIfCancelled();
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    return CommandResult.text('finished');
  }
}

class BoomCommand extends TerminalCommand {
  const BoomCommand();

  @override
  String get name => 'boom';

  @override
  String get summary => 'Throws';

  @override
  String get usage => 'boom';

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async => throw StateError('kaput');

  @override
  List<String> complete(CommandContext ctx, List<String> typedArgs) => throw StateError('bad completer');
}

/// Throws synchronously (not inside a Future).
class SyncBoomCommand extends TerminalCommand {
  const SyncBoomCommand();

  @override
  String get name => 'syncboom';

  @override
  String get summary => 'Throws synchronously';

  @override
  String get usage => 'syncboom';

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) => throw ArgumentError('sync failure');
}

/// Registry: the real terminal module plus a fake "dev tools" feature.
ToolRegistry buildTerminalRegistry({List<TerminalCommand> extra = const []}) => ToolRegistry([
  terminalModule,
  FeatureModule(id: 'dev_tools', tools: fakeTools(), commands: [const FakeHashCommand(), ...extra]),
]);

/// Unit-test driver around a [ProviderContainer].
class TerminalDriver {
  TerminalDriver(this.env, {ToolRegistry? registry, AppPlatform platform = AppPlatform.linux})
    : container = ProviderContainer(
        overrides: env.overrides(registry: registry ?? buildTerminalRegistry(), platform: platform),
      );

  final TestEnv env;
  final ProviderContainer container;
  final List<String> routes = [];

  TerminalSession get session => container.read(terminalSessionProvider.notifier);
  TerminalState get state => container.read(terminalSessionProvider);

  /// Clears the screen, runs [line] and returns the transcript without the
  /// echoed command line.
  Future<List<String>> run(String line) async {
    session.clear();
    await session.submit(line, navigate: routes.add);
    final rows = state.rows;
    return [for (final r in rows.skip(1)) r.plain];
  }

  /// Output of [line] as one string.
  Future<String> text(String line) async => (await run(line)).join('\n');

  Future<void> dispose() async {
    await session.historySaved;
    container.dispose();
  }
}

/// Deletes the test data directory, retrying while background saves that
/// were started by the code under test (activity history, command history)
/// are still finishing their atomic writes.
Future<void> disposeEnv(TestEnv env) async {
  for (var attempt = 0; ; attempt++) {
    try {
      await env.dispose();
      return;
    } on FileSystemException {
      if (attempt >= 40) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }
}
