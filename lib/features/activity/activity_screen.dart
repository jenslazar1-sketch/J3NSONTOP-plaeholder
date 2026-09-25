import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/activity/activity_controller.dart';
import '../../core/activity/operation.dart';
import '../../core/platform/capabilities.dart';
import '../../core/theme/effects.dart';
import '../../core/theme/j3_colors.dart';
import '../../core/theme/j3_spacing.dart';
import '../../core/theme/j3_typography.dart';
import '../../core/tools/tool_registry.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../core/workspace/workspace_controller.dart';
import '../shell/activity_panel.dart' show statusKindOf;
import 'activity_log.dart';

/// Keeps the activity log filter while the user moves around the app.
class ActivityFilterController extends Notifier<ActivityFilter> {
  @override
  ActivityFilter build() => const ActivityFilter();

  void set(ActivityFilter filter) => state = filter;
}

final activityFilterProvider = NotifierProvider<ActivityFilterController, ActivityFilter>(ActivityFilterController.new);

/// Statuses a finished operation can have, in chip order.
const List<OperationStatus> _finishedStatuses = [
  OperationStatus.succeeded,
  OperationStatus.warning,
  OperationStatus.failed,
  OperationStatus.cancelled,
];

String _statusChipLabel(OperationStatus s) => switch (s) {
  OperationStatus.running => 'Running',
  OperationStatus.succeeded => 'Done',
  OperationStatus.warning => 'Warnings',
  OperationStatus.failed => 'Failed',
  OperationStatus.cancelled => 'Cancelled',
};

/// Full operation history: running operations with progress and Cancel,
/// searchable/filterable finished operations with expandable details,
/// redacted log export and history clearing.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  late final TextEditingController _search = TextEditingController(text: ref.read(activityFilterProvider).query);
  final ScrollController _scroll = ScrollController();
  final Set<String> _expanded = {};

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _toolName(String id) => ref.read(toolRegistryProvider).byId(id)?.name ?? id;

  String? _workspaceName(String? id) {
    if (id == null) return null;
    return ref.read(workspacesProvider).byId(id)?.name ?? 'Removed workspace ($id)';
  }

  void _setFilter(ActivityFilter f) => ref.read(activityFilterProvider.notifier).set(f);

  /// Builds the redacted log of [ops] and hands it to the save/export flow.
  Future<void> _export(List<OperationRecord> ops, ActivityFilter filter) async {
    final now = DateTime.now();
    final text = buildActivityLog(
      ops,
      now: now,
      platformLabel: ref.read(capabilitiesProvider).platform.label,
      toolName: _toolName,
      workspaceName: _workspaceName,
      filterDescription: filter.describe(toolName: _toolName),
    );
    await saveOutput(
      context,
      ref,
      suggestedName: 'j3nsontop-activity-${Fmt.stamp(now)}.txt',
      bytes: Uint8List.fromList(utf8.encode(text)),
      mimeType: 'text/plain',
      toolId: 'system.activity',
    );
  }

  Future<void> _clear(int finished, int running) async {
    final ok = await showJ3Confirm(
      context,
      title: 'Clear operation history?',
      message:
          'Removes $finished finished ${finished == 1 ? 'operation' : 'operations'} from the history on this '
          'device. This cannot be undone.',
      details: [
        if (running > 0) '$running running ${running == 1 ? 'operation is' : 'operations are'} kept',
        'Files, workspaces, backups and mod journals are not touched',
      ],
      confirmLabel: 'Clear history',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await ref.read(activityProvider.notifier).clearHistory();
    _expanded.clear();
    ref
        .read(activityProvider.notifier)
        .notify(NoticeKind.success, 'Cleared $finished ${finished == 1 ? 'operation' : 'operations'} from history');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(activityProvider);
    final filter = ref.watch(activityFilterProvider);
    ref.watch(toolRegistryProvider);
    ref.watch(workspacesProvider);
    final fx = context.effects;

    final running = state.running;
    final finished = [
      for (final o in state.operations)
        if (o.status.isFinished) o,
    ];
    final visible = [
      for (final o in finished)
        if (filter.matches(o, toolName: _toolName(o.toolId))) o,
    ];
    final baseCount = [
      for (final o in finished)
        if (filter.matchesIgnoringStatus(o, toolName: _toolName(o.toolId))) o,
    ];
    final today = state.countToday(DateTime.now());
    final toolIds = {for (final o in state.operations) o.toolId}.toList()
      ..sort((a, b) => _toolName(a).toLowerCase().compareTo(_toolName(b).toLowerCase()));

    return LayoutBuilder(
      builder: (context, c) {
        final basePad = c.maxWidth >= J3Breakpoints.medium ? J3Space.xl : J3Space.lg;
        final hPad = math.max(basePad, (c.maxWidth - J3Size.maxContentWidth) / 2);
        final narrow = c.maxWidth < J3Breakpoints.compact;
        EdgeInsets pad([double top = J3Space.lg]) => EdgeInsets.fromLTRB(hPad, top, hPad, 0);

        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('// OPERATIONS LOG', style: J3Type.kicker.copyWith(color: fx.accentText)),
            const SizedBox(height: 2),
            GlitchText('Activity', style: J3Type.headline),
            const SizedBox(height: J3Space.xs),
            Text(
              '${Fmt.count(finished.length, 'operation')} in history  |  ${running.length} running  |  $today today',
              style: J3Type.bodySecondary,
            ),
            const SizedBox(height: J3Space.xs),
            Text(
              'Only real operations performed by tools are recorded. History keeps the newest '
              '${ActivityController.historyLimit} finished operations on this device.',
              style: J3Type.caption,
            ),
            const SizedBox(height: J3Space.md),
            Wrap(
              spacing: J3Space.sm,
              runSpacing: J3Space.sm,
              children: [
                IntrinsicWidth(
                  child: NeonButton.secondary(
                    label: 'Export log',
                    icon: Icons.file_download_outlined,
                    tooltip:
                        'Save the ${running.length + visible.length} operations shown as a plain-text log '
                        '(credentials are masked)',
                    onPressed: running.isEmpty && visible.isEmpty
                        ? null
                        : () => _export([...running, ...visible], filter),
                  ),
                ),
                IntrinsicWidth(
                  child: NeonButton.danger(
                    label: 'Clear history',
                    icon: Icons.delete_sweep_outlined,
                    tooltip: 'Remove finished operations from the history (running ones are kept)',
                    onPressed: finished.isEmpty ? null : () => _clear(finished.length, running.length),
                  ),
                ),
              ],
            ),
          ],
        );

        final searchField = TextField(
          controller: _search,
          style: J3Type.body,
          onChanged: (v) => _setFilter(filter.copyWith(query: v)),
          decoration: InputDecoration(
            prefixIcon: Icon(Icons.search, color: fx.accentText),
            hintText: 'Search title, summary, error or tool id',
            suffixIcon: filter.query.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    onPressed: () {
                      _search.clear();
                      _setFilter(filter.copyWith(query: ''));
                    },
                    icon: const Icon(Icons.close, size: 18),
                  ),
          ),
        );
        final statusChips = Wrap(
          spacing: J3Space.sm,
          runSpacing: J3Space.sm,
          children: [
            _StatusChip(
              label: 'All',
              icon: Icons.all_inclusive,
              color: J3Colors.textSecondary,
              count: baseCount.length,
              selected: filter.status == null,
              onSelected: () => _setFilter(filter.copyWith(clearStatus: true)),
            ),
            for (final s in _finishedStatuses)
              _StatusChip(
                label: _statusChipLabel(s),
                icon: statusKindOf(s).icon,
                color: statusKindOf(s).color,
                count: baseCount.where((o) => o.status == s).length,
                selected: filter.status == s,
                onSelected: () =>
                    _setFilter(filter.status == s ? filter.copyWith(clearStatus: true) : filter.copyWith(status: s)),
              ),
          ],
        );
        final toolDropdown = InputDecorator(
          decoration: const InputDecoration(labelText: 'Tool', prefixIcon: Icon(Icons.build_circle_outlined, size: 18)),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              isExpanded: true,
              isDense: true,
              value: toolIds.contains(filter.toolId) ? filter.toolId : null,
              style: J3Type.body,
              dropdownColor: J3Colors.surfaceRaised,
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('All tools', overflow: TextOverflow.ellipsis)),
                for (final id in toolIds)
                  DropdownMenuItem<String?>(
                    value: id,
                    child: Text(_toolName(id) == id ? id : '${_toolName(id)}  ($id)', overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => _setFilter(v == null ? filter.copyWith(clearTool: true) : filter.copyWith(toolId: v)),
            ),
          ),
        );
        final filterFooter = Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: J3Space.md,
          children: [
            Text('Showing ${visible.length} of ${finished.length}', style: J3Type.caption),
            if (filter.isActive)
              TextButton.icon(
                onPressed: () {
                  _search.clear();
                  _setFilter(const ActivityFilter());
                },
                icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
                label: const Text('Clear filters'),
              ),
          ],
        );
        final filters = NeonPanel(
          kicker: '// FILTER',
          title: 'Search and filter',
          emphasis: PanelEmphasis.subtle,
          padding: const EdgeInsets.all(J3Space.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (c.maxWidth >= 760)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: searchField),
                    const SizedBox(width: J3Space.md),
                    Expanded(flex: 2, child: toolDropdown),
                  ],
                )
              else ...[
                searchField,
                const SizedBox(height: J3Space.md),
                toolDropdown,
              ],
              const SizedBox(height: J3Space.md),
              statusChips,
              const SizedBox(height: J3Space.sm),
              filterFooter,
            ],
          ),
        );

        final Widget listSliver;
        if (finished.isEmpty) {
          listSliver = SliverToBoxAdapter(
            child: EmptyState(
              title: running.isEmpty ? 'No operations yet' : 'No finished operations yet',
              message:
                  'Hashes, conversions, profile applies, exports and other real work appear here with '
                  'their results, counts and errors.',
              glyph: '>_',
              action: IntrinsicWidth(
                child: NeonButton.secondary(
                  label: 'Browse tools',
                  icon: Icons.apps,
                  onPressed: () => context.go('/tools'),
                ),
              ),
            ),
          );
        } else if (visible.isEmpty) {
          listSliver = SliverToBoxAdapter(
            child: EmptyState(
              title: 'No operations match the filter',
              message: 'Change the search text, status or tool to see more.',
              glyph: '[ ?? ]',
              action: IntrinsicWidth(
                child: NeonButton.secondary(
                  label: 'Clear filters',
                  icon: Icons.filter_alt_off_outlined,
                  onPressed: () {
                    _search.clear();
                    _setFilter(const ActivityFilter());
                  },
                ),
              ),
            ),
          );
        } else {
          listSliver = SliverList.separated(
            itemCount: visible.length,
            separatorBuilder: (_, _) => const SizedBox(height: J3Space.sm),
            itemBuilder: (context, i) {
              final op = visible[i];
              return _OperationRow(
                key: ValueKey(op.id),
                op: op,
                narrow: narrow,
                expanded: _expanded.contains(op.id),
                toolName: _toolName(op.toolId),
                workspaceName: _workspaceName(op.workspaceId),
                onToggle: () => setState(() {
                  if (!_expanded.remove(op.id)) _expanded.add(op.id);
                }),
              );
            },
          );
        }

        return Scrollbar(
          controller: _scroll,
          child: CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverPadding(
                padding: pad(),
                sliver: SliverToBoxAdapter(child: header),
              ),
              if (running.isNotEmpty)
                SliverPadding(
                  padding: pad(),
                  sliver: SliverToBoxAdapter(
                    child: _RunningPanel(ops: running, toolName: _toolName),
                  ),
                ),
              SliverPadding(
                padding: pad(),
                sliver: SliverToBoxAdapter(child: filters),
              ),
              SliverPadding(
                padding: pad(J3Space.md),
                sliver: SliverToBoxAdapter(
                  child: SectionHeader(kicker: 'History', title: 'Finished operations (${visible.length})'),
                ),
              ),
              SliverPadding(padding: pad(0), sliver: listSliver),
              const SliverToBoxAdapter(child: SizedBox(height: J3Space.xxxl)),
            ],
          ),
        );
      },
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.count,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final IconData icon;
  final Color color;
  final int count;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Show ${label.toLowerCase()} ($count)',
      child: FilterChip(
        selected: selected,
        showCheckmark: false,
        onSelected: (_) => onSelected(),
        avatar: Icon(icon, size: 16, color: color),
        label: Text('$label  $count', style: J3Type.caption.copyWith(color: J3Colors.text)),
        materialTapTargetSize: MaterialTapTargetSize.padded,
      ),
    );
  }
}

/// Operations in progress with real progress and Cancel.
class _RunningPanel extends ConsumerWidget {
  const _RunningPanel({required this.ops, required this.toolName});
  final List<OperationRecord> ops;
  final String Function(String id) toolName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    return NeonPanel(
      kicker: '// RUNNING NOW',
      title: '${Fmt.count(ops.length, 'operation')} in progress',
      icon: Icons.sync,
      emphasis: PanelEmphasis.strong,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < ops.length; i++) ...[
            if (i > 0) const Divider(height: J3Space.xl),
            _RunningRow(op: ops[i], toolName: toolName(ops[i].toolId), now: now),
          ],
        ],
      ),
    );
  }
}

class _RunningRow extends ConsumerWidget {
  const _RunningRow({required this.op, required this.toolName, required this.now});
  final OperationRecord op;
  final String toolName;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pct = op.progress == null ? 'Working' : '${(op.progress! * 100).round()} %';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(op.title, style: J3Type.label),
        const SizedBox(height: J3Space.xs),
        NeonProgressBar(value: op.progress),
        const SizedBox(height: J3Space.xs),
        Wrap(
          spacing: J3Space.md,
          runSpacing: J3Space.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const StatusBadge(kind: StatusKind.running, dense: true),
            Text(pct, style: J3Type.code),
            if (op.progressMessage != null) Text(op.progressMessage!, style: J3Type.caption),
            Text(
              'Started ${Fmt.time(op.startedAt)}  (${Fmt.duration(now.difference(op.startedAt))})',
              style: J3Type.codeSmall,
            ),
            Text(toolName, style: J3Type.caption),
          ],
        ),
        const SizedBox(height: J3Space.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: op.cancellable
              ? IntrinsicWidth(
                  child: NeonButton.secondary(
                    label: 'Cancel',
                    icon: Icons.stop_circle_outlined,
                    dense: true,
                    tooltip: 'Ask "${op.title}" to stop at its next checkpoint',
                    onPressed: () => ref.read(activityProvider.notifier).cancel(op.id),
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.block, size: 14, color: J3Colors.textMuted),
                    const SizedBox(width: J3Space.xs),
                    Flexible(child: Text('This operation cannot be cancelled', style: J3Type.caption)),
                  ],
                ),
        ),
      ],
    );
  }
}

/// One finished operation; tap/Enter toggles its details.
class _OperationRow extends StatefulWidget {
  const _OperationRow({
    super.key,
    required this.op,
    required this.expanded,
    required this.onToggle,
    required this.toolName,
    required this.workspaceName,
    required this.narrow,
  });

  final OperationRecord op;
  final bool expanded;
  final VoidCallback onToggle;
  final String toolName;
  final String? workspaceName;
  final bool narrow;

  @override
  State<_OperationRow> createState() => _OperationRowState();
}

class _OperationRowState extends State<_OperationRow> {
  bool _focus = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final op = widget.op;
    final kind = statusKindOf(op.status);
    final expanded = widget.expanded;
    final borderColor = _focus
        ? fx.accentColor
        : expanded || _hover
        ? kind.color.withValues(alpha: 0.55)
        : J3Colors.border;

    final head = Padding(
      padding: const EdgeInsets.fromLTRB(J3Space.md + 3, J3Space.md, J3Space.sm, J3Space.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(kind.icon, size: 20, color: kind.color),
          ),
          const SizedBox(width: J3Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(op.title, style: J3Type.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: J3Space.xs),
                Wrap(
                  spacing: J3Space.sm,
                  runSpacing: J3Space.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    StatusBadge(kind: kind, text: op.status.label, dense: true),
                    Text(widget.toolName, style: J3Type.caption),
                    Text(Fmt.relative(op.startedAt), style: J3Type.codeSmall.copyWith(color: J3Colors.textMuted)),
                  ],
                ),
                if (!expanded && (op.error ?? op.summary) != null) ...[
                  const SizedBox(height: J3Space.xs),
                  Text(
                    op.error ?? op.summary!,
                    style: J3Type.caption.copyWith(color: op.error != null ? J3Colors.error : J3Colors.textSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: J3Space.xs),
          AnimatedRotation(
            turns: expanded ? 0.5 : 0,
            duration: fx.motion(J3Durations.fast),
            child: const Icon(Icons.expand_more, color: J3Colors.textSecondary),
          ),
        ],
      ),
    );

    final details = expanded
        ? _OperationDetails(
            op: op,
            toolName: widget.toolName,
            workspaceName: widget.workspaceName,
            narrow: widget.narrow,
          )
        : const SizedBox(width: double.infinity);

    return AnimatedContainer(
      duration: fx.motion(J3Durations.fast),
      decoration: BoxDecoration(
        color: expanded ? J3Colors.surfaceRaised : J3Colors.surface,
        borderRadius: J3Radius.medium,
        border: Border.all(color: borderColor, width: _focus ? 2 : 1),
      ),
      child: ClipRRect(
        borderRadius: J3Radius.medium,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  button: true,
                  expanded: expanded,
                  label: '${op.title}, ${op.status.label}. ${expanded ? 'Hide' : 'Show'} details',
                  excludeSemantics: true,
                  // Own Material so the ripple paints above the row colour.
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      onTap: widget.onToggle,
                      onFocusChange: (f) => setState(() => _focus = f),
                      onHover: (h) => setState(() => _hover = h),
                      child: head,
                    ),
                  ),
                ),
                // AnimatedSize cannot run with a zero duration, so reduced
                // motion swaps the details in without it.
                if (fx.reduceMotion)
                  details
                else
                  AnimatedSize(duration: J3Durations.medium, alignment: Alignment.topCenter, child: details),
              ],
            ),
            Positioned(left: 0, top: 0, bottom: 0, width: 3, child: ColoredBox(color: kind.color)),
          ],
        ),
      ),
    );
  }
}

class _OperationDetails extends StatelessWidget {
  const _OperationDetails({
    required this.op,
    required this.toolName,
    required this.workspaceName,
    required this.narrow,
  });

  final OperationRecord op;
  final String toolName;
  final String? workspaceName;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(J3Space.md + 3, 0, J3Space.md, J3Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(),
          const SizedBox(height: J3Space.sm),
          if (op.summary != null) ...[
            SelectableText(op.summary!, style: J3Type.body),
            const SizedBox(height: J3Space.sm),
          ],
          if (op.error != null) ...[
            Container(
              padding: const EdgeInsets.all(J3Space.sm),
              decoration: BoxDecoration(
                color: J3Colors.error.withValues(alpha: 0.08),
                borderRadius: J3Radius.small,
                border: Border.all(color: J3Colors.error.withValues(alpha: 0.6)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline, size: 18, color: J3Colors.error),
                  const SizedBox(width: J3Space.sm),
                  Expanded(
                    child: SelectableText('ERROR // ${op.error}', style: J3Type.code.copyWith(color: J3Colors.error)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: J3Space.sm),
          ],
          KeyValueTable(
            keyWidth: narrow ? 92 : 140,
            rows: [
              ('Status', op.status.label),
              ('Tool', toolName == op.toolId ? op.toolId : '$toolName  (${op.toolId})'),
              ('Workspace', workspaceName ?? 'None'),
              ('Started', Fmt.dateTime(op.startedAt)),
              if (op.endedAt != null) ('Ended', Fmt.dateTime(op.endedAt!)),
              if (op.elapsed != null) ('Duration', Fmt.duration(op.elapsed!)),
              ('Operation id', op.id),
            ],
          ),
          if (op.counts.isNotEmpty) ...[
            const SizedBox(height: J3Space.sm),
            Text('COUNTS', style: J3Type.kicker.copyWith(color: J3Colors.textMuted)),
            const SizedBox(height: J3Space.xs),
            Wrap(
              spacing: J3Space.sm,
              runSpacing: J3Space.sm,
              children: [
                for (final e in op.counts.entries)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: J3Space.sm, vertical: J3Space.xs),
                    decoration: BoxDecoration(
                      color: J3Colors.inputFill,
                      borderRadius: J3Radius.small,
                      border: Border.all(color: J3Colors.border),
                    ),
                    child: Text('${e.key}: ${formatCount(e.key, e.value)}', style: J3Type.code),
                  ),
              ],
            ),
          ],
          if (op.details.isNotEmpty) ...[
            const SizedBox(height: J3Space.sm),
            Text('DETAILS (${op.details.length})', style: J3Type.kicker.copyWith(color: J3Colors.textMuted)),
            const SizedBox(height: J3Space.xs),
            Container(
              padding: const EdgeInsets.all(J3Space.sm),
              decoration: BoxDecoration(
                color: J3Colors.inputFill,
                borderRadius: J3Radius.small,
                border: Border.all(color: J3Colors.border),
              ),
              child: SelectableText(op.details.map((d) => '> $d').join('\n'), style: J3Type.codeSmall),
            ),
          ],
        ],
      ),
    );
  }
}
