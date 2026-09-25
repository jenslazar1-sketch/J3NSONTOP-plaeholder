import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/drafts/drafts.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/workspace.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../data/rename_executor.dart';
import '../../domain/rename_plan.dart';
import '../shared/requests.dart';
import '../shared/scope_folder.dart';
import '../shared/ws_widgets.dart';
import 'batch_rename_state.dart';

class BatchRenamePage extends ConsumerStatefulWidget {
  const BatchRenamePage({super.key});

  @override
  ConsumerState<BatchRenamePage> createState() => _BatchRenamePageState();
}

class _BatchRenamePageState extends ConsumerState<BatchRenamePage> {
  Timer? _debounce;
  Timer? _scanDebounce;
  final List<TextEditingController> _listening = [];
  TextEditingController? _filter;

  late final BatchRenameController _ctrl = ref.read(batchRenameProvider.notifier);

  @override
  void initState() {
    super.initState();
    final start = ref.read(draftTextProvider(RenameFields.start));
    if (start.text.isEmpty) start.text = '1';
    final step = ref.read(draftTextProvider(RenameFields.step));
    if (step.text.isEmpty) step.text = '1';
    for (final key in RenameFields.all) {
      final c = ref.read(draftTextProvider(key));
      c.addListener(_onRuleChanged);
      _listening.add(c);
    }
    final filter = ref.read(draftTextProvider(RenameFields.filter))..addListener(_onFilterChanged);
    _filter = filter;
    _lastFilter = filter.text;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scanDebounce?.cancel();
    for (final c in _listening) {
      c.removeListener(_onRuleChanged);
    }
    _filter?.removeListener(_onFilterChanged);
    super.dispose();
  }

  String _lastRuleSnapshot = '';

  void _onRuleChanged() {
    final snap = RenameFields.all.map((k) => ref.read(draftTextProvider(k)).text).join('\u0000');
    if (snap == _lastRuleSnapshot) return;
    _lastRuleSnapshot = snap;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) _ctrl.replan();
    });
  }

  String _lastFilter = '';

  void _onFilterChanged() {
    final f = _filter!.text;
    if (f == _lastFilter) return;
    _lastFilter = f;
    _scanDebounce?.cancel();
    _scanDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final ws = ref.read(activeWorkspaceProvider);
      if (ws != null) _ctrl.rescan(ws);
    });
  }

  void _setOption(BatchRenameState Function(BatchRenameState s) f, {bool rescan = false}) {
    _ctrl.update(f);
    final ws = ref.read(activeWorkspaceProvider);
    if (rescan && ws != null) {
      _ctrl.rescan(ws);
    } else {
      _ctrl.replan();
    }
  }

  Future<void> _apply(Workspace ws, RenamePlan plan) async {
    final changes = plan.changes;
    final ok = await showJ3Confirm(
      context,
      title: 'Rename ${Fmt.count(changes.length, 'file')}?',
      message:
          'Files are renamed in two safe phases (through temporary names), and a journal is written so the '
          'whole batch can be undone.',
      confirmLabel: 'Rename',
      details: [for (final r in changes) '${r.item.relativePath}  ->  ${r.newName}'],
    );
    if (ok) await _ctrl.apply(ws);
  }

  Future<void> _undo(Workspace ws, RenameJournal j) async {
    final ok = await showJ3Confirm(
      context,
      title: 'Undo this batch rename?',
      message:
          'Files that are still where the rename left them get their old names back. Files that were moved, '
          'deleted or edited since are skipped and listed.',
      confirmLabel: 'Undo rename',
      details: [for (final e in j.entries.take(30)) '${e.dir.isEmpty ? '' : '${e.dir}/'}${e.to}  ->  ${e.from}'],
    );
    if (ok) await _ctrl.undo(ws, j);
  }

  @override
  Widget build(BuildContext context) {
    final ws = ref.watch(activeWorkspaceProvider);
    if (ws == null) {
      return const ToolScaffold(
        toolId: WsTools.batchRename,
        children: [WorkspaceRequired(purpose: 'Batch rename works on files of the active workspace.')],
      );
    }
    final s = ref.watch(batchRenameProvider);
    if ((s.scan == null && !s.scanning && s.error == null) || (s.workspaceId != null && s.workspaceId != ws.id)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final now = ref.read(batchRenameProvider);
        if (!now.scanning && (now.scan == null && now.error == null || now.workspaceId != ws.id)) {
          if (now.workspaceId != ws.id) _ctrl.update((x) => x.copyWith(dir: '', workspaceId: ws.id));
          _ctrl.rescan(ws);
        }
      });
    }
    return ToolScaffold(
      toolId: WsTools.batchRename,
      inputs: [_folderPanel(ws, s), _rulesPanel(s)],
      results: [
        if (s.error != null) WsErrorBanner(error: s.error!, action: 'The rename'),
        if (s.lastMessage != null)
          WsBanner(
            kind: StatusKind.success,
            title: 'Done',
            message: s.lastMessage,
            onDismiss: () => _ctrl.update((x) => x.copyWith(clearMessage: true)),
          ),
        if (s.opId != null) OperationProgress(operationId: s.opId!, label: 'Renaming'),
        _previewPanel(ws, s),
        _journalPanel(ws, s),
      ],
    );
  }

  Widget _folderPanel(Workspace ws, BatchRenameState s) {
    final filter = ref.watch(draftTextProvider(RenameFields.filter));
    return NeonPanel(
      kicker: 'Files',
      title: 'Which files',
      icon: Icons.folder_copy_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScopeFolderRow(
            workspace: ws,
            relDir: s.workspaceId == ws.id ? s.dir : '',
            onChanged: (d) => _setOption((x) => x.copyWith(dir: d, workspaceId: ws.id), rescan: true),
          ),
          const SizedBox(height: J3Space.sm),
          TextField(
            controller: filter,
            style: J3Type.code,
            decoration: const InputDecoration(labelText: 'Only files matching (glob)', hintText: '*.png'),
          ),
          WsSwitch(
            label: 'Include subfolders',
            value: s.recursive,
            onChanged: (v) => _setOption((x) => x.copyWith(recursive: v), rescan: true),
          ),
          WsSwitch(
            label: 'Include hidden files',
            value: s.includeHidden,
            onChanged: (v) => _setOption((x) => x.copyWith(includeHidden: v), rescan: true),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FitButton(
              NeonButton.ghost(
                label: 'Rescan',
                icon: Icons.refresh,
                busy: s.scanning,
                onPressed: () => _ctrl.rescan(ws),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(String key, String label, {String? hint, double? width}) {
    final c = ref.watch(draftTextProvider(key));
    final field = TextField(
      controller: c,
      style: J3Type.code,
      decoration: InputDecoration(labelText: label, hintText: hint),
    );
    return width == null ? field : SizedBox(width: width, child: field);
  }

  Widget _rulesPanel(BatchRenameState s) {
    return NeonPanel(
      kicker: 'Rules',
      title: 'New names',
      icon: Icons.drive_file_rename_outline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _field(RenameFields.find, 'Find', hint: s.useRegex ? r'IMG_(\d+)' : 'IMG_'),
          const SizedBox(height: J3Space.sm),
          _field(RenameFields.replace, 'Replace with', hint: s.useRegex ? r'shot-$1' : 'shot-'),
          WsSwitch(
            label: 'Regular expression',
            description: r'Groups: $1, ${name}; runs in a worker with a time limit',
            value: s.useRegex,
            onChanged: (v) => _setOption((x) => x.copyWith(useRegex: v)),
          ),
          WsSwitch(
            label: 'Match case',
            value: s.caseSensitive,
            onChanged: (v) => _setOption((x) => x.copyWith(caseSensitive: v)),
          ),
          WsSwitch(
            label: 'Find/replace includes the extension',
            value: s.includeExtension,
            onChanged: (v) => _setOption((x) => x.copyWith(includeExtension: v)),
          ),
          const SizedBox(height: J3Space.sm),
          _field(RenameFields.template, 'Name template (optional)', hint: 'level_{n:3}'),
          const SizedBox(height: J3Space.sm),
          ButtonWrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              _field(RenameFields.prefix, 'Prefix', hint: '{date}_', width: 160),
              _field(RenameFields.suffix, 'Suffix', hint: '_v{n}', width: 160),
              _field(RenameFields.start, 'Start {n}', width: 110),
              _field(RenameFields.step, 'Step', width: 90),
            ],
          ),
          const SizedBox(height: J3Space.xs),
          Text(
            'Tokens: {n} counter, {n:3} zero-padded, {name} name, {ext} extension, {parent} folder, '
            '{date} modified date (yyyy-MM-dd).',
            style: J3Type.caption,
          ),
          const SizedBox(height: J3Space.md),
          ChoiceRow<RenameCase>(
            label: 'Case',
            options: RenameCase.values,
            selected: s.caseTransform,
            labelOf: (c) => c.label,
            onSelected: (c) => _setOption((x) => x.copyWith(caseTransform: c)),
          ),
          const SizedBox(height: J3Space.md),
          ChoiceRow<ExtensionMode>(
            label: 'Extension',
            options: ExtensionMode.values,
            selected: s.extensionMode,
            labelOf: (m) => m.label,
            onSelected: (m) => _setOption((x) => x.copyWith(extensionMode: m)),
          ),
          if (s.extensionMode == ExtensionMode.change) ...[
            const SizedBox(height: J3Space.sm),
            _field(RenameFields.newExt, 'New extension', hint: 'png', width: 160),
          ],
        ],
      ),
    );
  }

  Widget _previewPanel(Workspace ws, BatchRenameState s) {
    final plan = s.plan;
    final fx = context.effects;
    final rows = plan == null ? const <RenameRow>[] : (s.onlyChanges ? plan.changes : plan.rows);
    final blocking = plan?.rows.where((r) => r.status.blocks).length ?? 0;
    return NeonPanel(
      kicker: 'Preview',
      title: plan == null ? 'Preview' : '${Fmt.count(plan.changes.length, 'file')} will change',
      icon: Icons.preview_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (s.scanning) const NeonProgressBar(),
          if (s.planError != null) WsErrorBanner(error: s.planError!, action: 'Evaluating the rules'),
          if (plan?.error != null) WsBanner(kind: StatusKind.error, title: 'Rule problem', message: plan!.error),
          if (s.scan != null && s.scan!.items.isEmpty)
            const EmptyState(glyph: '[ ]', title: 'No files', message: 'The folder has no files matching the filter.'),
          if (plan != null && plan.rows.isNotEmpty) ...[
            ButtonWrap(
              spacing: J3Space.sm,
              runSpacing: J3Space.xs,
              children: [
                for (final st in RenameStatus.values)
                  if (plan.count(st) > 0) CountChip(label: st.label, value: '${plan.count(st)}', kind: _kind(st)),
              ],
            ),
            WsSwitch(
              label: 'Show only files that change',
              value: s.onlyChanges,
              onChanged: (v) => _ctrl.update((x) => x.copyWith(onlyChanges: v)),
            ),
            BoundedList(
              fraction: 0.5,
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final r = rows[i];
                final k = _kind(r.status);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: J3Space.xs),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            PathText(r.item.relativePath, style: J3Type.codeSmall),
                            Row(
                              children: [
                                Text('-> ', style: J3Type.codeSmall.copyWith(color: fx.accentText)),
                                Expanded(
                                  child: PathText(
                                    r.newName,
                                    style: J3Type.code.copyWith(color: r.changes ? J3Colors.text : J3Colors.textMuted),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            StatusBadge(kind: k, text: r.status.label, dense: true),
                            if (r.message != null)
                              Text(
                                r.message!,
                                style: J3Type.caption.copyWith(color: k.color),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
          const SizedBox(height: J3Space.md),
          if (plan != null && blocking > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: J3Space.sm),
              child: Text(
                'Apply is disabled: fix ${Fmt.count(blocking, 'problem')} (collisions, duplicates or invalid names).',
                style: J3Type.caption.copyWith(color: J3Colors.warning),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: FitButton(
              NeonButton(
                label: plan == null ? 'Apply' : 'Apply ${Fmt.count(plan.changes.length, 'rename')}',
                icon: Icons.done_all,
                busy: s.opId != null,
                onPressed: plan != null && plan.canApply && s.opId == null ? () => _apply(ws, plan) : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  StatusKind _kind(RenameStatus st) => switch (st) {
    RenameStatus.unchanged => StatusKind.neutral,
    RenameStatus.ok => StatusKind.success,
    RenameStatus.caseOnly => StatusKind.info,
    RenameStatus.collision || RenameStatus.duplicate || RenameStatus.invalid => StatusKind.error,
  };

  Widget _journalPanel(Workspace ws, BatchRenameState s) {
    final journals = s.journals ?? const [];
    return NeonPanel(
      emphasis: PanelEmphasis.subtle,
      kicker: 'History',
      title: 'Undo a batch rename',
      icon: Icons.history,
      child: journals.isEmpty
          ? Text('No batch renames in this workspace yet.', style: J3Type.caption)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final j in journals.take(8))
                  Padding(
                    padding: const EdgeInsets.only(bottom: J3Space.sm),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${Fmt.dateTime(j.createdAt)}  |  ${Fmt.count(j.entries.length, 'file')}',
                                style: J3Type.code,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                j.note ?? j.status.name,
                                style: J3Type.caption,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        Flexible(
                          child: StatusBadge(
                            kind: j.canUndo ? StatusKind.info : StatusKind.neutral,
                            text: j.status.name.toUpperCase(),
                            dense: true,
                          ),
                        ),
                        if (j.canUndo)
                          NeonIconButton(icon: Icons.undo, tooltip: 'Undo this rename', onPressed: () => _undo(ws, j)),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
