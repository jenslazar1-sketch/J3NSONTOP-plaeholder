import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/commands/terminal_command.dart';
import '../../core/utils/format.dart';
import '../../core/workspace/workspace.dart';
import '../../core/workspace/workspace_controller.dart';
import 'data/mod_library.dart';
import 'data/profile_store.dart';
import 'data/target_game.dart';
import 'domain/issues.dart';
import 'domain/manifest.dart';
import 'domain/plan.dart';
import 'domain/profile.dart';
import 'domain/resolver.dart';

/// `profiles list|show|check|plan` - read-only access to the active
/// workspace's mod profiles. Applying is only done from the Mods section,
/// where the plan is reviewed and confirmed.
class ProfilesCommand extends TerminalCommand {
  const ProfilesCommand();

  static const subcommands = ['list', 'show', 'check', 'plan'];

  @override
  String get name => 'profiles';

  @override
  String get summary => 'List, inspect, check and dry-run mod profiles of the active workspace (read-only)';

  @override
  String get usage => 'profiles <list|show|check|plan> [profile-id] [--limit N]';

  @override
  List<CommandArg> get args => const [
    CommandArg('subcommand', 'list | show | check | plan', values: subcommands),
    CommandArg('profile-id', 'Profile id (see "profiles list")', optional: true),
  ];

  @override
  Set<String> get valueOptions => const {'limit'};

  @override
  List<String> get examples => const [
    'profiles list',
    'profiles show hardcore-run',
    'profiles check broken-deps',
    'profiles plan conflict-demo --limit 20',
  ];

  static const _applyHint = 'Read-only: nothing was written. Apply profiles from the Mods section (open mods.manager).';

  @override
  List<String> complete(CommandContext ctx, List<String> typedArgs) {
    if (typedArgs.length <= 1) return subcommands;
    if (typedArgs.length == 2 && typedArgs.first != 'list') {
      final ws = ctx.read(activeWorkspaceProvider);
      if (ws == null) return const [];
      final dir = Directory(ProfileStore(ctx.read(workspacesProvider.notifier).metaDir(ws)).dir);
      try {
        return [
          for (final e in dir.listSync(followLinks: false))
            if (e is File && e.path.endsWith(kProfileExtension)) p.basename(e.path).replaceAll(kProfileExtension, ''),
        ]..sort();
      } on FileSystemException {
        return const [];
      }
    }
    return const [];
  }

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    final sub = args.at(0);
    if (sub == null || !subcommands.contains(sub)) {
      return CommandResult.error(sub == null ? 'Missing subcommand' : 'Unknown subcommand "$sub"', usage: usage);
    }
    final ws = ctx.read(activeWorkspaceProvider);
    if (ws == null) {
      return CommandResult.error('No active workspace. Open one in Workspaces, or create the sample workspace.');
    }
    final meta = ctx.read(workspacesProvider.notifier).metaDir(ws);
    final store = ProfileStore(meta);
    final library = await ModLibrary(meta).list();
    final manifests = ModLibrary.manifestsById(library);
    final invalid = ModLibrary.invalidIds(library);

    if (sub == 'list') {
      final profiles = await store.list();
      if (profiles.isEmpty) {
        return CommandResult.ok([
          TermLine('No profiles in workspace "${ws.name}".'),
          TermLine.dim('Create one in the Mods section.'),
        ]);
      }
      final lines = <TermLine>[
        TermLine('Profiles in "${ws.name}" (${profiles.length})', TermStyle.accent),
        TermLine.dim('${'ID'.padRight(22)} ${'MODS'.padRight(6)} ${'TARGET'.padRight(12)} STATUS  NAME'),
      ];
      for (final sp in profiles) {
        final prof = sp.profile;
        if (prof == null) {
          lines.add(
            TermLine.error('${sp.id.padRight(22)} damaged file: ${sp.issues.map((i) => i.message).join('; ')}'),
          );
          continue;
        }
        final report = ModResolver.resolve(
          profile: prof,
          library: manifests,
          invalid: invalid,
          target: await readTargetGame(ws.rootPath, prof),
        );
        final status = report.hasErrors ? 'ERR' : (report.hasWarnings ? 'WARN' : 'OK');
        lines.add(
          TermLine(
            '${prof.id.padRight(22)} ${'${prof.enabledIds.length}/${prof.mods.length}'.padRight(6)} '
            '${prof.target.padRight(12)} ${status.padRight(7)} ${prof.name}',
            report.hasErrors ? TermStyle.error : (report.hasWarnings ? TermStyle.warning : TermStyle.normal),
          ),
        );
      }
      lines.add(TermLine.dim(_applyHint));
      return CommandResult.ok(lines);
    }

    final id = args.at(1);
    if (id == null) return CommandResult.error('Missing profile id', usage: usage);
    final prof = await store.load(id);
    if (prof == null) {
      return CommandResult.error('No valid profile "$id" in workspace "${ws.name}". Try "profiles list".');
    }
    final target = await readTargetGame(ws.rootPath, prof);
    final report = ModResolver.resolve(profile: prof, library: manifests, invalid: invalid, target: target);

    switch (sub) {
      case 'show':
        return CommandResult.ok([
          TermLine('${prof.name} (${prof.id})', TermStyle.accent),
          if (prof.description.isNotEmpty) TermLine(prof.description),
          TermLine('target: ${prof.target}   game: ${target.isKnown ? target.toString() : 'unknown'}'),
          TermLine.dim('load order (first -> last, last wins):'),
          for (var i = 0; i < prof.mods.length; i++) _modLine(i, prof.mods[i], manifests, invalid),
          TermLine.dim(_applyHint),
        ]);
      case 'check':
        return _check(prof, report);
      case 'plan':
        return _plan(ctx, ws, prof, report, library, args);
    }
    return CommandResult.error('Unknown subcommand "$sub"', usage: usage);
  }

  TermLine _modLine(int i, ProfileMod m, Map<String, ModManifest> manifests, Set<String> invalid) {
    final man = manifests[m.id];
    final state = man == null ? (invalid.contains(m.id) ? 'INVALID' : 'MISSING') : '${man.version}';
    return TermLine(
      '${(i + 1).toString().padLeft(2)}. [${m.enabled ? 'x' : ' '}] ${m.id} $state',
      man == null && m.enabled ? TermStyle.error : (m.enabled ? TermStyle.normal : TermStyle.dim),
    );
  }

  CommandResult _check(ModProfile prof, ResolutionReport report) {
    final lines = <TermLine>[
      TermLine(
        'check ${prof.id}: ${report.order.length} enabled package(s), target ${report.target}',
        TermStyle.accent,
      ),
    ];
    if (report.errors.isNotEmpty) {
      lines.add(const TermLine('errors:', TermStyle.error));
      for (final i in report.errors) {
        lines.add(TermLine.error(i.message));
      }
    }
    if (report.warnings.isNotEmpty) {
      lines.add(const TermLine('warnings:', TermStyle.warning));
      for (final i in report.warnings) {
        lines.add(TermLine.warn(i.message));
      }
    }
    if (report.overlaps.isNotEmpty) {
      lines.add(const TermLine('overlaps (last one wins):', TermStyle.warning));
      for (final o in report.overlaps) {
        lines.add(TermLine.warn('${o.target}: ${o.providers.join(' -> ')} => ${o.winner} wins'));
      }
    }
    for (final n in report.notes) {
      lines.add(TermLine.dim('note: ${n.message}'));
    }
    if (report.issues.isEmpty) lines.add(TermLine.ok('OK: ready to apply'));
    lines.add(
      TermLine(
        'result: ${report.errors.length} error(s), ${report.issues.where((i) => i.severity == IssueSeverity.warning).length} '
        'warning(s)',
        report.hasErrors ? TermStyle.error : TermStyle.success,
      ),
    );
    return CommandResult(lines, exitCode: report.hasErrors ? 1 : 0);
  }

  Future<CommandResult> _plan(
    CommandContext ctx,
    Workspace ws,
    ModProfile prof,
    ResolutionReport report,
    List<LibraryEntry> library,
    ParsedArgs args,
  ) async {
    if (report.hasErrors) {
      return CommandResult([
        TermLine.error('Cannot plan ${prof.id}: ${report.errors.length} resolution error(s)'),
        for (final e in report.errors) TermLine.error(e.message),
        TermLine.dim('Run "profiles check ${prof.id}" for the full report.'),
      ], exitCode: 1);
    }
    final limitRaw = args.option('limit');
    final limit = limitRaw == null ? 50 : int.tryParse(limitRaw);
    if (limit == null || limit < 1) return CommandResult.error('--limit must be a positive number', usage: usage);
    final sources = [
      for (final id in report.order)
        PlanSource(
          manifest: ModLibrary.entryFor(library, id)!.manifest!,
          archivePath: ModLibrary.entryFor(library, id)!.path,
        ),
    ];
    final ApplyPlan plan;
    try {
      plan = await buildPlanInBackground(
        workspaceRoot: ws.rootPath,
        profile: prof,
        packages: sources,
        token: ctx.token,
      );
    } catch (e) {
      return CommandResult.error('Planning failed: $e');
    }
    final lines = <TermLine>[TermLine('dry-run plan for ${prof.id} -> ${plan.targetRel}', TermStyle.accent)];
    for (final c in plan.changes.take(limit)) {
      lines.add(
        TermLine(
          '${c.action.label.padRight(9)} ${c.path}  ${Fmt.bytes(c.size)}  <- ${c.packageId}'
          '${c.overrides.isEmpty ? '' : ' (overrides ${c.overrides.join(', ')})'}',
          switch (c.action) {
            ChangeAction.create => TermStyle.success,
            ChangeAction.overwrite => TermStyle.warning,
            ChangeAction.unchanged => TermStyle.dim,
          },
        ),
      );
    }
    if (plan.changes.length > limit) lines.add(TermLine.dim('... ${plan.changes.length - limit} more (use --limit)'));
    for (final d in plan.directoriesToCreate) {
      lines.add(TermLine('MKDIR     $d/', TermStyle.success));
    }
    lines
      ..add(
        TermLine(
          'total: ${plan.creates} create, ${plan.overwrites} overwrite, ${plan.unchanged} unchanged, '
          '${plan.directoriesToCreate.length} folder(s), ${Fmt.bytes(plan.bytesToWrite)} to write',
        ),
      )
      ..add(TermLine.dim(_applyHint));
    return CommandResult.ok(lines);
  }
}
