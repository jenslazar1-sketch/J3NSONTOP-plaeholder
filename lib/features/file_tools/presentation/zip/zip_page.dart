import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/archive/safe_zip.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/workspace.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../domain/zip_studio.dart';
import '../shared.dart';
import 'zip_controller.dart';

/// ZIP Studio: create and safely extract archives.
class ZipPage extends ConsumerWidget {
  const ZipPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.draft<ZipMode>('$kZipToolId/mode', ZipMode.create);
    final modePanel = NeonPanel(
      kicker: 'Mode',
      title: mode == ZipMode.create ? 'Pack files into a ZIP' : 'Inspect and extract a ZIP',
      icon: Icons.folder_zip_outlined,
      child: ChoiceRow<ZipMode>(
        label: 'Action',
        options: ZipMode.values,
        selected: mode,
        labelOf: (m) => m.label,
        onSelected: (m) => ref.setDraft('$kZipToolId/mode', m),
      ),
    );
    return switch (mode) {
      ZipMode.create => ToolScaffold(
        toolId: kZipToolId,
        inputs: [modePanel, const _CreateSources()],
        results: const [_CreateOutput()],
      ),
      ZipMode.extract => ToolScaffold(
        toolId: kZipToolId,
        inputs: [modePanel, const _ExtractInput(), const _LimitsPanel()],
        results: const [_ExtractPreview()],
      ),
    };
  }
}

// ---------------------------------------------------------------------------
// Create

class _CreateSources extends ConsumerWidget {
  const _CreateSources();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(zipCreateProvider);
    final ctl = ref.read(zipCreateProvider.notifier);
    final ws = ref.watch(activeWorkspaceProvider);
    final plan = st.plan;
    final noWs = ws == null ? 'Open a workspace to browse its files' : null;

    Future<void> addFolder() async {
      final folder = await pickWorkspaceFolder(context, ref, title: 'Add a folder to the archive');
      if (folder == null) return;
      try {
        final (entries, walk) = await zipEntriesForFolder(folder, origin: 'workspace');
        ctl.addEntries(
          entries,
          notice: walk.truncated
              ? 'Only the first ${entries.length} files of that folder were added.'
              : (walk.skippedLinks.isNotEmpty ? '${walk.skippedLinks.length} symbolic link(s) skipped.' : null),
        );
      } catch (e) {
        ref.read(activityProvider.notifier).notify(NoticeKind.error, 'Cannot list folder: ${describeError(e)}');
      }
    }

    return NeonPanel(
      kicker: 'Sources',
      title: plan.entries.isEmpty
          ? 'Nothing added yet'
          : '${plan.entries.length} entries · ${Fmt.bytes(plan.totalBytes)}',
      icon: Icons.playlist_add,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ButtonWrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              NeonButton.secondary(
                label: 'Workspace file',
                icon: Icons.insert_drive_file_outlined,
                tooltip: noWs ?? 'Add a file (stored under its name)',
                onPressed: ws == null || st.running
                    ? null
                    : () async {
                        final f = await pickWorkspaceFile(context, ref, title: 'Add a file to the archive');
                        if (f == null) return;
                        ctl.addEntries([await zipEntryForFile(f.path, origin: 'workspace')]);
                      },
              ),
              NeonButton.secondary(
                label: 'Workspace folder',
                icon: Icons.folder_open,
                tooltip: noWs ?? 'Add a folder with everything inside it',
                onPressed: ws == null || st.running ? null : addFolder,
              ),
              NeonButton.secondary(
                label: 'From device',
                icon: Icons.upload_file_outlined,
                onPressed: st.running
                    ? null
                    : () async {
                        final files = await pickDeviceFiles(ref, toolKey: kZipToolId);
                        ctl.addEntries([for (final f in files) await zipEntryForFile(f.path, origin: 'device')]);
                      },
              ),
              if (plan.entries.isNotEmpty)
                NeonButton.ghost(label: 'Clear', icon: Icons.clear_all, onPressed: st.running ? null : ctl.clear),
            ],
          ),
          if (st.notice != null) ...[const SizedBox(height: J3Space.sm), InfoLine(st.notice!)],
          const SizedBox(height: J3Space.md),
          if (plan.entries.isEmpty)
            const EmptyState(
              glyph: '[ zip ]',
              title: 'Add files or folders',
              message: 'Folders keep their name as the top folder in the archive. Symbolic links are skipped.',
            )
          else ...[
            if (plan.problems.isNotEmpty) ...[
              StatusBanner(
                kind: StatusKind.error,
                title: 'Fix before creating',
                message:
                    '${plan.problems.length} entr${plan.problems.length == 1 ? 'y has' : 'ies have'} a problem. '
                    'Remove duplicates or rename the files.',
              ),
              const SizedBox(height: J3Space.sm),
            ],
            BoundedList(
              itemCount: plan.entries.length,
              maxHeight: 360,
              inlineUpTo: 20,
              itemBuilder: (context, i) {
                final e = plan.entries[i];
                final problem = plan.problems[e.archivePath];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      if (problem != null) ...[
                        const StatusBadge(kind: StatusKind.error, text: 'BLOCKED', dense: true),
                        const SizedBox(width: J3Space.xs),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              e.archivePath,
                              style: J3Type.codeSmall.copyWith(color: J3Colors.text),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(problem ?? '${Fmt.bytes(e.size)} · ${e.origin}', style: J3Type.caption),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Remove ${e.archivePath}',
                        onPressed: st.running ? null : () => ctl.remove(e.archivePath),
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _CreateOutput extends ConsumerWidget {
  const _CreateOutput();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(zipCreateProvider);
    final ctl = ref.read(zipCreateProvider.notifier);
    final ws = ref.watch(activeWorkspaceProvider);
    final nameCtl = ref.watch(draftTextProvider('$kZipToolId/name'));
    final plan = st.plan;
    final folder = ws == null ? null : (st.destFolder ?? ws.rootPath);

    Future<void> createAndExport() async {
      final created = await ctl.create(
        archiveName: nameCtl.text.isEmpty ? suggestArchiveName(plan) : nameCtl.text,
        toWorkspace: false,
      );
      if (created == null || !context.mounted) return;
      final file = File(created.path);
      try {
        if (created.bytes > kMaxExportArchiveBytes) {
          ref
              .read(activityProvider.notifier)
              .notify(
                NoticeKind.warning,
                'The archive is ${Fmt.bytes(created.bytes)}; exports are limited to '
                '${Fmt.bytes(kMaxExportArchiveBytes)}. Use "Create in workspace" instead.',
              );
          return;
        }
        final bytes = await file.readAsBytes();
        if (!context.mounted) return;
        await saveOutput(
          context,
          ref,
          suggestedName: p.basename(created.path),
          bytes: bytes,
          mimeType: 'application/zip',
          toolId: kZipToolId,
        );
      } finally {
        // The staging copy is only a hand-over buffer.
        if (await file.exists()) await file.delete();
        final dir = file.parent;
        if (await dir.exists() && await dir.list().isEmpty) await dir.delete();
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeonPanel(
          kicker: 'Output',
          title: 'Archive',
          icon: Icons.archive_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('zip.name'),
                controller: nameCtl,
                style: J3Type.code,
                decoration: InputDecoration(labelText: 'Archive name', hintText: suggestArchiveName(plan)),
              ),
              const SizedBox(height: J3Space.md),
              if (ws != null) ...[
                Text('Save into workspace folder', style: J3Type.caption),
                ButtonWrap(
                  spacing: J3Space.sm,
                  runSpacing: J3Space.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(_folderLabel(ws, folder!), style: J3Type.code),
                    NeonButton.ghost(
                      label: 'Change folder',
                      icon: Icons.folder_open,
                      dense: true,
                      onPressed: st.running
                          ? null
                          : () async {
                              final f = await pickWorkspaceFolder(context, ref, title: 'Save the archive into...');
                              if (f != null) ctl.setDestFolder(f);
                            },
                    ),
                  ],
                ),
                const SizedBox(height: J3Space.xs),
                const InfoLine('An existing archive is never replaced: the new one gets a " (2)" name.'),
                const SizedBox(height: J3Space.md),
              ],
              ButtonWrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                children: [
                  if (ws != null)
                    NeonButton(
                      key: const Key('zip.create'),
                      label: 'Create in workspace',
                      icon: Icons.inventory_2_outlined,
                      busy: st.running,
                      onPressed: !plan.canCreate
                          ? null
                          : () => ctl.create(
                              archiveName: nameCtl.text.isEmpty ? suggestArchiveName(plan) : nameCtl.text,
                              toWorkspace: true,
                            ),
                    ),
                  NeonButton.secondary(
                    label: 'Create & export...',
                    icon: Icons.ios_share,
                    busy: st.running,
                    tooltip:
                        'Build the archive, then save it with the system dialog or share it '
                        '(up to ${Fmt.bytes(kMaxExportArchiveBytes)})',
                    onPressed: !plan.canCreate ? null : createAndExport,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: J3Space.md),
        OperationProgressPanel(operationId: st.opId, label: 'Compressing...'),
        if (st.error != null) ErrorPanel(title: 'Could not create the archive', error: st.error!),
        if (st.created != null && !st.created!.staged)
          StatusBanner(
            kind: StatusKind.success,
            title: 'ARCHIVE CREATED',
            message:
                '${st.created!.label} · ${Fmt.bytes(st.created!.bytes)} · ${Fmt.count(st.created!.entries, 'file')} '
                '(${Fmt.bytes(plan.totalBytes)} before compression)',
          ),
      ],
    );
  }
}

String _folderLabel(Workspace ws, String folder) {
  final rel = workspaceLabel(ws, folder);
  return rel == '.' ? '${ws.name} (workspace root)' : rel;
}

// ---------------------------------------------------------------------------
// Extract

class _ExtractInput extends ConsumerWidget {
  const _ExtractInput();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(zipExtractProvider);
    final ctl = ref.read(zipExtractProvider.notifier);
    final ws = ref.watch(activeWorkspaceProvider);

    return NeonPanel(
      kicker: 'Archive',
      title: st.zip?.label ?? 'Choose a ZIP',
      icon: Icons.unarchive_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NeonButton.secondary(
            key: const Key('zip.open'),
            label: st.zip == null ? 'Open archive...' : 'Open another...',
            icon: Icons.file_open_outlined,
            onPressed: st.running
                ? null
                : () async {
                    final sel = await pickInputFile(
                      context,
                      ref,
                      extensions: const ['zip', 'j3mod'],
                      title: 'Open a ZIP',
                    );
                    if (sel == null) return;
                    ctl.open(
                      FileItem(
                        path: sel.path,
                        label: sel.displayName,
                        inWorkspace: sel.fromWorkspace,
                        size: await File(sel.path).length(),
                      ),
                    );
                  },
          ),
          if (st.zip != null && ws == null) ...[
            const SizedBox(height: J3Space.md),
            const NoWorkspaceNotice(what: 'Extracting'),
          ],
          if (st.zip != null && ws != null && st.inspection != null) ...[
            const SizedBox(height: J3Space.md),
            _Destination(ws: ws),
          ],
        ],
      ),
    );
  }
}

class _Destination extends ConsumerWidget {
  const _Destination({required this.ws});
  final Workspace ws;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(zipExtractProvider);
    final ctl = ref.read(zipExtractProvider.notifier);
    final dest = ctl.destination();
    final conflicts = ctl.conflicts();
    final ins = st.inspection!;

    Future<void> run() async {
      if (st.policy == ExistingFilePolicy.overwrite && conflicts.isNotEmpty) {
        final ok = await showJ3Confirm(
          context,
          title: 'Overwrite ${conflicts.length} existing file(s)?',
          message:
              'These files will be replaced by the archive versions. A backup copy of each is written to the '
              'workspace backups folder first.',
          confirmLabel: 'Overwrite',
          destructive: true,
          details: conflicts,
        );
        if (!ok) return;
      }
      await ctl.extract();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Destination', style: J3Type.label),
        const SizedBox(height: J3Space.xs),
        ButtonWrap(
          spacing: J3Space.sm,
          runSpacing: J3Space.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(dest == null ? '-' : '${_folderLabel(ws, dest)}/', key: const Key('zip.dest'), style: J3Type.code),
            NeonButton.ghost(
              label: 'Change folder',
              icon: Icons.folder_open,
              dense: true,
              onPressed: st.running
                  ? null
                  : () async {
                      final f = await pickWorkspaceFolder(context, ref, title: 'Extract into...');
                      if (f != null) ctl.setDestParent(f);
                    },
            ),
          ],
        ),
        InkSurface(
          child: OptionSwitch(
            label: 'Create a new folder named after the archive',
            description: 'Recommended: nothing existing is touched',
            value: st.makeSubfolder,
            onChanged: st.running ? null : ctl.setSubfolder,
          ),
        ),
        if (conflicts.isNotEmpty) ...[
          const SizedBox(height: J3Space.sm),
          StatusBanner(
            kind: StatusKind.warning,
            title: '${conflicts.length} file(s) already exist',
            message: 'Choose what happens to them.',
            details: conflicts.take(12).toList(),
          ),
          const SizedBox(height: J3Space.sm),
          ChoiceRow<ExistingFilePolicy>(
            label: 'Existing files',
            options: const [ExistingFilePolicy.skip, ExistingFilePolicy.fail, ExistingFilePolicy.overwrite],
            selected: st.policy,
            labelOf: (p) => switch (p) {
              ExistingFilePolicy.skip => 'Skip (keep mine)',
              ExistingFilePolicy.fail => 'Stop with an error',
              ExistingFilePolicy.overwrite => 'Overwrite (danger)',
            },
            onSelected: ctl.setPolicy,
          ),
        ],
        const SizedBox(height: J3Space.md),
        NeonButton(
          key: const Key('zip.extract'),
          label: ins.isSafe ? 'Extract ${Fmt.count(ins.files.length, 'file')}' : 'Blocked',
          icon: ins.isSafe ? Icons.unarchive : Icons.block,
          busy: st.running,
          tooltip: ins.isSafe ? null : 'The archive has blocked entries (see the preview)',
          onPressed: ins.isSafe ? run : null,
        ),
      ],
    );
  }
}

class _LimitsPanel extends StatelessWidget {
  const _LimitsPanel();

  @override
  Widget build(BuildContext context) {
    return NeonPanel(
      kicker: 'Safety',
      title: 'Extraction limits',
      icon: Icons.shield_outlined,
      emphasis: PanelEmphasis.subtle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final l in describeZipLimits())
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: InfoLine(l, icon: Icons.check),
            ),
          const SizedBox(height: J3Space.xs),
          Text(
            'Every entry is decompressed with a byte counter and CRC-32 check, so a lying archive stops at its '
            'declared size. Blocked archives are never partially extracted.',
            style: J3Type.caption,
          ),
        ],
      ),
    );
  }
}

class _ExtractPreview extends ConsumerWidget {
  const _ExtractPreview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(zipExtractProvider);
    final fx = context.effects;
    final ins = st.inspection;
    final ws = ref.watch(activeWorkspaceProvider);

    final children = <Widget>[
      OperationProgressPanel(operationId: st.opId, label: 'Extracting...'),
      if (st.error != null) ErrorPanel(title: 'Extraction failed', error: st.error!),
      if (st.outcome != null) _OutcomeBanner(outcome: st.outcome!, ws: ws),
    ];

    if (st.zip == null) {
      children.add(
        const NeonPanel(
          emphasis: PanelEmphasis.subtle,
          child: EmptyState(
            glyph: '[ >zip< ]',
            title: 'No archive open',
            message:
                'The preview lists every entry and blocks unsafe ones before anything is written. '
                'Try the .j3mod files in the sample workspace "downloads/" folder - they are ZIPs.',
          ),
        ),
      );
    } else if (st.inspectError != null) {
      children.add(
        ErrorPanel(
          title: 'Not a readable ZIP',
          error: st.inspectError!,
          hint: 'Only standard ZIP archives (Stored/Deflate) are supported.',
        ),
      );
    } else if (ins != null) {
      final byEntry = <String, List<ZipIssue>>{};
      for (final i in ins.issues) {
        byEntry.putIfAbsent(i.entry, () => []).add(i);
      }
      final global = byEntry['*'] ?? const <ZipIssue>[];
      final fatal = ins.fatal.length;
      final warnings = ins.issues.length - fatal;
      children.add(
        ins.isSafe
            ? StatusBanner(
                kind: warnings > 0 ? StatusKind.warning : StatusKind.success,
                title: warnings > 0 ? 'SAFE WITH WARNINGS' : 'SAFE TO EXTRACT',
                message:
                    '${ins.files.length} files, ${Fmt.bytes(ins.totalBytes)} unpacked'
                    '${warnings > 0 ? ', $warnings warning(s)' : ''}.',
              )
            : StatusBanner(
                kind: StatusKind.error,
                title: 'BLOCKED',
                message: '$fatal problem(s) make this archive unsafe. Nothing will be extracted.',
                details: [for (final i in ins.fatal.take(12)) i.toString()],
              ),
      );
      children.add(
        NeonPanel(
          kicker: 'Preview',
          title: '${ins.entries.length} entries',
          icon: Icons.list_alt,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final g in global) InfoLine(g.toString(), icon: Icons.block),
              BoundedList(
                itemCount: ins.entries.length,
                maxHeight: 440,
                itemBuilder: (context, i) {
                  final e = ins.entries[i];
                  final issues = byEntry[e.rawName] ?? const <ZipIssue>[];
                  final blocked = issues.any((x) => x.isFatal);
                  return Container(
                    margin: const EdgeInsets.only(bottom: 2),
                    padding: const EdgeInsets.symmetric(horizontal: J3Space.xs, vertical: 3),
                    decoration: BoxDecoration(
                      color: blocked ? J3Colors.error.withValues(alpha: 0.08) : Colors.transparent,
                      borderRadius: J3Radius.small,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(
                              e.isDirectory ? Icons.folder_outlined : Icons.description_outlined,
                              size: 14,
                              color: J3Colors.textMuted,
                            ),
                            const SizedBox(width: J3Space.xs),
                            Expanded(
                              child: Text(
                                e.path ?? e.rawName,
                                style: J3Type.codeSmall.copyWith(color: blocked ? J3Colors.error : J3Colors.text),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          e.isDirectory
                              ? 'folder'
                              : '${Fmt.bytes(e.size)} · packed ${Fmt.bytes(e.compressedSize)} · ${ratioLabel(e)}'
                                    '${e.modified == null ? '' : ' · ${Fmt.dateTime(e.modified!)}'}',
                          style: J3Type.caption,
                        ),
                        for (final x in issues)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: StatusBadge(
                              dense: true,
                              kind: x.isFatal ? StatusKind.error : StatusKind.warning,
                              text: '${x.isFatal ? 'BLOCKED' : 'WARN'}: ${x.message}',
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: J3Space.xs),
              Text(
                'Unpacked ${Fmt.bytes(ins.totalBytes)} · archive ${Fmt.bytes(st.zip!.size)}',
                style: J3Type.caption.copyWith(color: fx.accentText),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: J3Space.md), children[i]],
      ],
    );
  }
}

class _OutcomeBanner extends StatelessWidget {
  const _OutcomeBanner({required this.outcome, required this.ws});
  final ExtractOutcome outcome;
  final Workspace? ws;

  @override
  Widget build(BuildContext context) {
    final dest = ws == null ? p.basename(outcome.dest) : _folderLabel(ws!, outcome.dest);
    return StatusBanner(
      kind: outcome.cancelled ? StatusKind.warning : StatusKind.success,
      title: outcome.cancelled ? 'CANCELLED' : 'EXTRACTED',
      message: [
        '${outcome.written.length} written, ${outcome.skipped.length} skipped, ${Fmt.bytes(outcome.bytes)} into $dest/',
        if (outcome.cancelled) 'Files written before cancelling were kept.',
        if (outcome.backedUp.isNotEmpty) '${outcome.backedUp.length} overwritten file(s) were backed up first.',
      ].join('\n'),
      details: outcome.skipped.take(12).map((s) => 'skipped (exists): $s').toList(),
    );
  }
}
