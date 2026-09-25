import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/activity/operation.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/file_types.dart';
import '../../domain/fs_errors.dart';
import 'requests.dart';

/// Status banner used by the workspace tools: icon + text label + title,
/// optional message, detail lines and actions. (Uniform border so it can
/// be painted with rounded corners on every Flutter version.)
class WsBanner extends StatelessWidget {
  const WsBanner({
    super.key,
    required this.kind,
    required this.title,
    this.message,
    this.details = const [],
    this.actions = const [],
    this.onDismiss,
    this.maxDetails = 12,
  });

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
          color: kind.color.withValues(alpha: 0.07),
          borderRadius: J3Radius.medium,
          border: Border.all(color: kind.color.withValues(alpha: 0.45)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(J3Space.md, J3Space.md, J3Space.xs, J3Space.md),
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
                      const SizedBox(height: J3Space.sm),
                      for (final d in details.take(maxDetails))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: SelectableText('> $d', style: J3Type.codeSmall),
                        ),
                      if (details.length > maxDetails)
                        Text('... ${details.length - maxDetails} more', style: J3Type.caption),
                    ],
                    if (actions.isNotEmpty) ...[const SizedBox(height: J3Space.sm), ButtonWrap(children: actions)],
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

/// Readable error for any failure (uses [describeError]).
class WsErrorBanner extends StatelessWidget {
  const WsErrorBanner({super.key, required this.error, this.action = 'The operation', this.onRetry, this.onDismiss});

  final Object error;
  final String action;
  final VoidCallback? onRetry;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final f = describeError(error, action: action);
    final cancelled = f.title == 'Cancelled';
    return WsBanner(
      kind: cancelled ? StatusKind.info : StatusKind.error,
      title: f.title,
      message: f.message,
      details: [?f.hint],
      onDismiss: onDismiss,
      actions: [if (onRetry != null) NeonButton.secondary(label: 'Retry', icon: Icons.refresh, onPressed: onRetry)],
    );
  }
}

/// Shown by workspace tools when no workspace is active.
class WorkspaceRequired extends ConsumerWidget {
  const WorkspaceRequired({super.key, this.purpose = 'This tool works on the files of a workspace.'});
  final String purpose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NeonPanel(
      emphasis: PanelEmphasis.subtle,
      child: EmptyState(
        glyph: '[ ?_? ]',
        title: 'No active workspace',
        message: '$purpose Create, import or choose one first.',
        action: FitButton(
          NeonButton(
            label: 'Open Workspaces',
            icon: Icons.folder_open,
            onPressed: () => ref.goRoute(context, '/workspaces'),
          ),
        ),
      ),
    );
  }
}

/// Live progress of an activity operation with a Cancel button.
class OperationProgress extends ConsumerWidget {
  const OperationProgress({super.key, required this.operationId, required this.label});
  final String operationId;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final op = ref.watch(
      activityProvider.select((s) {
        for (final o in s.operations) {
          if (o.id == operationId) return o;
        }
        return null;
      }),
    );
    if (op == null || op.status != OperationStatus.running) return const SizedBox.shrink();
    return NeonPanel(
      emphasis: PanelEmphasis.subtle,
      padding: EdgeInsets.zero,
      child: LoadingState(
        label: op.progressMessage == null ? label : '$label\n${op.progressMessage}',
        progress: op.progress,
        onCancel: op.cancellable ? () => ref.read(activityProvider.notifier).cancel(operationId) : null,
      ),
    );
  }
}

/// Monospace path/name that ellipsizes and shows the full text on hover
/// or long press.
class PathText extends StatelessWidget {
  const PathText(this.text, {super.key, this.style, this.maxLines = 1});
  final String text;
  final TextStyle? style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: text,
      child: Text(text, style: style ?? J3Type.code, maxLines: maxLines, overflow: TextOverflow.ellipsis),
    );
  }
}

/// A snippet with highlighted ranges (flat [start, end) pairs). The
/// highlight uses background, weight and underline, not colour alone.
class HighlightedSnippet extends StatelessWidget {
  const HighlightedSnippet({super.key, required this.text, required this.ranges, this.maxLines = 2});
  final String text;
  final List<int> ranges;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final spans = <TextSpan>[];
    var pos = 0;
    for (var i = 0; i + 1 < ranges.length; i += 2) {
      final s = ranges[i].clamp(pos, text.length);
      final e = ranges[i + 1].clamp(s, text.length);
      if (s > pos) spans.add(TextSpan(text: text.substring(pos, s)));
      if (e > s) {
        spans.add(
          TextSpan(
            text: text.substring(s, e),
            style: TextStyle(
              color: J3Colors.text,
              backgroundColor: J3Colors.selection,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.underline,
              decorationColor: fx.accentText,
            ),
          ),
        );
      }
      pos = e;
    }
    if (pos < text.length) spans.add(TextSpan(text: text.substring(pos)));
    return Text.rich(
      TextSpan(
        style: J3Type.code.copyWith(color: J3Colors.textSecondary),
        children: spans,
      ),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}

IconData iconForCategory(FileCategory c) => switch (c) {
  FileCategory.folder => Icons.folder,
  FileCategory.link => Icons.link,
  FileCategory.text => Icons.description_outlined,
  FileCategory.code => Icons.data_object,
  FileCategory.data => Icons.table_chart_outlined,
  FileCategory.image => Icons.image_outlined,
  FileCategory.audio => Icons.audiotrack_outlined,
  FileCategory.video => Icons.movie_outlined,
  FileCategory.archive => Icons.folder_zip_outlined,
  FileCategory.font => Icons.font_download_outlined,
  FileCategory.executable => Icons.memory,
  FileCategory.other => Icons.insert_drive_file_outlined,
};

/// Height for an embedded, virtualised list inside a scrolling tool page:
/// large enough to be useful, small enough to keep controls reachable.
double listViewportHeight(BuildContext context, {double fraction = 0.62, double min = 240, double max = 760}) {
  final h = MediaQuery.sizeOf(context).height * fraction;
  return h.clamp(min, max);
}

/// A compact labelled value used in summaries ("12 files").
class CountChip extends StatelessWidget {
  const CountChip({super.key, required this.label, required this.value, this.kind = StatusKind.neutral});
  final String label;
  final String value;
  final StatusKind kind;

  @override
  Widget build(BuildContext context) {
    return StatusBadge(kind: kind, text: '$label: $value', dense: true);
  }
}

/// [OptionSwitch] on its own transparent [Material], so its ink and tile
/// background render correctly inside decorated panels.
class WsSwitch extends StatelessWidget {
  const WsSwitch({super.key, required this.label, required this.value, required this.onChanged, this.description});

  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: OptionSwitch(label: label, value: value, onChanged: onChanged, description: description),
    );
  }
}

/// Sizes a [NeonButton] to its label (the kit button otherwise fills the
/// available width inside Wrap/Align/Column).
class FitButton extends StatelessWidget {
  const FitButton(this.child, {super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => IntrinsicWidth(child: child);
}

/// A [Wrap] of actions: buttons keep their natural width and flow onto
/// new lines on narrow screens.
class ButtonWrap extends StatelessWidget {
  const ButtonWrap({
    super.key,
    required this.children,
    this.spacing = J3Space.sm,
    this.runSpacing = J3Space.sm,
    this.alignment = WrapAlignment.start,
    this.crossAxisAlignment = WrapCrossAlignment.center,
  });

  final List<Widget> children;
  final double spacing;
  final double runSpacing;
  final WrapAlignment alignment;
  final WrapCrossAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: spacing,
      runSpacing: runSpacing,
      alignment: alignment,
      crossAxisAlignment: crossAxisAlignment,
      children: [for (final c in children) c is NeonButton ? FitButton(c) : c],
    );
  }
}

/// Virtualised list embedded in a scrolling page: shrinks to its content
/// for short lists, otherwise takes a fixed share of the screen height.
/// Owns its scroll controller (never shares the page's primary one).
class BoundedList extends StatefulWidget {
  const BoundedList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.fraction = 0.62,
    this.shrinkBelow = 60,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double fraction;

  /// Lists with at most this many items are sized to their content.
  final int shrinkBelow;

  @override
  State<BoundedList> createState() => _BoundedListState();
}

class _BoundedListState extends State<BoundedList> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = listViewportHeight(context, fraction: widget.fraction);
    final shrink = widget.itemCount <= widget.shrinkBelow;
    final list = Scrollbar(
      controller: _controller,
      child: ListView.builder(
        controller: _controller,
        primary: false,
        shrinkWrap: shrink,
        itemCount: widget.itemCount,
        itemBuilder: widget.itemBuilder,
      ),
    );
    return shrink
        ? ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: list,
          )
        : SizedBox(height: maxHeight, child: list);
  }
}
