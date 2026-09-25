import 'dart:convert';
import 'dart:typed_data';

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
import '../../domain/duplicates.dart';
import '../../domain/quarantine.dart';
import '../shared.dart';
import 'duplicates_controller.dart';

const _minSizes = [1, 1024, 100 * 1024, 1024 * 1024, 10 * 1024 * 1024];

String _minSizeLabel(int b) => b <= 1 ? 'Any size' : '≥ ${Fmt.bytes(b, decimals: 0)}';

/// Duplicate Finder with reversible quarantine.
class DuplicatesPage extends ConsumerStatefulWidget {
  const DuplicatesPage({super.key});

  @override
  ConsumerState<DuplicatesPage> createState() => _DuplicatesPageState();
}

class _DuplicatesPageState extends ConsumerState<DuplicatesPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      final st = ref.read(duplicatesProvider);
      if (!st.sessionsLoaded) ref.read(duplicatesProvider.notifier).loadSessions();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ws = ref.watch(activeWorkspaceProvider);
    // Reload journals when the workspace changes (the controller resets).
    ref.listen(activeWorkspaceProvider.select((w) => w?.id), (_, _) {
      ref.read(duplicatesProvider.notifier).loadSessions();
    });
    if (ws == null) {
      return const ToolScaffold(
        toolId: kDuplicatesToolId,
        children: [NoWorkspaceNotice(what: 'The duplicate finder')],
      );
    }
    return ToolScaffold(
      toolId: kDuplicatesToolId,
      inputs: [
        _ScanInput(ws: ws),
        const _QuarantinePanel(),
      ],
      results: [_ScanResults(ws: ws)],
    );
  }
}

class _ScanInput extends ConsumerWidget {
  const _ScanInput({required this.ws});
  final Workspace ws;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(duplicatesProvider);
    final ctl = ref.read(duplicatesProvider.notifier);
    final include = ref.watch(draftTextProvider('$kDuplicatesToolId/include'));
    final exclude = ref.watch(draftTextProvider('$kDuplicatesToolId/exclude'));
    final minSize = ref.draft<int>('$kDuplicatesToolId/minSize', 1);
    final root = st.root ?? ws.rootPath;
    final rel = workspaceLabel(ws, root);

    return NeonPanel(
      kicker: 'Scan',
      title: 'Where to look',
      icon: Icons.manage_search,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Folder (recursive)', style: J3Type.caption),
          const SizedBox(height: J3Space.xs),
          ButtonWrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(rel == '.' ? '${ws.name} (workspace root)' : rel, style: J3Type.code),
              NeonButton.ghost(
                label: 'Change folder',
                icon: Icons.folder_open,
                dense: true,
                onPressed: st.running
                    ? null
                    : () async {
                        final f = await pickWorkspaceFolder(context, ref, title: 'Scan for duplicates in...');
                        if (f != null) ctl.setRoot(f);
                      },
              ),
            ],
          ),
          const SizedBox(height: J3Space.md),
          GlobFields(include: include, exclude: exclude),
          const SizedBox(height: J3Space.md),
          ChoiceRow<int>(
            label: 'Minimum file size',
            options: _minSizes,
            selected: minSize,
            labelOf: _minSizeLabel,
            onSelected: (v) => ref.setDraft('$kDuplicatesToolId/minSize', v),
          ),
          const SizedBox(height: J3Space.sm),
          const InfoLine(
            'Symbolic links are never followed (no loops). Hard links to the same file are recognised and not '
            'reported as duplicates. Only files of equal size are hashed (SHA-256, streamed).',
          ),
          const SizedBox(height: J3Space.md),
          NeonButton(
            key: const Key('dup.scan'),
            label: 'Scan for duplicates',
            icon: Icons.radar,
            busy: st.running,
            onPressed: () => ctl.scan(include: include.text, exclude: exclude.text, minSize: minSize),
          ),
        ],
      ),
    );
  }
}

class _ScanResults extends ConsumerWidget {
  const _ScanResults({required this.ws});
  final Workspace ws;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(duplicatesProvider);
    final ctl = ref.read(duplicatesProvider.notifier);
    final r = st.result;
    final format = ref.draft<ReportFormat>('$kDuplicatesToolId/format', ReportFormat.text);

    final children = <Widget>[
      OperationProgressPanel(operationId: st.opId, label: 'Working...'),
      if (st.error != null) ErrorPanel(title: 'Duplicate finder', error: st.error!),
      if (st.notice != null) StatusBanner(kind: StatusKind.info, title: 'Note', message: st.notice),
    ];

    if (r == null) {
      if (!st.running) {
        children.add(
          const NeonPanel(
            emphasis: PanelEmphasis.subtle,
            child: EmptyState(
              glyph: '[ =_= ]',
              title: 'No scan yet',
              message: 'Run a scan to list identical files, largest waste first. Nothing is ever deleted.',
            ),
          ),
        );
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _spaced(children));
    }

    children.add(
      NeonPanel(
        kicker: 'Summary',
        title: r.groups.isEmpty ? 'No duplicates found' : Fmt.count(r.groups.length, 'duplicate group'),
        icon: Icons.analytics_outlined,
        emphasis: r.groups.isEmpty ? PanelEmphasis.success : PanelEmphasis.normal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: J3Space.sm,
              runSpacing: J3Space.sm,
              children: [
                StatTile(label: 'Reclaimable', value: Fmt.bytes(r.wastedBytes), icon: Icons.savings_outlined),
                StatTile(label: 'Redundant copies', value: '${r.duplicateFiles}', icon: Icons.file_copy_outlined),
                StatTile(label: 'Files scanned', value: '${r.filesScanned}', icon: Icons.description_outlined),
                StatTile(label: 'Hashed', value: '${r.hashedFiles}', icon: Icons.tag),
              ],
            ),
            const SizedBox(height: J3Space.sm),
            Text(
              '${Fmt.bytes(r.bytesScanned)} scanned in ${Fmt.duration(r.elapsed)} · ${r.filterDescription}',
              style: J3Type.caption,
            ),
            if (r.skippedLinks.isNotEmpty)
              InfoLine('${r.skippedLinks.length} symbolic link(s) skipped', icon: Icons.link_off),
            if (r.hardLinks.isNotEmpty)
              InfoLine(
                '${r.hardLinks.length} hard link(s) share storage with another path and are not duplicates',
                icon: Icons.link,
              ),
            if (r.unreadable.isNotEmpty)
              InfoLine(
                '${r.unreadable.length} unreadable: ${r.unreadable.first.$1} (${r.unreadable.first.$2})',
                icon: Icons.warning_amber_rounded,
              ),
            if (r.truncated)
              const InfoLine(
                'File limit reached (200 000): results cover part of the folder.',
                icon: Icons.warning_amber_rounded,
              ),
          ],
        ),
      ),
    );

    if (r.groups.isNotEmpty) {
      final selected = st.selectedCopies.length;
      children.add(
        NeonPanel(
          kicker: 'Groups',
          title: 'Choose what to keep',
          icon: Icons.rule_folder_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ChoiceRow<KeeperRule>(
                label: 'Default keeper in every group',
                options: KeeperRule.values,
                selected: st.rule,
                labelOf: (k) => k.label,
                onSelected: ctl.setRule,
              ),
              const SizedBox(height: J3Space.sm),
              ButtonWrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.xs,
                children: [
                  NeonButton.ghost(label: 'Select all copies', dense: true, onPressed: () => ctl.selectAll(true)),
                  NeonButton.ghost(label: 'Select none', dense: true, onPressed: () => ctl.selectAll(false)),
                ],
              ),
              const SizedBox(height: J3Space.sm),
              BoundedList(
                itemCount: r.groups.length,
                inlineUpTo: 15,
                maxHeight: 560,
                itemBuilder: (context, i) => _GroupCard(group: r.groups[i], ws: ws),
              ),
              const SizedBox(height: J3Space.md),
              NeonButton(
                key: const Key('dup.quarantine'),
                label: selected == 0
                    ? 'Move selected copies to quarantine'
                    : 'Move $selected ${selected == 1 ? 'copy' : 'copies'} to quarantine (${Fmt.bytes(st.selectedBytes)})',
                icon: Icons.move_down_rounded,
                busy: st.running,
                tooltip: 'Moves copies into the workspace quarantine folder. Reversible; nothing is deleted.',
                onPressed: selected == 0
                    ? null
                    : () async {
                        final ok = await showJ3Confirm(
                          context,
                          title: 'Move $selected ${selected == 1 ? 'copy' : 'copies'} to quarantine?',
                          message:
                              'The selected copies are moved out of the folder into the workspace quarantine '
                              '(app storage). Each keeper is re-checked first. You can restore everything '
                              'from "Quarantine & undo" at any time.',
                          confirmLabel: 'Move to quarantine',
                          details: [for (final (_, f) in st.selectedCopies) workspaceLabel(ws, f.path)],
                        );
                        if (ok) await ctl.quarantineSelected();
                      },
              ),
            ],
          ),
        ),
      );
    }

    children.add(
      NeonPanel(
        kicker: 'Report',
        title: 'Export',
        icon: Icons.summarize_outlined,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ChoiceRow<ReportFormat>(
              label: 'Format',
              options: ReportFormat.values,
              selected: format,
              labelOf: (f) => f.label,
              onSelected: (f) => ref.setDraft('$kDuplicatesToolId/format', f),
            ),
            const SizedBox(height: J3Space.sm),
            NeonButton.secondary(
              key: const Key('dup.export'),
              label: 'Save report...',
              icon: Icons.save_alt_rounded,
              onPressed: () {
                final rootLabel = workspaceLabel(ws, r.root);
                final text = buildDuplicateReport(
                  r,
                  st.decisions(),
                  format,
                  rootLabel: rootLabel == '.' ? ws.name : rootLabel,
                );
                saveOutput(
                  context,
                  ref,
                  suggestedName: 'duplicates-${Fmt.stamp(DateTime.now())}.${format.extension}',
                  bytes: Uint8List.fromList(utf8.encode(text)),
                  mimeType: format.mimeType,
                  toolId: kDuplicatesToolId,
                );
              },
            ),
          ],
        ),
      ),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _spaced(children));
  }
}

List<Widget> _spaced(List<Widget> items) => [
  for (var i = 0; i < items.length; i++) ...[if (i > 0) const SizedBox(height: J3Space.md), items[i]],
];

class _GroupCard extends ConsumerWidget {
  const _GroupCard({required this.group, required this.ws});
  final DuplicateGroup group;
  final Workspace ws;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(duplicatesProvider);
    final ctl = ref.read(duplicatesProvider.notifier);
    final keeper = st.keeperOf(group);
    final fx = context.effects;
    return Container(
      margin: const EdgeInsets.only(bottom: J3Space.sm),
      padding: const EdgeInsets.all(J3Space.sm),
      decoration: BoxDecoration(
        color: J3Colors.surfaceRaised,
        borderRadius: J3Radius.small,
        border: Border.all(color: J3Colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '#${group.id + 1} · ${group.files.length} × ${Fmt.bytes(group.size)} · '
            '${Fmt.bytes(group.wastedBytes)} reclaimable',
            style: J3Type.label.copyWith(color: fx.accentText),
          ),
          Text('sha256 ${group.digest.substring(0, 16)}…', style: J3Type.codeSmall.copyWith(fontSize: 11)),
          const SizedBox(height: J3Space.xs),
          RadioGroup<int>(
            groupValue: keeper,
            onChanged: (v) {
              if (v != null) ctl.setKeeper(group, v);
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < group.files.length; i++)
                  _FileRow(
                    file: group.files[i],
                    label: workspaceLabel(ws, group.files[i].path),
                    index: i,
                    isKeeper: i == keeper,
                    selected: st.isSelected(group, i),
                    onSelected: st.running ? null : (v) => ctl.toggleCopy(group, i, v),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.label,
    required this.index,
    required this.isKeeper,
    required this.selected,
    required this.onSelected,
  });

  final DuplicateFile file;
  final String label;
  final int index;
  final bool isKeeper;
  final bool selected;
  final ValueChanged<bool>? onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Tooltip(
          message: 'Keep this copy',
          child: Radio<int>(value: index),
        ),
        Tooltip(
          message: isKeeper ? 'The keeper is never moved' : 'Move this copy to quarantine',
          child: Checkbox(
            value: isKeeper ? false : selected,
            onChanged: isKeeper || onSelected == null ? null : (v) => onSelected!(v ?? false),
          ),
        ),
        const SizedBox(width: J3Space.xs),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: J3Type.codeSmall.copyWith(color: J3Colors.text),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              Wrap(
                spacing: J3Space.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  StatusBadge(
                    dense: true,
                    kind: isKeeper ? StatusKind.success : (selected ? StatusKind.warning : StatusKind.neutral),
                    text: isKeeper ? 'KEEP' : (selected ? 'MOVE' : 'LEAVE'),
                  ),
                  Text(Fmt.dateTime(file.modified), style: J3Type.caption),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _QuarantinePanel extends ConsumerWidget {
  const _QuarantinePanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(duplicatesProvider);
    final ctl = ref.read(duplicatesProvider.notifier);
    final sessions = st.sessions;
    return NeonPanel(
      kicker: 'Undo',
      title: 'Quarantine & undo',
      icon: Icons.restore_from_trash_outlined,
      actions: [
        IconButton(
          tooltip: 'Reload quarantine journals',
          onPressed: ctl.loadSessions,
          icon: const Icon(Icons.refresh, size: 18),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const InfoLine(
            'Moved copies live in the workspace metadata folder (quarantine/<time>/<path>) with a journal. '
            'Restoring never overwrites: an occupied path gets a " (2)" name.',
          ),
          const SizedBox(height: J3Space.sm),
          if (st.sessionsError != null) ErrorPanel(title: 'Cannot read quarantine', error: st.sessionsError!),
          if (!st.sessionsLoaded)
            const LoadingState(label: 'Reading journals...')
          else if (sessions.isEmpty)
            Text('Nothing in quarantine.', style: J3Type.bodySecondary)
          else
            for (final s in sessions) _SessionTile(session: s, busy: st.running),
        ],
      ),
    );
  }
}

class _SessionTile extends ConsumerWidget {
  const _SessionTile({required this.session, required this.busy});
  final QuarantineSession session;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctl = ref.read(duplicatesProvider.notifier);
    final held = session.inQuarantine.toList();
    final restored = session.entries.where((e) => e.state == QuarantineState.restored).length;
    return InkSurface(
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: J3Space.xs),
        childrenPadding: const EdgeInsets.only(left: J3Space.sm, bottom: J3Space.sm),
        title: Text(Fmt.dateTime(session.createdAt), style: J3Type.code),
        subtitle: Wrap(
          spacing: J3Space.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            StatusBadge(
              dense: true,
              kind: held.isEmpty ? StatusKind.success : StatusKind.warning,
              text: held.isEmpty ? 'RESTORED' : 'HELD ${held.length}',
            ),
            Text('${Fmt.bytes(session.quarantinedBytes)} held · $restored restored', style: J3Type.caption),
          ],
        ),
        children: [
          if (held.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: NeonButton.secondary(
                label: 'Restore all ${held.length}',
                icon: Icons.settings_backup_restore,
                dense: true,
                onPressed: busy ? null : () => ctl.restore(session),
              ),
            ),
          for (final e in session.entries)
            Row(
              children: [
                StatusBadge(dense: true, kind: _stateKind(e.state), text: e.state.name.toUpperCase()),
                const SizedBox(width: J3Space.sm),
                Expanded(
                  child: Text(
                    e.restoredAs == null ? e.relativePath : '${e.relativePath} → ${e.restoredAs}',
                    style: J3Type.codeSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (e.state == QuarantineState.quarantined)
                  IconButton(
                    tooltip: 'Restore ${e.relativePath}',
                    onPressed: busy ? null : () => ctl.restore(session, only: {e.relativePath}),
                    icon: const Icon(Icons.undo, size: 18),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

StatusKind _stateKind(QuarantineState s) => switch (s) {
  QuarantineState.quarantined => StatusKind.warning,
  QuarantineState.restored => StatusKind.success,
  QuarantineState.skipped => StatusKind.neutral,
  QuarantineState.missing => StatusKind.error,
  QuarantineState.pending => StatusKind.info,
};
