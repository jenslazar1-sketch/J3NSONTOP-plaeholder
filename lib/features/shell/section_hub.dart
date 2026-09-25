import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/platform/capabilities.dart';
import '../../core/storage/user_data.dart';
import '../../core/theme/effects.dart';
import '../../core/theme/j3_colors.dart';
import '../../core/theme/j3_spacing.dart';
import '../../core/theme/j3_typography.dart';
import '../../core/tools/tool_definition.dart';
import '../../core/tools/tool_registry.dart';
import '../../core/widgets/widgets.dart';

/// Landing for a section: the feature's custom landing if registered,
/// otherwise a grid of the section's tools.
class SectionPage extends ConsumerWidget {
  const SectionPage({super.key, required this.section});
  final ToolSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final landing = ref.watch(toolRegistryProvider).landingFor(section);
    if (landing != null) return landing(context);
    return SectionHub(section: section);
  }
}

class SectionHub extends ConsumerWidget {
  const SectionHub({super.key, required this.section, this.embedded = false});
  final ToolSection section;

  /// When embedded inside another page, skip the page header and padding.
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(toolRegistryProvider);
    final caps = ref.watch(capabilitiesProvider);
    final tools = registry.inSection(section, caps);
    final hidden = registry.inSection(section).length - tools.length;
    final fx = context.effects;

    final grid = tools.isEmpty
        ? const EmptyState(title: 'No tools in this section on this platform')
        : LayoutBuilder(
            builder: (context, c) {
              final cols = (c.maxWidth / 300).floor().clamp(1, 4);
              return Wrap(
                spacing: J3Space.md,
                runSpacing: J3Space.md,
                children: [
                  for (final t in tools)
                    SizedBox(
                      width: (c.maxWidth - (cols - 1) * J3Space.md) / cols,
                      child: ToolCard(tool: t),
                    ),
                ],
              );
            },
          );

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!embedded) ...[
          Text('// ${section.label.toUpperCase()}', style: J3Type.kicker.copyWith(color: fx.accentText)),
          GlitchText(section.label, style: J3Type.headline),
          const SizedBox(height: J3Space.xs),
          Text('${section.tagline}  |  ${tools.length} tools', style: J3Type.bodySecondary),
          const SizedBox(height: J3Space.lg),
        ],
        grid,
        if (hidden > 0) ...[
          const SizedBox(height: J3Space.md),
          Text('$hidden tool(s) need capabilities not available on ${caps.platform.label}.', style: J3Type.caption),
        ],
      ],
    );
    if (embedded) return column;
    return SingleChildScrollView(
      padding: J3Space.pagePaddingWide,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: J3Size.maxContentWidth),
          child: column,
        ),
      ),
    );
  }
}

/// Clickable tool card with hover glow and favourite indicator.
class ToolCard extends ConsumerStatefulWidget {
  const ToolCard({super.key, required this.tool, this.dense = false});
  final ToolDefinition tool;
  final bool dense;

  @override
  ConsumerState<ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends ConsumerState<ToolCard> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final t = widget.tool;
    final fav = ref.watch(userDataProvider.select((u) => u.favorites.contains(t.id)));
    final active = _hover || _focus;
    return Semantics(
      button: true,
      label: '${t.name}. ${t.description}',
      excludeSemantics: true,
      child: FocusableActionDetector(
        onShowHoverHighlight: (h) => setState(() => _hover = h),
        onShowFocusHighlight: (f) => setState(() => _focus = f),
        mouseCursor: SystemMouseCursors.click,
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => context.go(t.route))},
        child: GestureDetector(
          onTap: () => context.go(t.route),
          child: AnimatedContainer(
            duration: fx.motion(J3Durations.fast),
            padding: EdgeInsets.all(widget.dense ? J3Space.md : J3Space.lg),
            decoration: BoxDecoration(
              color: active ? J3Colors.surfaceRaised : J3Colors.surface,
              borderRadius: J3Radius.medium,
              border: Border.all(color: active ? fx.accentColor : J3Colors.border, width: _focus ? 2 : 1),
              boxShadow: active && fx.glow
                  ? [
                      BoxShadow(
                        color: fx.accentColor.withValues(alpha: 0.22),
                        blurRadius: fx.glowBlur(18),
                        spreadRadius: -4,
                      ),
                    ]
                  : null,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(t.icon, color: active ? fx.accentText : J3Colors.textSecondary, size: 24),
                const SizedBox(width: J3Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.name, style: J3Type.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                      if (!widget.dense) ...[
                        const SizedBox(height: J3Space.xs),
                        Text(t.description, style: J3Type.caption, maxLines: 3, overflow: TextOverflow.ellipsis),
                      ],
                    ],
                  ),
                ),
                if (fav) Icon(Icons.star_rounded, size: 16, color: fx.accentText),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// All sections at a glance (the "Tools" tab on phones).
class AllToolsPage extends ConsumerWidget {
  const AllToolsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fx = context.effects;
    return SingleChildScrollView(
      padding: J3Space.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('// ALL TOOLS', style: J3Type.kicker.copyWith(color: fx.accentText)),
          Text('Toolbox', style: J3Type.headline),
          const SizedBox(height: J3Space.lg),
          for (final s in ToolSection.values)
            if (ref.watch(toolRegistryProvider).inSection(s, ref.watch(capabilitiesProvider)).isNotEmpty) ...[
              SectionHeader(
                title: s.label,
                kicker: s.tagline,
                trailing: s == ToolSection.system
                    ? null
                    : TextButton(onPressed: () => context.go(s.route), child: const Text('Open')),
              ),
              SectionHub(section: s, embedded: true),
              const SizedBox(height: J3Space.xl),
            ],
        ],
      ),
    );
  }
}
