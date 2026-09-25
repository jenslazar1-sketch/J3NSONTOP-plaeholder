import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/platform/file_access.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/file_backup.dart';
import '../../../../core/workspace/workspace.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../data/replace_service.dart';
import '../../domain/glob.dart';
import '../../domain/text_pattern.dart';
import '../shared/requests.dart';
import '../shared/scope_folder.dart';
import '../shared/ws_widgets.dart';

class ReplaceState {
  const ReplaceState({
    this.workspaceId,
    this.dir = '',
    this.isRegex = false,
    this.caseSensitive = true,
    this.wholeWord = false,
    this.includeHidden = false,
    this.preview,
    this.selected = const {},
    this.expanded = const {},
    this.opId,
    this.error,
    this.applied,
  });

  final String? workspaceId;
  final String dir;
  final bool isRegex;
  final bool caseSensitive;
  final bool wholeWord;
  final bool includeHidden;
  final ReplacePreview? preview;

  /// Relative paths chosen for applying.
  final Set<String> selected;
  final Set<String> expanded;
  final String? opId;
  final Object? error;
  final ReplaceApplyResult? applied;

  ReplaceState copyWith({
    String? workspaceId,
    String? dir,
    bool? isRegex,
    bool? caseSensitive,
    bool? wholeWord,
    bool? includeHidden,
    ReplacePreview? preview,
    bool clearPreview = false,
    Set<String>? selected,
    Set<String>? expanded,
    String? opId,
    bool clearOp = false,
    Object? error,
    bool clearError = false,
    ReplaceApplyResult? applied,
    bool clearApplied = false,
  }) => ReplaceState(
    workspaceId: workspaceId ?? this.workspaceId,
    dir: dir ?? this.dir,
    isRegex: isRegex ?? this.isRegex,
    caseSensitive: caseSensitive ?? this.caseSensitive,
    wholeWord: wholeWord ?? this.wholeWord,
    includeHidden: includeHidden ?? this.includeHidden,
    preview: clearPreview ? null : (preview ?? this.preview),
    selected: selected ?? this.selected,
    expanded: expanded ?? this.expanded,
    opId: clearOp ? null : (opId ?? this.opId),
    error: clearError ? null : (error ?? this.error),
    applied: clearApplied ? null : (applied ?? this.applied),
  );
}

class ReplaceController extends Notifier<ReplaceState> {
  @override
  ReplaceState build() => const ReplaceState();

  void update(ReplaceState Function(ReplaceState s) f) => state = f(state);

  /// Options changed: an old preview no longer describes what Apply would do.
  void invalidate(ReplaceState Function(ReplaceState s) f) =>
      state = f(state).copyWith(clearPreview: true, selected: const {}, expanded: const {});

  void toggleSelected(String rel) {
    final next = {...state.selected};
    if (!next.remove(rel)) next.add(rel);
    state = state.copyWith(selected: next);
  }

  void toggleExpanded(String rel) {
    final next = {...state.expanded};
    if (!next.remove(rel)) next.add(rel);
    state = state.copyWith(expanded: next);
  }

  void selectAll(bool all) => state = state.copyWith(
    selected: all ? {for (final f in state.preview?.files ?? const <FileChangePreview>[]) f.relative} : const {},
  );

  Future<void> preview(Workspace ws, String find, String replacement, String glob) async {
    final spec = FindSpec(
      pattern: find,
      isRegex: state.isRegex,
      caseSensitive: state.caseSensitive,
      wholeWord: state.wholeWord,
    );
    final invalid = spec.validate();
    if (invalid != null) {
      state = state.copyWith(error: FormatException(invalid), clearPreview: true);
      return;
    }
    if (glob.trim().isNotEmpty) {
      try {
        Glob(glob.trim());
      } on FormatException catch (e) {
        state = state.copyWith(error: e, clearPreview: true);
        return;
      }
    }
    final dir = state.workspaceId == ws.id ? state.dir : '';
    final options = ReplaceOptions(
      find: spec,
      replacement: replacement,
      includeGlob: glob,
      includeHidden: state.includeHidden,
    );
    state = state.copyWith(
      workspaceId: ws.id,
      dir: dir,
      clearError: true,
      clearPreview: true,
      clearApplied: true,
      selected: const {},
      expanded: const {},
    );
    try {
      final r = await ref
          .read(activityProvider.notifier)
          .run<ReplacePreview>(
            toolId: WsTools.replace,
            title: 'Preview replace "$find"',
            workspaceId: ws.id,
            cancellable: true,
            notify: false,
            body: (op) {
              state = state.copyWith(opId: op.id);
              return ReplaceService.preview(
                root: scopePath(ws, dir),
                options: options,
                token: op.token,
                onProgress: (scanned, changed) =>
                    op.progress(null, '${Fmt.count(scanned, 'file')} checked, $changed would change'),
              );
            },
            summary: (r) => '${r.totalReplacements} replacements in ${Fmt.count(r.files.length, 'file')}',
          );
      state = state.copyWith(
        preview: r,
        clearOp: true,
        selected: {for (final f in r.files) f.relative},
        expanded: {for (final f in r.files.take(3)) f.relative},
      );
    } catch (e) {
      state = state.copyWith(error: e, clearOp: true);
    }
  }

  Future<void> apply(Workspace ws) async {
    final preview = state.preview;
    if (preview == null) return;
    final files = [
      for (final f in preview.files)
        if (state.selected.contains(f.relative)) f,
    ];
    if (files.isEmpty) return;
    final started = DateTime.now();
    final writer = WorkspaceFileWriter(
      workspace: ws,
      metaDir: ref.read(workspacesProvider.notifier).metaDir(ws),
      clock: () => started,
    );
    state = state.copyWith(clearError: true);
    try {
      final r = await ref
          .read(activityProvider.notifier)
          .run<ReplaceApplyResult>(
            toolId: WsTools.replace,
            title: 'Replace in ${Fmt.count(files.length, 'file')}',
            workspaceId: ws.id,
            cancellable: true,
            body: (op) {
              state = state.copyWith(opId: op.id);
              return ReplaceService.apply(
                files: files,
                options: preview.options,
                writer: writer,
                token: op.token,
                onProgress: (d, t) => op.progress(t == 0 ? null : d / t, '$d / $t files'),
              );
            },
            summary: (r) =>
                '${r.replacements} replacements in ${Fmt.count(r.changed.length, 'file')}'
                '${r.skipped.isEmpty ? '' : ', ${r.skipped.length} skipped'}'
                '${r.failed.isEmpty ? '' : ', ${r.failed.length} failed'}',
            counts: (r) => {
              'files': r.changed.length,
              'replacements': r.replacements,
              'skipped': r.skipped.length,
              'failed': r.failed.length,
            },
          );
      state = state.copyWith(applied: r, clearOp: true, clearPreview: true, selected: const {}, expanded: const {});
    } catch (e) {
      state = state.copyWith(error: e, clearOp: true, clearPreview: true);
    }
  }
}

final replaceProvider = NotifierProvider<ReplaceController, ReplaceState>(ReplaceController.new);

class ReplacePage extends ConsumerWidget {
  const ReplacePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ws = ref.watch(activeWorkspaceProvider);
    if (ws == null) {
      return const ToolScaffold(
        toolId: WsTools.replace,
        children: [
          WorkspaceRequired(purpose: 'Replace in files changes files of the active workspace (with backups).'),
        ],
      );
    }
    final s = ref.watch(replaceProvider);
    final ctrl = ref.read(replaceProvider.notifier);
    final find = ref.watch(draftTextProvider('${WsTools.replace}/find'));
    final replacement = ref.watch(draftTextProvider('${WsTools.replace}/replacement'));
    final glob = ref.watch(draftTextProvider('${WsTools.replace}/glob'));
    if (s.workspaceId != null && s.workspaceId != ws.id && s.opId == null) {
      // A preview of another workspace must never be applied here.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => ctrl.invalidate((x) => x.copyWith(dir: '', workspaceId: ws.id, clearError: true, clearApplied: true)),
      );
    }
    final running = s.opId != null;

    Future<void> apply() async {
      final preview = s.preview;
      if (preview == null) return;
      final chosen = preview.files.where((f) => s.selected.contains(f.relative)).toList();
      final total = chosen.fold<int>(0, (a, f) => a + f.count);
      final ok = await showJ3Confirm(
        context,
        title: 'Replace in ${Fmt.count(chosen.length, 'file')}?',
        message:
            '$total replacement(s). Every file is backed up first to this workspace\'s backups folder '
            '(app storage). Encoding and line endings are kept.',
        confirmLabel: 'Replace',
        destructive: true,
        details: [for (final f in chosen) '${f.relative} (${f.count})'],
      );
      if (ok) await ctrl.apply(ws);
    }

    return ToolScaffold(
      toolId: WsTools.replace,
      inputs: [
        NeonPanel(
          kicker: 'Replace',
          title: 'Find and replace in files',
          icon: Icons.find_replace,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: find,
                style: J3Type.code,
                decoration: InputDecoration(labelText: s.isRegex ? 'Find (regular expression)' : 'Find'),
                onChanged: (_) => s.preview == null ? null : ctrl.invalidate((x) => x),
              ),
              const SizedBox(height: J3Space.sm),
              TextField(
                controller: replacement,
                style: J3Type.code,
                decoration: InputDecoration(
                  labelText: 'Replace with',
                  hintText: s.isRegex ? r'Groups: $1 ${name} $& ; \n newline' : 'Inserted literally',
                ),
                onChanged: (_) => s.preview == null ? null : ctrl.invalidate((x) => x),
              ),
              const SizedBox(height: J3Space.sm),
              TextField(
                controller: glob,
                style: J3Type.code,
                decoration: const InputDecoration(
                  labelText: 'Only files matching (glob, optional)',
                  hintText: '*.json',
                ),
                onChanged: (_) => s.preview == null ? null : ctrl.invalidate((x) => x),
              ),
              WsSwitch(
                label: 'Regular expression',
                description: 'Checked first; evaluated in workers with a time limit',
                value: s.isRegex,
                onChanged: (v) => ctrl.invalidate((x) => x.copyWith(isRegex: v)),
              ),
              WsSwitch(
                label: 'Match case',
                value: s.caseSensitive,
                onChanged: (v) => ctrl.invalidate((x) => x.copyWith(caseSensitive: v)),
              ),
              WsSwitch(
                label: 'Whole word',
                value: s.wholeWord,
                onChanged: (v) => ctrl.invalidate((x) => x.copyWith(wholeWord: v)),
              ),
              WsSwitch(
                label: 'Include hidden files',
                value: s.includeHidden,
                onChanged: (v) => ctrl.invalidate((x) => x.copyWith(includeHidden: v)),
              ),
              const SizedBox(height: J3Space.sm),
              ScopeFolderRow(
                workspace: ws,
                relDir: s.workspaceId == ws.id ? s.dir : '',
                label: 'In folder',
                onChanged: (d) => ctrl.invalidate((x) => x.copyWith(dir: d, workspaceId: ws.id)),
              ),
              const SizedBox(height: J3Space.lg),
              ButtonWrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                children: [
                  NeonButton(
                    label: 'Preview changes',
                    icon: Icons.preview_outlined,
                    busy: running,
                    onPressed: running ? null : () => ctrl.preview(ws, find.text, replacement.text, glob.text),
                  ),
                  if (running)
                    NeonButton.secondary(
                      label: 'Cancel',
                      icon: Icons.stop_circle_outlined,
                      onPressed: () => ref.read(activityProvider.notifier).cancel(s.opId!),
                    ),
                ],
              ),
              const SizedBox(height: J3Space.sm),
              Text(
                'Nothing is written until you apply a preview. Binary files and files over 10 MiB are skipped.',
                style: J3Type.caption,
              ),
            ],
          ),
        ),
      ],
      results: [
        if (s.error != null) WsErrorBanner(error: s.error!, action: 'Replace'),
        if (running) OperationProgress(operationId: s.opId!, label: 'Working'),
        if (s.applied != null) _AppliedSummary(result: s.applied!, workspace: ws),
        if (s.preview == null && s.applied == null && s.error == null && !running)
          const NeonPanel(
            emphasis: PanelEmphasis.subtle,
            child: EmptyState(
              glyph: '[ s/a/b/ ]',
              title: 'No preview yet',
              message: 'Preview shows every change first.',
            ),
          ),
        if (s.preview != null) _PreviewList(state: s, onApply: apply),
      ],
    );
  }
}

class _PreviewList extends ConsumerWidget {
  const _PreviewList({required this.state, required this.onApply});
  final ReplaceState state;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = state.preview!;
    final ctrl = ref.read(replaceProvider.notifier);
    final chosen = r.files.where((f) => state.selected.contains(f.relative)).toList();
    final replacements = chosen.fold<int>(0, (a, f) => a + f.count);
    return NeonPanel(
      kicker: 'Preview',
      title: '${Fmt.count(r.totalReplacements, 'replacement')} in ${Fmt.count(r.files.length, 'file')}',
      icon: Icons.difference_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ButtonWrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.xs,
            children: [
              CountChip(label: 'Checked', value: '${r.filesScanned}'),
              CountChip(label: 'Binary skipped', value: '${r.skippedBinary}'),
              CountChip(label: 'Over 10 MiB', value: '${r.skippedLarge}'),
              CountChip(
                label: 'Not rewritable',
                value: '${r.skippedUnsafe.length}',
                kind: r.skippedUnsafe.isEmpty ? StatusKind.neutral : StatusKind.warning,
              ),
            ],
          ),
          if (r.skippedUnsafe.isNotEmpty || r.unreadable.isNotEmpty) ...[
            const SizedBox(height: J3Space.sm),
            WsBanner(
              kind: StatusKind.warning,
              title: 'Skipped files',
              message: 'These match but cannot be rewritten without changing other bytes, or could not be read.',
              details: [...r.skippedUnsafe, ...r.unreadable],
            ),
          ],
          const SizedBox(height: J3Space.sm),
          if (r.files.isEmpty)
            const EmptyState(glyph: '[ 0 ]', title: 'No matches', message: 'Nothing would change.')
          else ...[
            ButtonWrap(
              spacing: J3Space.sm,
              runSpacing: J3Space.xs,
              children: [
                NeonButton.ghost(label: 'Select all', onPressed: () => ctrl.selectAll(true)),
                NeonButton.ghost(label: 'Select none', onPressed: () => ctrl.selectAll(false)),
              ],
            ),
            BoundedList(
              fraction: 0.55,
              itemCount: r.files.length,
              itemBuilder: (context, i) => _FileChange(
                change: r.files[i],
                selected: state.selected.contains(r.files[i].relative),
                expanded: state.expanded.contains(r.files[i].relative),
              ),
            ),
            const SizedBox(height: J3Space.md),
            Align(
              alignment: Alignment.centerLeft,
              child: FitButton(
                NeonButton(
                  label: 'Apply to ${Fmt.count(chosen.length, 'file')} ($replacements)',
                  icon: Icons.done_all,
                  onPressed: chosen.isEmpty || state.opId != null ? null : onApply,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FileChange extends ConsumerWidget {
  const _FileChange({required this.change, required this.selected, required this.expanded});
  final FileChangePreview change;
  final bool selected;
  final bool expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = change;
    final ctrl = ref.read(replaceProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Checkbox(
              value: selected,
              onChanged: (_) => ctrl.toggleSelected(c.relative),
              semanticLabel: 'Include ${c.relative}',
            ),
            Expanded(
              child: InkWell(
                onTap: () => ctrl.toggleExpanded(c.relative),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      PathText(c.relative),
                      Text(
                        '${c.count} replacement(s)  |  ${c.encodingLabel}  |  ${c.lineEnding}',
                        style: J3Type.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            NeonIconButton(
              icon: expanded ? Icons.expand_less : Icons.expand_more,
              tooltip: expanded ? 'Hide diff' : 'Show diff',
              onPressed: () => ctrl.toggleExpanded(c.relative),
            ),
          ],
        ),
        if (expanded)
          Container(
            margin: const EdgeInsets.only(left: J3Space.xl, bottom: J3Space.sm),
            padding: const EdgeInsets.all(J3Space.sm),
            decoration: BoxDecoration(
              color: J3Colors.inputFill,
              borderRadius: J3Radius.small,
              border: Border.all(color: J3Colors.border),
            ),
            child: _DiffText(diff: c.diff, truncated: c.diffTruncated),
          ),
      ],
    );
  }
}

/// Unified diff with +/- prefixes (colour is only a secondary cue).
class _DiffText extends StatelessWidget {
  const _DiffText({required this.diff, required this.truncated});
  final String diff;
  final bool truncated;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final lines = diff.split('\n').where((l) => !l.startsWith('---') && !l.startsWith('+++') && l.isNotEmpty);
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final l in lines)
            Text(
              l,
              style: J3Type.codeSmall.copyWith(
                color: l.startsWith('+')
                    ? J3Colors.success
                    : l.startsWith('-')
                    ? J3Colors.error
                    : l.startsWith('@@')
                    ? fx.accentText
                    : J3Colors.textSecondary,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          if (truncated) Text('... diff shortened', style: J3Type.caption),
        ],
      ),
    );
  }
}

class _AppliedSummary extends ConsumerWidget {
  const _AppliedSummary({required this.result, required this.workspace});
  final ReplaceApplyResult result;
  final Workspace workspace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = result;
    final ok = r.failed.isEmpty && r.skipped.isEmpty;
    return WsBanner(
      kind: ok ? StatusKind.success : StatusKind.warning,
      title: '${Fmt.count(r.replacements, 'replacement')} in ${Fmt.count(r.changed.length, 'file')}',
      message: r.backupDir == null
          ? null
          : 'Originals were backed up to ${p.basename(r.backupDir!)} in this workspace\'s backups (app storage).',
      details: [
        ...r.changed.map((c) => 'changed $c'),
        ...r.skipped.map((c) => 'skipped $c'),
        ...r.failed.map((c) => 'failed $c'),
      ],
      onDismiss: () => ref.read(replaceProvider.notifier).update((x) => x.copyWith(clearApplied: true)),
      actions: [
        if (r.backupDir != null)
          NeonButton.secondary(
            label: 'Copy backup path',
            icon: Icons.copy_rounded,
            onPressed: () async {
              await ref.read(fileAccessProvider).copyText(r.backupDir!);
              ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Backup path copied');
            },
          ),
      ],
    );
  }
}
