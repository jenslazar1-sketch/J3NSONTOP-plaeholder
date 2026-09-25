import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/activity/activity_controller.dart';
import '../../../core/drafts/drafts.dart';
import '../../../core/tasks/cancellation.dart';
import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../core/workspace/file_backup.dart';
import '../../../core/workspace/workspace_controller.dart';
import '../domain/glob.dart';
import '../domain/text_files.dart';
import 'shared.dart';

/// Where a batch takes its files from.
enum BatchSource {
  files('Chosen files'),
  folder('Folder + filter');

  const BatchSource(this.label);
  final String label;
}

class TextBatchState<S> {
  const TextBatchState({
    this.files = const [],
    this.folder,
    this.results,
    this.applied = false,
    this.opId,
    this.error,
    this.notice,
  });

  final List<FileItem> files;

  /// Absolute folder for [BatchSource.folder]; null = workspace root.
  final String? folder;
  final List<TextFileResult<S>>? results;

  /// Whether [results] come from an apply (files were written).
  final bool applied;
  final String? opId;
  final String? error;
  final String? notice;

  bool get running => opId != null;

  TextBatchState<S> copyWith({
    List<FileItem>? files,
    String? folder,
    List<TextFileResult<S>>? results,
    bool clearResults = false,
    bool? applied,
    String? opId,
    bool clearOp = false,
    String? error,
    bool clearError = false,
    String? notice,
    bool clearNotice = false,
  }) => TextBatchState<S>(
    files: files ?? this.files,
    folder: folder ?? this.folder,
    results: clearResults ? null : (results ?? this.results),
    applied: clearResults ? false : (applied ?? this.applied),
    opId: clearOp ? null : (opId ?? this.opId),
    error: clearError ? null : (error ?? this.error),
    notice: clearNotice ? null : (notice ?? this.notice),
  );
}

/// Dry-run / apply controller shared by the line-ending and whitespace
/// tools. Only workspace files are rewritten, always with a backup.
class TextBatchController<S> extends Notifier<TextBatchState<S>> {
  TextBatchController(this.toolId, this.verb);

  final String toolId;

  /// "Convert", "Clean"...
  final String verb;

  @override
  TextBatchState<S> build() {
    ref.watch(activeWorkspaceProvider.select((w) => w?.id));
    return TextBatchState<S>();
  }

  void addFiles(Iterable<FileItem> items) =>
      state = state.copyWith(files: mergeFileItems(state.files, items), clearResults: true, clearNotice: true);

  void removeFile(FileItem f) =>
      state = state.copyWith(files: state.files.where((x) => x != f).toList(), clearResults: true);

  void clearFiles() => state = state.copyWith(files: const [], clearResults: true);

  void setFolder(String folder) => state = state.copyWith(folder: folder, clearResults: true);

  void invalidateResults() {
    if (state.results != null && !state.running) state = state.copyWith(clearResults: true, clearNotice: true);
  }

  Future<List<TextFileTarget>> _targets(
    BatchSource source,
    String include,
    String exclude,
    CancellationToken token,
  ) async {
    if (source == BatchSource.files) {
      return [for (final f in state.files) TextFileTarget(path: f.path, label: f.label, inWorkspace: f.inWorkspace)];
    }
    final ws = ref.read(activeWorkspaceProvider);
    if (ws == null) throw StateError('Open a workspace to process a folder');
    final filter = GlobFilter.parse(include: include, exclude: exclude);
    final (items, walk) = await filesInFolder(
      ws,
      state.folder ?? ws.rootPath,
      filter: filter,
      maxFiles: kMaxBatchFiles,
      token: token,
    );
    if (walk.truncated && ref.mounted) {
      state = state.copyWith(notice: 'Only the first $kMaxBatchFiles matching files are processed per run.');
    }
    return [for (final f in items) TextFileTarget(path: f.path, label: f.label, inWorkspace: true)];
  }

  /// Analyses ([apply] false) or rewrites ([apply] true) the files.
  Future<void> run({
    required bool apply,
    required BatchSource source,
    required TextTransform<S> transform,
    String include = '',
    String exclude = '',
  }) async {
    if (state.running) return;
    final ws = ref.read(activeWorkspaceProvider);
    WorkspaceFileWriter? writer;
    if (apply) {
      if (ws == null) {
        state = state.copyWith(error: 'Open a workspace to change files in place.');
        return;
      }
      writer = WorkspaceFileWriter(workspace: ws, metaDir: ref.read(workspacesProvider.notifier).metaDir(ws));
    }
    state = state.copyWith(clearResults: true, clearError: true, clearNotice: true);
    try {
      final results = await ref
          .read(activityProvider.notifier)
          .run<List<TextFileResult<S>>>(
            toolId: toolId,
            title: apply ? '$verb files' : 'Analyse files ($verb)',
            cancellable: true,
            workspaceId: ws?.id,
            body: (op) async {
              state = state.copyWith(opId: op.id);
              op.progress(null, 'Collecting files...');
              final targets = await _targets(source, include, exclude, op.token);
              if (targets.isEmpty) throw const FormatException('No files to process (check the folder and filter)');
              final throttle = ProgressThrottle(op);
              final r = await processTextFiles<S>(
                targets,
                transform,
                apply: apply,
                writer: writer,
                token: op.token,
                onProgress: (done, total, cur) =>
                    throttle.report(total == 0 ? null : done / total, cur.isEmpty ? null : cur),
              );
              final counts = countStatuses(r);
              final changed = counts[TextFileStatus.changed] ?? 0;
              final willChange = counts[TextFileStatus.willChange] ?? 0;
              final skipped = r.where((x) => x.status.isSkip).length;
              final summary = apply
                  ? 'Changed $changed of ${r.length} files${skipped > 0 ? ', $skipped skipped' : ''}'
                  : '$willChange of ${r.length} files would change${skipped > 0 ? ', $skipped skipped' : ''}';
              final c = {'files': r.length, 'changed': apply ? changed : willChange, 'skipped': skipped};
              if (skipped > 0) {
                op.warn(
                  summary,
                  counts: c,
                  details: [
                    for (final x in r.where((x) => x.status.isSkip)) '${x.target.label}: ${x.detail ?? x.status.label}',
                  ],
                );
              } else {
                op.succeed(summary, counts: c);
              }
              return r;
            },
          );
      if (!ref.mounted) return;
      final backups = results.map((r) => r.backupPath).whereType<String>().toList();
      state = state.copyWith(
        results: results,
        applied: apply,
        clearOp: true,
        notice: apply && backups.isNotEmpty
            ? 'Originals were backed up to ${_backupFolderLabel(backups.first)} (workspace metadata).'
            : state.notice,
      );
    } on OperationCancelled {
      if (ref.mounted) {
        state = state.copyWith(
          clearOp: true,
          notice: apply ? 'Cancelled. Files already written keep their backups.' : 'Analysis cancelled.',
        );
      }
    } catch (e) {
      if (ref.mounted) state = state.copyWith(clearOp: true, error: describeError(e));
    }
  }

  static String _backupFolderLabel(String backupPath) {
    final parts = p.split(backupPath);
    final i = parts.lastIndexOf('backups');
    return i >= 0 && i + 1 < parts.length ? 'backups/${parts[i + 1]}' : p.dirname(backupPath);
  }

  /// Transformed bytes of one (device) file for export.
  Future<List<int>?> exportBytes(FileItem f, TextTransform<S> transform) async {
    final (r, bytes) = await transformTextFile<S>(
      TextFileTarget(path: f.path, label: f.label, inWorkspace: f.inWorkspace),
      transform,
    );
    if (r.status.isSkip) throw FormatException('${f.label}: ${r.detail ?? r.status.label}');
    return bytes;
  }
}

/// Source picker (files or folder + globs) for a batch.
class BatchSourcePanel<S> extends ConsumerWidget {
  const BatchSourcePanel({super.key, required this.toolId, required this.provider});

  final String toolId;
  final NotifierProvider<TextBatchController<S>, TextBatchState<S>> provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(provider);
    final ctl = ref.read(provider.notifier);
    final ws = ref.watch(activeWorkspaceProvider);
    final source = ref.draft<BatchSource>('$toolId/batchSource', BatchSource.files);
    final include = ref.watch(draftTextProvider('$toolId/include'));
    final exclude = ref.watch(draftTextProvider('$toolId/exclude'));

    return NeonPanel(
      kicker: 'Files',
      title: 'What to process',
      icon: Icons.folder_copy_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChoiceRow<BatchSource>(
            label: 'Source',
            options: BatchSource.values,
            selected: source,
            labelOf: (s) => s.label,
            onSelected: (s) {
              ref.setDraft('$toolId/batchSource', s);
              ctl.invalidateResults();
            },
          ),
          const SizedBox(height: J3Space.md),
          if (source == BatchSource.files) ...[
            ButtonWrap(
              spacing: J3Space.sm,
              runSpacing: J3Space.sm,
              children: [
                NeonButton.secondary(
                  label: 'Workspace file',
                  icon: Icons.insert_drive_file_outlined,
                  tooltip: ws == null ? 'Open a workspace to browse its files' : 'Add a file from the workspace',
                  onPressed: ws == null || st.running
                      ? null
                      : () async {
                          final f = await pickWorkspaceFile(context, ref);
                          if (f != null) ctl.addFiles([f]);
                        },
                ),
                NeonButton.secondary(
                  label: 'From device',
                  icon: Icons.upload_file_outlined,
                  tooltip: 'Import copies; results are exported instead of written in place',
                  onPressed: st.running ? null : () async => ctl.addFiles(await pickDeviceFiles(ref, toolKey: toolId)),
                ),
                if (st.files.isNotEmpty)
                  NeonButton.ghost(
                    label: 'Clear',
                    icon: Icons.clear_all,
                    onPressed: st.running ? null : ctl.clearFiles,
                  ),
              ],
            ),
            const SizedBox(height: J3Space.sm),
            if (st.files.isEmpty)
              Text('No files chosen.', style: J3Type.bodySecondary)
            else
              FileItemList(items: st.files, onRemove: st.running ? null : ctl.removeFile),
          ] else ...[
            if (ws == null)
              const NoWorkspaceNotice(what: 'Folder batches')
            else ...[
              ButtonWrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(() {
                    final rel = workspaceLabel(ws, st.folder ?? ws.rootPath);
                    return rel == '.' ? '${ws.name} (workspace root)' : rel;
                  }(), style: J3Type.code),
                  NeonButton.ghost(
                    label: 'Change folder',
                    icon: Icons.folder_open,
                    dense: true,
                    onPressed: st.running
                        ? null
                        : () async {
                            final f = await pickWorkspaceFolder(context, ref);
                            if (f != null) ctl.setFolder(f);
                          },
                  ),
                ],
              ),
              const SizedBox(height: J3Space.sm),
              GlobFields(include: include, exclude: exclude),
              const SizedBox(height: J3Space.xs),
              InfoLine(
                'Recursive, symbolic links skipped, at most $kMaxBatchFiles files per run. Binary files and files '
                'over ${kMaxTextFileBytes ~/ (1024 * 1024)} MiB are skipped and listed.',
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Analyse/apply buttons plus the per-file report.
class BatchResultsPanel<S> extends ConsumerWidget {
  const BatchResultsPanel({
    super.key,
    required this.toolId,
    required this.provider,
    required this.transform,
    required this.describeStats,
    required this.applyLabel,
    required this.exportSuffix,
  });

  final String toolId;
  final NotifierProvider<TextBatchController<S>, TextBatchState<S>> provider;
  final TextTransform<S> Function() transform;
  final String Function(S stats) describeStats;

  /// e.g. "Convert files".
  final String applyLabel;

  /// Suffix for exported device files, e.g. "-lf".
  final String exportSuffix;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(provider);
    final ctl = ref.read(provider.notifier);
    final source = ref.draft<BatchSource>('$toolId/batchSource', BatchSource.files);
    final include = ref.watch(draftTextProvider('$toolId/include'));
    final exclude = ref.watch(draftTextProvider('$toolId/exclude'));
    final ws = ref.watch(activeWorkspaceProvider);
    final hasInput = source == BatchSource.folder ? ws != null : st.files.isNotEmpty;
    final results = st.results;
    final changes = results?.where((r) => r.status == TextFileStatus.willChange).length ?? 0;

    Future<void> runApply() async {
      final ok = await showJ3Confirm(
        context,
        title: 'Rewrite files in place?',
        message:
            'Workspace files that change are replaced atomically after a backup copy is written to the '
            'workspace backups folder. Device imports are never written; export them instead.',
        confirmLabel: applyLabel,
        details: results == null
            ? const []
            : [
                for (final r in results.where((r) => r.status == TextFileStatus.willChange && r.target.inWorkspace))
                  r.target.label,
              ],
      );
      if (!ok) return;
      await ctl.run(apply: true, source: source, transform: transform(), include: include.text, exclude: exclude.text);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeonPanel(
          kicker: 'Run',
          title: 'Dry run first',
          icon: Icons.play_circle_outline,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ButtonWrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                children: [
                  NeonButton.secondary(
                    key: Key('$toolId.analyse'),
                    label: 'Analyse',
                    icon: Icons.search,
                    busy: st.running,
                    tooltip: 'Show what would change without writing anything',
                    onPressed: !hasInput
                        ? null
                        : () => ctl.run(
                            apply: false,
                            source: source,
                            transform: transform(),
                            include: include.text,
                            exclude: exclude.text,
                          ),
                  ),
                  NeonButton(
                    key: Key('$toolId.apply'),
                    label: applyLabel,
                    icon: Icons.auto_fix_high,
                    busy: st.running,
                    tooltip: 'Rewrite changed workspace files (backups first)',
                    onPressed: !hasInput || results == null || st.applied || changes == 0 ? null : runApply,
                  ),
                ],
              ),
              const SizedBox(height: J3Space.xs),
              Text(
                results == null
                    ? 'Analyse to preview per-file changes; applying is enabled afterwards.'
                    : (st.applied ? 'Applied. Analyse again to re-check.' : '$changes file(s) would change.'),
                style: J3Type.caption,
              ),
            ],
          ),
        ),
        const SizedBox(height: J3Space.md),
        OperationProgressPanel(operationId: st.opId, label: 'Processing files...'),
        if (st.error != null) ErrorPanel(title: 'Batch failed', error: st.error!),
        if (st.notice != null) ...[const SizedBox(height: J3Space.sm), InfoLine(st.notice!)],
        if (results != null) ...[
          const SizedBox(height: J3Space.md),
          _BatchReport<S>(
            results: results,
            applied: st.applied,
            describeStats: describeStats,
            onExport: (r) async {
              try {
                final item = FileItem(path: r.target.path, label: r.target.label, inWorkspace: false, size: r.size);
                final bytes = await ctl.exportBytes(item, transform());
                if (bytes == null || !context.mounted) return;
                final name = p.basenameWithoutExtension(r.target.label) + exportSuffix + p.extension(r.target.label);
                await saveOutput(
                  context,
                  ref,
                  suggestedName: name,
                  bytes: Uint8List.fromList(bytes),
                  mimeType: 'text/plain',
                  toolId: toolId,
                );
              } catch (e) {
                ref.read(activityProvider.notifier).notify(NoticeKind.error, 'Export failed: ${describeError(e)}');
              }
            },
          ),
        ],
      ],
    );
  }
}

class _BatchReport<S> extends StatelessWidget {
  const _BatchReport({
    required this.results,
    required this.applied,
    required this.describeStats,
    required this.onExport,
  });

  final List<TextFileResult<S>> results;
  final bool applied;
  final String Function(S stats) describeStats;
  final void Function(TextFileResult<S> r) onExport;

  @override
  Widget build(BuildContext context) {
    final counts = countStatuses(results);
    return NeonPanel(
      kicker: applied ? 'Applied' : 'Dry run',
      title: '${Fmt.count(results.length, 'file')} checked',
      icon: Icons.fact_check_outlined,
      emphasis: applied ? PanelEmphasis.success : PanelEmphasis.normal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              for (final e in counts.entries)
                StatTile(
                  label: e.key.label,
                  value: '${e.value}',
                  icon: _statusIcon(e.key),
                  color: _statusKind(e.key).color,
                ),
            ],
          ),
          const SizedBox(height: J3Space.md),
          BoundedList(
            itemCount: results.length,
            itemBuilder: (context, i) {
              final r = results[i];
              final canExport =
                  !r.target.inWorkspace &&
                  (r.status == TextFileStatus.willChange || r.status == TextFileStatus.exportOnly);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StatusBadge(dense: true, kind: _statusKind(r.status), text: r.status.label),
                    const SizedBox(width: J3Space.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.target.label,
                            style: J3Type.codeSmall.copyWith(color: J3Colors.text),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            [
                              ?r.encodingLabel,
                              if (r.stats != null) describeStats(r.stats as S),
                              ?r.detail,
                              if (r.backupPath != null) 'backup kept',
                            ].join(' · '),
                            style: J3Type.caption,
                          ),
                        ],
                      ),
                    ),
                    if (canExport)
                      IconButton(
                        tooltip: 'Export converted copy of ${r.target.label}',
                        onPressed: () => onExport(r),
                        icon: const Icon(Icons.save_alt_rounded, size: 18),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

StatusKind _statusKind(TextFileStatus s) => switch (s) {
  TextFileStatus.willChange => StatusKind.info,
  TextFileStatus.changed => StatusKind.success,
  TextFileStatus.unchanged => StatusKind.neutral,
  TextFileStatus.exportOnly => StatusKind.info,
  TextFileStatus.unreadable => StatusKind.error,
  _ => StatusKind.warning,
};

IconData _statusIcon(TextFileStatus s) => switch (s) {
  TextFileStatus.willChange => Icons.edit_note,
  TextFileStatus.changed => Icons.check_circle_outline,
  TextFileStatus.unchanged => Icons.remove_circle_outline,
  TextFileStatus.exportOnly => Icons.phone_android_outlined,
  TextFileStatus.unreadable => Icons.error_outline,
  TextFileStatus.binary => Icons.memory,
  TextFileStatus.tooLarge => Icons.straighten,
  TextFileStatus.encodingUnsafe => Icons.translate,
};
