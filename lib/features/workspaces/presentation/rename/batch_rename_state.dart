import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/tasks/isolate_runner.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/workspace/workspace.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../data/rename_executor.dart';
import '../../domain/fs_errors.dart';
import '../../domain/rename_plan.dart';
import '../shared/requests.dart';
import '../shared/scope_folder.dart';

/// Draft keys of the rule text fields.
abstract final class RenameFields {
  static const find = '${WsTools.batchRename}/find';
  static const replace = '${WsTools.batchRename}/replace';
  static const prefix = '${WsTools.batchRename}/prefix';
  static const suffix = '${WsTools.batchRename}/suffix';
  static const template = '${WsTools.batchRename}/template';
  static const start = '${WsTools.batchRename}/start';
  static const step = '${WsTools.batchRename}/step';
  static const newExt = '${WsTools.batchRename}/ext';
  static const filter = '${WsTools.batchRename}/filter';

  static const all = [find, replace, prefix, suffix, template, start, step, newExt];
}

class BatchRenameState {
  const BatchRenameState({
    this.workspaceId,
    this.dir = '',
    this.recursive = false,
    this.includeHidden = false,
    this.useRegex = false,
    this.caseSensitive = true,
    this.includeExtension = false,
    this.caseTransform = RenameCase.keep,
    this.extensionMode = ExtensionMode.keep,
    this.onlyChanges = false,
    this.scan,
    this.scanning = false,
    this.plan,
    this.planError,
    this.error,
    this.opId,
    this.lastMessage,
    this.journals,
  });

  final String? workspaceId;
  final String dir;
  final bool recursive;
  final bool includeHidden;
  final bool useRegex;
  final bool caseSensitive;
  final bool includeExtension;
  final RenameCase caseTransform;
  final ExtensionMode extensionMode;
  final bool onlyChanges;
  final RenameScan? scan;
  final bool scanning;
  final RenamePlan? plan;

  /// Evaluation problem of the rules (e.g. regex timed out).
  final Object? planError;
  final Object? error;
  final String? opId;
  final String? lastMessage;
  final List<RenameJournal>? journals;

  BatchRenameState copyWith({
    String? workspaceId,
    String? dir,
    bool? recursive,
    bool? includeHidden,
    bool? useRegex,
    bool? caseSensitive,
    bool? includeExtension,
    RenameCase? caseTransform,
    ExtensionMode? extensionMode,
    bool? onlyChanges,
    RenameScan? scan,
    bool clearScan = false,
    bool? scanning,
    RenamePlan? plan,
    bool clearPlan = false,
    Object? planError,
    bool clearPlanError = false,
    Object? error,
    bool clearError = false,
    String? opId,
    bool clearOp = false,
    String? lastMessage,
    bool clearMessage = false,
    List<RenameJournal>? journals,
  }) => BatchRenameState(
    workspaceId: workspaceId ?? this.workspaceId,
    dir: dir ?? this.dir,
    recursive: recursive ?? this.recursive,
    includeHidden: includeHidden ?? this.includeHidden,
    useRegex: useRegex ?? this.useRegex,
    caseSensitive: caseSensitive ?? this.caseSensitive,
    includeExtension: includeExtension ?? this.includeExtension,
    caseTransform: caseTransform ?? this.caseTransform,
    extensionMode: extensionMode ?? this.extensionMode,
    onlyChanges: onlyChanges ?? this.onlyChanges,
    scan: clearScan ? null : (scan ?? this.scan),
    scanning: scanning ?? this.scanning,
    plan: clearPlan ? null : (plan ?? this.plan),
    planError: clearPlanError ? null : (planError ?? this.planError),
    error: clearError ? null : (error ?? this.error),
    opId: clearOp ? null : (opId ?? this.opId),
    lastMessage: clearMessage ? null : (lastMessage ?? this.lastMessage),
    journals: journals ?? this.journals,
  );
}

/// Worker closure that captures only the plan inputs (never the notifier).
RenamePlan Function() _planTask(List<RenameItem> items, RenameRules rules, Map<String, List<String>> existing) =>
    () => planRenames(items: items, rules: rules, existing: existing);

class BatchRenameController extends Notifier<BatchRenameState> {
  int _planSeq = 0;

  @override
  BatchRenameState build() => const BatchRenameState();

  void update(BatchRenameState Function(BatchRenameState s) f) => state = f(state);

  String _text(String key) => ref.read(draftTextProvider(key)).text;

  RenameRules rules() => RenameRules(
    find: _text(RenameFields.find),
    replace: _text(RenameFields.replace),
    useRegex: state.useRegex,
    caseSensitive: state.caseSensitive,
    includeExtension: state.includeExtension,
    prefix: _text(RenameFields.prefix),
    suffix: _text(RenameFields.suffix),
    template: _text(RenameFields.template),
    startNumber: int.tryParse(_text(RenameFields.start).trim()) ?? 1,
    step: int.tryParse(_text(RenameFields.step).trim()) ?? 1,
    caseTransform: state.caseTransform,
    extensionMode: state.extensionMode,
    newExtension: _text(RenameFields.newExt),
  );

  RenameExecutor executor(Workspace ws) =>
      RenameExecutor(root: ws.rootPath, metaDir: ref.read(workspacesProvider.notifier).metaDir(ws));

  /// Lists the files to rename (and all names in their folders).
  Future<void> rescan(Workspace ws) async {
    final dir = state.workspaceId == ws.id ? state.dir : '';
    state = state.copyWith(workspaceId: ws.id, dir: dir, scanning: true, clearError: true);
    try {
      final scan = await RenameScanner.scan(
        root: ws.rootPath,
        folder: scopePath(ws, dir),
        recursive: state.recursive,
        filter: _text(RenameFields.filter),
        includeHidden: state.includeHidden,
      );
      state = state.copyWith(scan: scan, scanning: false);
      await replan();
    } catch (e) {
      state = state.copyWith(scanning: false, error: e, clearScan: true, clearPlan: true);
    }
    await loadJournals(ws);
  }

  /// Recomputes the preview. Regex rules run in a bounded worker so a
  /// pathological pattern cannot freeze the UI.
  Future<void> replan() async {
    final scan = state.scan;
    if (scan == null) return;
    final seq = ++_planSeq;
    final r = rules();
    try {
      final RenamePlan plan;
      if (r.needsBoundedEvaluation) {
        final items = scan.items;
        final existing = scan.existing;
        plan = await runBounded(_planTask(items, r, existing), timeout: const Duration(seconds: 3));
      } else {
        plan = planRenames(items: scan.items, rules: r, existing: scan.existing);
      }
      if (seq == _planSeq) state = state.copyWith(plan: plan, clearPlanError: true);
    } on OperationTimedOut {
      if (seq == _planSeq) {
        state = state.copyWith(
          clearPlan: true,
          planError: PatternTimeoutException(const Duration(seconds: 3), [for (final i in scan.items.take(1)) i.name]),
        );
      }
    } catch (e) {
      if (seq == _planSeq) state = state.copyWith(clearPlan: true, planError: e);
    }
  }

  Future<void> loadJournals(Workspace ws) async {
    try {
      final list = await executor(ws).journals();
      state = state.copyWith(journals: list);
    } catch (_) {
      state = state.copyWith(journals: const []);
    }
  }

  Future<void> apply(Workspace ws) async {
    final plan = state.plan;
    if (plan == null || !plan.canApply) return;
    final changes = plan.changes.length;
    state = state.copyWith(clearError: true, clearMessage: true);
    try {
      final r = await ref
          .read(activityProvider.notifier)
          .run<RenameResult>(
            toolId: WsTools.batchRename,
            title: 'Batch rename ${Fmt.count(changes, 'file')}',
            workspaceId: ws.id,
            cancellable: true,
            body: (op) {
              state = state.copyWith(opId: op.id);
              return executor(ws).apply(
                plan.rows,
                token: op.token,
                onProgress: (d, t) => op.progress(t == 0 ? null : d / t, '$d / $t steps'),
              );
            },
            summary: (r) => '${Fmt.count(r.renamed, 'file')} renamed; undo is available',
            counts: (r) => {'renamed': r.renamed},
          );
      state = state.copyWith(
        clearOp: true,
        lastMessage: 'Renamed ${Fmt.count(r.renamed, 'file')}. Journal: ${r.journal.id}',
      );
    } catch (e) {
      state = state.copyWith(clearOp: true, error: e);
    }
    await rescan(ws);
  }

  Future<void> undo(Workspace ws, RenameJournal journal) async {
    state = state.copyWith(clearError: true, clearMessage: true);
    try {
      final r = await ref
          .read(activityProvider.notifier)
          .run<RenameResult>(
            toolId: WsTools.batchRename,
            title: 'Undo batch rename ${journal.id}',
            workspaceId: ws.id,
            body: (op) => executor(ws).undo(journal, token: op.token),
            summary: (r) =>
                '${Fmt.count(r.renamed, 'file')} restored${r.skipped.isEmpty ? '' : ', ${r.skipped.length} skipped'}',
            counts: (r) => {'restored': r.renamed, 'skipped': r.skipped.length},
          );
      state = state.copyWith(
        lastMessage:
            'Restored ${Fmt.count(r.renamed, 'file')}'
            '${r.skipped.isEmpty ? '' : '. Skipped: ${r.skipped.join('; ')}'}',
      );
    } catch (e) {
      state = state.copyWith(error: e);
    }
    await rescan(ws);
  }
}

final batchRenameProvider = NotifierProvider<BatchRenameController, BatchRenameState>(BatchRenameController.new);
