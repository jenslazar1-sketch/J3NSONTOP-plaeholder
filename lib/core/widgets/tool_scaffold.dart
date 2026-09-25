import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/user_data.dart';
import '../theme/effects.dart';
import '../theme/j3_colors.dart';
import '../theme/j3_spacing.dart';
import '../theme/j3_typography.dart';
import '../tools/tool_registry.dart';
import 'glitch_text.dart';

/// Standard layout for every tool page:
///
/// * header: section kicker, tool name, description, favourite toggle and
///   optional header actions (presets, help);
/// * body: either a single column ([children]) or, on wide screens, a two
///   pane layout ([inputs] left, [results] right) that stacks on phones.
///
/// Tools pass their registry [toolId]; name/description/icon come from the
/// registry so they stay consistent with search and navigation.
class ToolScaffold extends ConsumerWidget {
  const ToolScaffold({
    super.key,
    required this.toolId,
    this.children,
    this.inputs,
    this.results,
    this.headerActions = const [],
    this.banner,
    this.scrollable = true,
    this.body,
  }) : assert(children != null || inputs != null || body != null, 'Provide children, inputs/results or body');

  final String toolId;

  /// Single-column content.
  final List<Widget>? children;

  /// Two-pane content: inputs on the left, results on the right (stacked
  /// vertically below 900 px).
  final List<Widget>? inputs;
  final List<Widget>? results;

  /// Fully custom body that manages its own scrolling (e.g. editors).
  final Widget? body;
  final List<Widget> headerActions;

  /// Shown under the header (platform notes, recovery warnings).
  final Widget? banner;
  final bool scrollable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tool = ref.watch(toolRegistryProvider).byId(toolId);
    final fav = ref.watch(userDataProvider.select((u) => u.favorites.contains(toolId)));
    final fx = context.effects;

    final media = MediaQuery.of(context);
    // Short or narrow viewports (phones, landscape, large text) get a compact
    // header: smaller title and the description behind an info toggle.
    final compact = media.size.height < 700 || media.size.width < J3Breakpoints.compact;

    final header = Padding(
      padding: EdgeInsets.only(bottom: compact ? J3Space.sm : J3Space.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (tool != null)
            Container(
              width: compact ? 36 : 44,
              height: compact ? 36 : 44,
              margin: const EdgeInsets.only(right: J3Space.md, top: 2),
              decoration: BoxDecoration(
                color: J3Colors.surfaceRaised,
                borderRadius: J3Radius.medium,
                border: Border.all(color: fx.accentColor.withValues(alpha: 0.6)),
                boxShadow: fx.glow
                    ? [BoxShadow(color: fx.accentColor.withValues(alpha: 0.25), blurRadius: fx.glowBlur(12))]
                    : null,
              ),
              child: Icon(tool.icon, color: fx.accentText, size: compact ? 18 : 22),
            ),
          Expanded(
            child: _HeaderText(
              kicker: '// ${(tool?.section.label ?? 'TOOL').toUpperCase()}',
              title: tool?.name ?? toolId,
              description: tool?.description,
              compact: compact,
            ),
          ),
          ...headerActions,
          IconButton(
            tooltip: fav ? 'Remove from favourites' : 'Add to favourites',
            onPressed: () => ref.read(userDataProvider.notifier).toggleFavorite(toolId),
            icon: Icon(
              fav ? Icons.star_rounded : Icons.star_outline_rounded,
              color: fav ? fx.accentText : J3Colors.textMuted,
            ),
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= J3Breakpoints.medium;
        final pad = wide ? J3Space.pagePaddingWide : J3Space.pagePadding;

        if (body != null) {
          return Padding(
            padding: pad,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                if (banner != null) ...[banner!, const SizedBox(height: J3Space.md)],
                Expanded(child: body!),
              ],
            ),
          );
        }

        Widget content;
        if (inputs != null) {
          final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _gap(inputs!));
          final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _gap(results ?? const []));
          content = wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: left),
                    const SizedBox(width: J3Space.lg),
                    Expanded(child: right),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    left,
                    if (results != null && results!.isNotEmpty) ...[const SizedBox(height: J3Space.lg), right],
                  ],
                );
        } else {
          content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _gap(children!));
        }

        final column = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            if (banner != null) ...[banner!, const SizedBox(height: J3Space.md)],
            content,
            const SizedBox(height: J3Space.xxl),
          ],
        );

        if (!scrollable) return Padding(padding: pad, child: column);
        return Scrollbar(
          child: SingleChildScrollView(
            padding: pad,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: J3Size.maxContentWidth),
                child: column,
              ),
            ),
          ),
        );
      },
    );
  }

  static List<Widget> _gap(List<Widget> items) => [
    for (var i = 0; i < items.length; i++) ...[if (i > 0) const SizedBox(height: J3Space.lg), items[i]],
  ];
}

/// Tool title block. In compact mode the description is collapsed behind an
/// info toggle so the tool itself gets the screen space.
class _HeaderText extends StatefulWidget {
  const _HeaderText({required this.kicker, required this.title, required this.description, required this.compact});

  final String kicker;
  final String title;
  final String? description;
  final bool compact;

  @override
  State<_HeaderText> createState() => _HeaderTextState();
}

class _HeaderTextState extends State<_HeaderText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final showDescription = widget.description != null && (!widget.compact || _expanded);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.kicker,
          style: J3Type.kicker.copyWith(color: fx.accentText),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Flexible(
              child: GlitchText(widget.title, style: widget.compact ? J3Type.title : J3Type.headline, maxLines: 2),
            ),
            if (widget.compact && widget.description != null)
              IconButton(
                tooltip: _expanded ? 'Hide description' : 'Show description',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(_expanded ? Icons.expand_less : Icons.info_outline, size: 18),
              ),
          ],
        ),
        if (showDescription) ...[
          const SizedBox(height: J3Space.xs),
          Text(widget.description!, style: J3Type.bodySecondary),
        ],
      ],
    );
  }
}
