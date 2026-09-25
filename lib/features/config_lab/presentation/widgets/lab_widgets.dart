/// Small shared widgets of the Config Lab: validity badges, the parse error
/// panel (caret snippet + jump), issue lists, pane tabs and the itemised
/// conversion report.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/conversion_report.dart';
import '../../domain/source_location.dart';
import '../document_io.dart';

enum Validity { valid, invalid, empty, checking, stale }

/// VALID / INVALID / EMPTY / CHECKING / STALE badge (icon + text).
class ValidityBadge extends StatelessWidget {
  const ValidityBadge({super.key, required this.validity, this.label});
  final Validity validity;

  /// Overrides the default text (e.g. "VALID YAML").
  final String? label;

  @override
  Widget build(BuildContext context) {
    final (kind, text) = switch (validity) {
      Validity.valid => (StatusKind.success, 'VALID'),
      Validity.invalid => (StatusKind.error, 'INVALID'),
      Validity.empty => (StatusKind.neutral, 'EMPTY'),
      Validity.checking => (StatusKind.running, 'CHECKING'),
      Validity.stale => (StatusKind.warning, 'NOT CHECKED'),
    };
    return Semantics(
      label: 'Status: ${label ?? text}',
      child: StatusBadge(kind: kind, text: label ?? text),
    );
  }
}

/// A status row: badge plus a short explanation that wraps.
class StatusLine extends StatelessWidget {
  const StatusLine({super.key, required this.badge, this.message, this.trailing = const []});
  final Widget badge;
  final String? message;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: J3Space.md,
      runSpacing: J3Space.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        badge,
        if (message != null) Text(message!, style: J3Type.bodySecondary),
        ...trailing,
      ],
    );
  }
}

/// Monospace excerpt box (scrolls horizontally, never wraps).
class CodeExcerpt extends StatelessWidget {
  const CodeExcerpt(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(J3Space.sm),
      decoration: BoxDecoration(
        color: J3Colors.inputFill,
        borderRadius: J3Radius.small,
        border: Border.all(color: J3Colors.border),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(text, style: J3Type.codeSmall.copyWith(color: color ?? J3Colors.text)),
      ),
    );
  }
}

/// Parse error with location, caret snippet and a "Jump to error" action.
class ParseErrorPanel extends StatelessWidget {
  const ParseErrorPanel({super.key, required this.error, this.onJump, this.kicker = 'PARSE ERROR'});
  final LocatedError error;
  final void Function(SourceLocation location)? onJump;
  final String kicker;

  @override
  Widget build(BuildContext context) {
    final loc = error.location;
    return Semantics(
      liveRegion: true,
      child: NeonPanel(
        kicker: kicker,
        title: loc == null ? 'Invalid input' : 'Line ${loc.line}, column ${loc.column}',
        icon: Icons.error_outline,
        emphasis: PanelEmphasis.danger,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const StatusBadge(kind: StatusKind.error, dense: true),
                const SizedBox(width: J3Space.sm),
                Expanded(child: SelectableText(error.message, style: J3Type.body)),
              ],
            ),
            if (error.snippet != null && error.snippet!.isNotEmpty) ...[
              const SizedBox(height: J3Space.sm),
              CodeExcerpt(error.snippet!),
            ],
            if (loc != null && onJump != null) ...[
              const SizedBox(height: J3Space.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: NeonButton.secondary(
                  label: 'Jump to error',
                  icon: Icons.my_location,
                  dense: true,
                  tooltip: 'Move the cursor to line ${loc.line}, column ${loc.column}',
                  onPressed: () => onJump!(loc),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One entry of an [IssueList].
class IssueItem {
  const IssueItem({required this.kind, required this.message, this.line, this.column});
  final StatusKind kind;
  final String message;
  final int? line;
  final int? column;
}

/// Warnings/errors with line numbers; tapping one jumps to it.
class IssueList extends StatelessWidget {
  const IssueList({super.key, required this.items, this.onJump, this.title = 'Issues', this.kicker = 'DIAGNOSTICS'});
  final List<IssueItem> items;
  final void Function(int line, int column)? onJump;
  final String title;
  final String kicker;

  @override
  Widget build(BuildContext context) {
    final shown = items.take(200).toList();
    return NeonPanel(
      kicker: kicker,
      title: '$title (${items.length})',
      emphasis: items.any((i) => i.kind == StatusKind.error) ? PanelEmphasis.danger : PanelEmphasis.subtle,
      child: InkLayer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final i in shown)
              InkWell(
                onTap: i.line == null || onJump == null ? null : () => onJump!(i.line!, i.column ?? 1),
                borderRadius: J3Radius.small,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: J3Space.xs, horizontal: J3Space.xs),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(i.kind.icon, size: 16, color: i.kind.color),
                        const SizedBox(width: J3Space.sm),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text:
                                      '${i.kind.label}${i.line == null ? '' : ' L${i.line}${i.column == null ? '' : ':${i.column}'}'}  ',
                                  style: J3Type.codeSmall.copyWith(color: i.kind.color),
                                ),
                                TextSpan(text: i.message, style: J3Type.bodySecondary),
                              ],
                            ),
                          ),
                        ),
                        if (i.line != null && onJump != null)
                          const Padding(
                            padding: EdgeInsets.only(left: J3Space.xs),
                            child: Icon(Icons.my_location, size: 16, color: J3Colors.textMuted),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            if (items.length > shown.length)
              Text('… ${items.length - shown.length} more not shown', style: J3Type.caption),
          ],
        ),
      ),
    );
  }
}

/// One selectable pane of a workbench.
class PaneSpec {
  const PaneSpec({required this.id, required this.label, required this.icon, required this.builder, this.badge});
  final String id;
  final String label;
  final IconData icon;
  final WidgetBuilder builder;

  /// Optional count shown next to the label.
  final int? badge;
}

/// Accessible tab strip (chips) that wraps on narrow screens.
class PaneTabs extends StatelessWidget {
  const PaneTabs({super.key, required this.panes, required this.selected, required this.onSelected});
  final List<PaneSpec> panes;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: J3Space.sm,
      runSpacing: J3Space.sm,
      children: [
        for (final p in panes)
          Semantics(
            selected: p.id == selected,
            button: true,
            child: ChoiceChip(
              avatar: Icon(p.icon, size: 16, color: p.id == selected ? J3Colors.text : J3Colors.textSecondary),
              label: Text(p.badge == null ? p.label : '${p.label} (${p.badge})'),
              selected: p.id == selected,
              showCheckmark: false,
              onSelected: (_) => onSelected(p.id),
            ),
          ),
      ],
    );
  }
}

/// Last-save line: time, target and backup location (copyable).
class SaveReceiptLine extends ConsumerWidget {
  const SaveReceiptLine({super.key, required this.receipt});
  final SaveReceipt receipt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backup = receipt.backupPath;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: J3Space.sm, vertical: J3Space.xs),
        decoration: BoxDecoration(
          color: J3Colors.success.withValues(alpha: 0.06),
          borderRadius: J3Radius.small,
          border: Border.all(color: J3Colors.success.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline, size: 16, color: J3Colors.success),
            const SizedBox(width: J3Space.sm),
            Expanded(
              child: Text(
                backup == null
                    ? 'SAVED ${Fmt.time(receipt.at)} -> ${receipt.target}'
                    : 'SAVED ${Fmt.time(receipt.at)} -> ${receipt.target}  |  backup: ${receipt.backupDisplay ?? backup}',
                style: J3Type.codeSmall.copyWith(color: J3Colors.text),
              ),
            ),
            if (backup != null)
              IconButton(
                tooltip: 'Copy backup path',
                onPressed: () => copyWithNotice(ref, backup, 'backup path'),
                icon: const Icon(Icons.copy_rounded, size: 16),
              ),
          ],
        ),
      ),
    );
  }
}

/// Transparent Material so ink splashes and list tiles render above a
/// coloured panel (NeonPanel paints an opaque surface).
class InkLayer extends StatelessWidget {
  const InkLayer({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(type: MaterialType.transparency, child: child);
}

/// [OptionSwitch] that is safe to place inside panels.
class LabSwitch extends StatelessWidget {
  const LabSwitch({super.key, required this.label, required this.value, required this.onChanged, this.description});
  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => InkLayer(
    child: OptionSwitch(label: label, description: description, value: value, onChanged: onChanged),
  );
}

/// Short inline explanation with an info icon.
class LabHint extends StatelessWidget {
  const LabHint(this.text, {super.key, this.icon = Icons.info_outline});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: J3Colors.info),
        const SizedBox(width: J3Space.sm),
        Expanded(child: Text(text, style: J3Type.caption)),
      ],
    );
  }
}

/// LOSSLESS / CHANGES REPRESENTATION / FAILED badge.
class VerdictBadge extends StatelessWidget {
  const VerdictBadge({super.key, required this.report});
  final ConversionReport report;

  @override
  Widget build(BuildContext context) {
    final kind = report.failed
        ? StatusKind.error
        : report.lossless
        ? StatusKind.success
        : StatusKind.warning;
    return Tooltip(
      message: report.failed
          ? 'The conversion was refused; nothing was produced.'
          : report.lossless
          ? 'Data, types, key order and comments are preserved.'
          : 'The output differs from the source; every difference is listed.',
      child: StatusBadge(kind: kind, text: report.verdict),
    );
  }
}

/// Itemised conversion report grouped by kind.
class ConversionReportView extends ConsumerStatefulWidget {
  const ConversionReportView({super.key, required this.report, this.onJumpToLine});
  final ConversionReport report;
  final void Function(int line)? onJumpToLine;

  @override
  ConsumerState<ConversionReportView> createState() => _ConversionReportViewState();
}

class _ConversionReportViewState extends ConsumerState<ConversionReportView> {
  final Set<IssueKind> _expanded = {};

  static StatusKind _kindOf(IssueSeverity s) => switch (s) {
    IssueSeverity.error => StatusKind.error,
    IssueSeverity.loss => StatusKind.warning,
    IssueSeverity.note => StatusKind.info,
  };

  static String _severityLabel(IssueSeverity s) => switch (s) {
    IssueSeverity.error => 'ERROR',
    IssueSeverity.loss => 'CHANGE',
    IssueSeverity.note => 'NOTE',
  };

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    final groups = <(IssueKind, IssueSeverity), List<ConversionIssue>>{};
    for (final i in r.issues) {
      groups.putIfAbsent((i.kind, i.severity), () => []).add(i);
    }
    final ordered = groups.entries.toList()..sort((a, b) => a.key.$2.index.compareTo(b.key.$2.index));
    final summary = r.failed
        ? '${r.errors.length} error(s): conversion refused.'
        : r.lossless
        ? (r.notes.isEmpty
              ? 'No differences: data, types, key order and comments are preserved.'
              : 'Data preserved; ${r.notes.length} note(s) below.')
        : '${r.losses.length} change(s) in representation, listed below.';
    return NeonPanel(
      kicker: 'CONVERSION REPORT',
      title: '${r.from} -> ${r.to}',
      emphasis: r.failed ? PanelEmphasis.danger : PanelEmphasis.normal,
      actions: [
        IconButton(
          tooltip: 'Copy report',
          onPressed: () => copyWithNotice(ref, r.toText(), 'conversion report'),
          icon: const Icon(Icons.copy_all_rounded, size: 18),
        ),
      ],
      child: InkLayer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: J3Space.sm,
              runSpacing: J3Space.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                VerdictBadge(report: r),
                if (r.verified) const StatusBadge(kind: StatusKind.success, text: 'ROUND TRIP VERIFIED'),
              ],
            ),
            const SizedBox(height: J3Space.sm),
            Text(summary, style: J3Type.bodySecondary),
            for (final g in ordered) ...[const SizedBox(height: J3Space.md), _group(g.key.$1, g.key.$2, g.value)],
          ],
        ),
      ),
    );
  }

  Widget _group(IssueKind kind, IssueSeverity severity, List<ConversionIssue> items) {
    final status = _kindOf(severity);
    final open = _expanded.contains(kind);
    final shown = open ? items : items.take(8).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(status.icon, size: 16, color: status.color),
            const SizedBox(width: J3Space.sm),
            Expanded(
              child: Text(
                '${_severityLabel(severity)} // ${kind.label} (${items.length})',
                style: J3Type.label.copyWith(color: status.color),
              ),
            ),
          ],
        ),
        for (final i in shown)
          InkWell(
            onTap: i.line != null && widget.onJumpToLine != null ? () => widget.onJumpToLine!(i.line!) : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32),
              child: Padding(
                padding: const EdgeInsets.only(left: 24, top: 2, bottom: 2),
                child: Text.rich(
                  TextSpan(
                    children: [
                      if (i.line != null)
                        TextSpan(
                          text: 'L${i.line} ',
                          style: J3Type.codeSmall.copyWith(color: context.effects.accentText),
                        ),
                      if (i.path != null)
                        TextSpan(
                          text: '${i.path} ',
                          style: J3Type.codeSmall.copyWith(color: J3Colors.text),
                        ),
                      TextSpan(
                        text: i.message,
                        style: J3Type.caption.copyWith(color: J3Colors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (items.length > 8)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => open ? _expanded.remove(kind) : _expanded.add(kind)),
              child: Text(open ? 'Show fewer' : 'Show all ${items.length}'),
            ),
          ),
      ],
    );
  }
}
