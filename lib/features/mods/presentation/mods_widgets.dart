import 'package:flutter/material.dart';

import '../../../core/theme/effects.dart';
import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/issues.dart';
import '../domain/manifest.dart';
import '../domain/plan.dart';
import '../domain/resolver.dart';
import 'mods_controller.dart';

/// Inline status banner (icon + label + text, never colour alone). Uses a
/// uniform border so it paints safely with rounded corners.
class ModBanner extends StatelessWidget {
  const ModBanner({
    super.key,
    required this.kind,
    required this.title,
    this.message,
    this.details = const [],
    this.actions = const [],
    this.onDismiss,
    this.maxDetails = 12,
  });

  factory ModBanner.note(ResultNote note, {Key? key, VoidCallback? onDismiss}) => ModBanner(
    key: key,
    kind: note.kind,
    title: note.title,
    message: note.message,
    details: note.details,
    onDismiss: onDismiss,
  );

  final StatusKind kind;
  final String title;
  final String? message;
  final List<String> details;
  final List<Widget> actions;
  final VoidCallback? onDismiss;
  final int maxDetails;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: kind == StatusKind.error || kind == StatusKind.success,
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: kind.color.withValues(alpha: 0.08),
          borderRadius: J3Radius.medium,
          border: Border.all(color: kind.color.withValues(alpha: 0.55)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(J3Space.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(kind.icon, color: kind.color, size: 20),
              const SizedBox(width: J3Space.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${kind.label} // $title', style: J3Type.label.copyWith(color: kind.color)),
                    if (message != null) ...[
                      const SizedBox(height: J3Space.xs),
                      SelectableText(message!, style: J3Type.bodySecondary),
                    ],
                    if (details.isNotEmpty) ...[
                      const SizedBox(height: J3Space.xs),
                      for (final d in details.take(maxDetails))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: SelectableText('> $d', style: J3Type.codeSmall),
                        ),
                      if (details.length > maxDetails)
                        Text('... ${details.length - maxDetails} more', style: J3Type.caption),
                    ],
                    if (actions.isNotEmpty) ...[
                      const SizedBox(height: J3Space.sm),
                      Wrap(spacing: J3Space.sm, runSpacing: J3Space.sm, children: actions),
                    ],
                  ],
                ),
              ),
              if (onDismiss != null)
                IconButton(tooltip: 'Dismiss', onPressed: onDismiss, icon: const Icon(Icons.close, size: 18)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small neutral label chip (tags, counts, sizes).
class InfoChip extends StatelessWidget {
  const InfoChip(this.text, {super.key, this.icon, this.color, this.tooltip});
  final String text;
  final IconData? icon;
  final Color? color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = color ?? J3Colors.textSecondary;
    Widget chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: J3Colors.surfaceHigh,
        borderRadius: J3Radius.small,
        border: Border.all(color: J3Colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: c), const SizedBox(width: 4)],
          Flexible(
            child: Text(
              text,
              style: J3Type.codeSmall.copyWith(color: c),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    if (tooltip != null) chip = Tooltip(message: tooltip!, child: chip);
    return chip;
  }
}

/// Neon status chip for a planned change (icon + label).
class ChangeChip extends StatelessWidget {
  const ChangeChip(this.action, {super.key, this.count});
  final ChangeAction action;
  final int? count;

  static (IconData, Color, String) styleOf(ChangeAction a) => switch (a) {
    ChangeAction.create => (Icons.add_box_outlined, J3Colors.success, 'CREATE'),
    ChangeAction.overwrite => (Icons.published_with_changes, J3Colors.warning, 'OVERWRITE'),
    ChangeAction.unchanged => (Icons.drag_handle, J3Colors.textMuted, 'SAME'),
  };

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final (icon, color, label) = styleOf(action);
    final lit = action != ChangeAction.unchanged;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: lit ? 0.12 : 0.05),
        borderRadius: J3Radius.small,
        border: Border.all(color: color.withValues(alpha: lit ? 0.8 : 0.4)),
        boxShadow: lit && fx.glow
            ? [BoxShadow(color: color.withValues(alpha: 0.25), blurRadius: fx.glowBlur(8), spreadRadius: -2)]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              count == null ? label : '$count $label',
              style: J3Type.codeSmall.copyWith(color: color, fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

StatusKind statusOfSeverity(IssueSeverity s) => switch (s) {
  IssueSeverity.error => StatusKind.error,
  IssueSeverity.warning => StatusKind.warning,
  IssueSeverity.info => StatusKind.info,
};

/// One validation issue line: severity icon + label, field, message.
class IssueLine extends StatelessWidget {
  const IssueLine({super.key, required this.severity, required this.message, this.field});

  IssueLine.of(ModIssue i, {Key? key}) : this(key: key, severity: i.severity, message: i.message, field: i.field);

  final IssueSeverity severity;
  final String message;
  final String? field;

  @override
  Widget build(BuildContext context) {
    final kind = statusOfSeverity(severity);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(kind.icon, size: 16, color: kind.color),
          ),
          const SizedBox(width: J3Space.sm),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${severity.label} ',
                    style: J3Type.codeSmall.copyWith(color: kind.color, fontWeight: FontWeight.w700),
                  ),
                  if (field != null && field!.isNotEmpty)
                    TextSpan(
                      text: '$field: ',
                      style: J3Type.codeSmall.copyWith(color: J3Colors.text),
                    ),
                  TextSpan(text: message, style: J3Type.bodySecondary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Collapsible group of issues with a counted header.
class IssueGroup extends StatelessWidget {
  const IssueGroup({
    super.key,
    required this.title,
    required this.kind,
    required this.children,
    this.initiallyExpanded = true,
  });

  final String title;
  final StatusKind kind;
  final List<Widget> children;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    // Own transparent Material: ListTile ink must not paint below the
    // panel's decorated background.
    return Material(
      type: MaterialType.transparency,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: J3Space.sm),
          leading: Icon(kind.icon, color: kind.color, size: 20),
          title: Text('$title (${children.length})', style: J3Type.label.copyWith(color: kind.color)),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

/// ASCII dependency chains of a profile, e.g. `core-patch ──> hardcore-balance`.
/// Every status is written as a text marker, not only as colour.
class DependencyChainView extends StatelessWidget {
  const DependencyChainView({super.key, required this.report, required this.manifests});

  final ResolutionReport report;
  final Map<String, ModManifest> manifests;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final lines = <List<TextSpan>>[];
    final enabled = report.order.toSet();
    final linked = <String>{};
    final arrow = TextSpan(
      text: ' ──> ',
      style: J3Type.code.copyWith(color: fx.accentText),
    );
    final dotted = TextSpan(
      text: ' ··> ',
      style: J3Type.code.copyWith(color: J3Colors.textMuted),
    );
    TextSpan name(String id) => TextSpan(
      text: id,
      style: J3Type.code.copyWith(color: J3Colors.text),
    );
    TextSpan mark(String text, Color color) => TextSpan(
      text: '  [$text]',
      style: J3Type.code.copyWith(color: color, fontWeight: FontWeight.w700),
    );

    for (final id in report.order) {
      final m = manifests[id];
      if (m == null) continue;
      for (final dep in m.dependencies) {
        linked
          ..add(id)
          ..add(dep.id);
        final issue = report
            .forPackage(id)
            .where((i) => i.relatedId == dep.id && i.code != ResolutionCode.overlap)
            .firstOrNull;
        final status = switch (issue?.code) {
          null => mark('OK', J3Colors.success),
          ResolutionCode.missingDependency => mark('MISSING', J3Colors.error),
          ResolutionCode.dependencyNotEnabled => mark('NOT ENABLED', J3Colors.error),
          ResolutionCode.dependencyVersionMismatch => mark(
            'VERSION ${dep.constraintText} != ${manifests[dep.id]?.version ?? '?'}',
            J3Colors.error,
          ),
          ResolutionCode.dependencyOrder => mark('ORDER', J3Colors.error),
          _ => mark('CHECK', J3Colors.warning),
        };
        final inCycle = report.cycles.any((c) => c.contains(id) && c.contains(dep.id));
        lines.add([
          name(dep.id),
          if (!dep.isAny) TextSpan(text: ' ${dep.constraintText}', style: J3Type.codeSmall),
          arrow,
          name(id),
          inCycle ? mark('CYCLE', J3Colors.error) : status,
        ]);
      }
      for (final opt in m.optionalDependencies) {
        linked.add(id);
        final present = enabled.contains(opt.id);
        final problem = report.forPackage(id).any((i) => i.relatedId == opt.id && i.severity == IssueSeverity.warning);
        lines.add([
          name(opt.id),
          dotted,
          name(id),
          present
              ? (problem ? mark('OPTIONAL: CHECK', J3Colors.warning) : mark('OPTIONAL', J3Colors.success))
              : mark('OPTIONAL: ABSENT', J3Colors.textMuted),
        ]);
      }
    }
    for (final c in report.cycles) {
      lines.add([
        TextSpan(
          text: '[CYCLE] ',
          style: J3Type.code.copyWith(color: J3Colors.error, fontWeight: FontWeight.w700),
        ),
        for (var i = 0; i < c.length; i++) ...[if (i > 0) arrow, name(c[i])],
      ]);
    }
    final standalone = report.order.where((id) => !linked.contains(id)).toList();
    if (standalone.isNotEmpty) {
      lines.add([
        TextSpan(text: 'standalone: ', style: J3Type.codeSmall),
        TextSpan(
          text: standalone.join(', '),
          style: J3Type.code.copyWith(color: J3Colors.textSecondary),
        ),
      ]);
    }
    if (lines.isEmpty) {
      return Text('No packages enabled.', style: J3Type.caption);
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(J3Space.md),
      decoration: BoxDecoration(
        color: J3Colors.inputFill,
        borderRadius: J3Radius.small,
        border: Border.all(color: J3Colors.border),
      ),
      child: Scrollbar(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final l in lines) Text.rich(TextSpan(children: l), softWrap: false)],
          ),
        ),
      ),
    );
  }
}

/// Visualises an overlap: every provider in order, losers struck through,
/// the winner marked.
class OverlapView extends StatelessWidget {
  const OverlapView({super.key, required this.overlap});
  final FileOverlap overlap;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    return Container(
      margin: const EdgeInsets.only(bottom: J3Space.sm),
      padding: const EdgeInsets.all(J3Space.sm),
      decoration: BoxDecoration(
        color: J3Colors.surfaceRaised,
        borderRadius: J3Radius.small,
        border: Border.all(color: J3Colors.warning.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.layers_outlined, size: 16, color: J3Colors.warning),
              const SizedBox(width: J3Space.xs),
              Expanded(child: SelectableText(overlap.target, style: J3Type.code)),
            ],
          ),
          const SizedBox(height: J3Space.xs),
          Wrap(
            spacing: J3Space.xs,
            runSpacing: J3Space.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (var i = 0; i < overlap.providers.length; i++) ...[
                if (i > 0) Text('──>', style: J3Type.codeSmall.copyWith(color: fx.accentText)),
                if (i < overlap.providers.length - 1)
                  InfoChip(
                    '${overlap.providers[i]} (overridden)',
                    icon: Icons.remove_circle_outline,
                    color: J3Colors.textMuted,
                    tooltip: 'Applied earlier; its version of this file is replaced',
                  )
                else
                  InfoChip(
                    '${overlap.providers[i]} WINS',
                    icon: Icons.emoji_events_outlined,
                    color: fx.accentText,
                    tooltip: 'Applied last; its version of this file is used',
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Tabs for phones: a wrap of selectable chips (never overflows).
class PaneTabs<T> extends StatelessWidget {
  const PaneTabs({
    super.key,
    required this.values,
    required this.selected,
    required this.onSelected,
    required this.labelOf,
    required this.iconOf,
  });

  final List<T> values;
  final T selected;
  final ValueChanged<T> onSelected;
  final String Function(T) labelOf;
  final IconData Function(T) iconOf;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Wrap(
        spacing: J3Space.sm,
        runSpacing: J3Space.sm,
        children: [
          for (final v in values)
            Semantics(
              selected: v == selected,
              child: ChoiceChip(
                avatar: Icon(iconOf(v), size: 16),
                label: Text(labelOf(v)),
                selected: v == selected,
                showCheckmark: false,
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onSelected: (_) => onSelected(v),
              ),
            ),
        ],
      ),
    );
  }
}

/// Opens [child] as a right-side drawer on wide screens and as a bottom
/// sheet on phones. Motion follows the effects settings.
Future<T?> showModsSheet<T>(
  BuildContext context, {
  required String title,
  required Widget Function(BuildContext) builder,
}) {
  final width = MediaQuery.sizeOf(context).width;
  final fx = context.effects;
  if (width >= J3Breakpoints.medium) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close $title',
      barrierColor: Colors.black54,
      transitionDuration: fx.motion(J3Durations.medium),
      pageBuilder: (ctx, _, _) => Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: J3Colors.surface,
          elevation: 8,
          child: SizedBox(
            width: width * 0.9 < 560 ? width * 0.9 : 560,
            height: double.infinity,
            child: SafeArea(
              child: _SheetFrame(title: title, child: builder(ctx)),
            ),
          ),
        ),
      ),
      transitionBuilder: (ctx, anim, _, child) => SlideTransition(
        position: Tween(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: J3Colors.surface,
    builder: (ctx) => SizedBox(
      height: MediaQuery.sizeOf(ctx).height * 0.9,
      child: _SheetFrame(title: title, child: builder(ctx)),
    ),
  );
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(J3Space.lg, J3Space.sm, J3Space.xs, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(title, style: J3Type.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        const Divider(),
        Expanded(child: child),
      ],
    );
  }
}
