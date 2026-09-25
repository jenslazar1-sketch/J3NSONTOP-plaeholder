import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/activity/activity_controller.dart';
import '../../core/platform/capabilities.dart';
import '../../core/storage/user_data.dart';
import '../../core/theme/effects.dart';
import '../../core/theme/j3_colors.dart';
import '../../core/theme/j3_spacing.dart';
import '../../core/theme/j3_typography.dart';
import '../../core/tools/tool_definition.dart';
import '../../core/tools/tool_registry.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../core/workspace/workspace_controller.dart';
import '../palette/command_palette.dart';
import '../sample/sample_workspace.dart';
import '../shell/activity_panel.dart' show OperationTile;
import '../shell/destinations.dart';
import 'home_status.dart' show KindBadge;

/// Lays [children] out in a fixed number of equal columns ([cols]); the
/// last row stretches its items. One column stacks them.
class ColumnsLayout extends StatelessWidget {
  const ColumnsLayout({super.key, required this.children, required this.cols, this.gap = J3Space.lg});

  final List<Widget> children;
  final int cols;
  final double gap;

  @override
  Widget build(BuildContext context) {
    if (cols <= 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(height: gap), children[i]],
        ],
      );
    }
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += cols) {
      final chunk = children.sublist(i, i + cols > children.length ? children.length : i + cols);
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var j = 0; j < chunk.length; j++) ...[if (j > 0) SizedBox(width: gap), Expanded(child: chunk[j])],
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[if (i > 0) SizedBox(height: gap), rows[i]],
      ],
    );
  }
}

/// Equal-width tiles in as many columns as fit (at least [minTileWidth]).
class TileGrid extends StatelessWidget {
  const TileGrid({super.key, required this.children, this.minTileWidth = 220, this.maxCols = 4});
  final List<Widget> children;
  final double minTileWidth;
  final int maxCols;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        const gap = J3Space.sm;
        final cols = ((c.maxWidth + gap) / (minTileWidth + gap)).floor().clamp(1, maxCols);
        final w = (c.maxWidth - (cols - 1) * gap) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final child in children) SizedBox(width: w, child: child)],
        );
      },
    );
  }
}

/// Focusable, hoverable tile with a subtle neon glow. Disabled when
/// [onTap] is null.
class HomeTile extends StatefulWidget {
  const HomeTile({
    super.key,
    required this.child,
    required this.onTap,
    required this.semanticLabel,
    this.tooltip,
    this.selected = false,
    this.padding = const EdgeInsets.all(J3Space.md),
  });

  final Widget child;
  final VoidCallback? onTap;
  final String semanticLabel;
  final String? tooltip;
  final bool selected;
  final EdgeInsetsGeometry padding;

  @override
  State<HomeTile> createState() => _HomeTileState();
}

class _HomeTileState extends State<HomeTile> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final enabled = widget.onTap != null;
    final active = enabled && (_hover || _focus);
    Widget tile = Semantics(
      button: true,
      enabled: enabled,
      selected: widget.selected,
      label: widget.semanticLabel,
      excludeSemantics: true,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onShowHoverHighlight: (h) => setState(() => _hover = h),
        onShowFocusHighlight: (f) => setState(() => _focus = f),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: fx.motion(J3Durations.fast),
            constraints: const BoxConstraints(minHeight: 48),
            padding: widget.padding,
            decoration: BoxDecoration(
              color: active || widget.selected ? J3Colors.surfaceRaised : J3Colors.inputFill,
              borderRadius: J3Radius.medium,
              border: Border.all(
                color: _focus
                    ? fx.accentColor
                    : active
                    ? fx.accentColor.withValues(alpha: 0.7)
                    : widget.selected
                    ? fx.accentColor.withValues(alpha: 0.45)
                    : J3Colors.border,
                width: _focus ? 2 : 1,
              ),
              boxShadow: active && fx.glow
                  ? [
                      BoxShadow(
                        color: fx.accentColor.withValues(alpha: 0.22),
                        blurRadius: fx.glowBlur(16),
                        spreadRadius: -4,
                      ),
                    ]
                  : null,
            ),
            child: Opacity(opacity: enabled ? 1 : 0.5, child: widget.child),
          ),
        ),
      ),
    );
    if (widget.tooltip != null) tile = Tooltip(message: widget.tooltip!, child: tile);
    return tile;
  }
}

/// A keyboard shortcut drawn as a small key cap.
class ShortcutCap extends StatelessWidget {
  const ShortcutCap(this.keys, {super.key});
  final String keys;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: J3Colors.surface,
        borderRadius: J3Radius.small,
        border: Border.all(color: J3Colors.borderStrong),
      ),
      child: Text(keys, style: J3Type.codeSmall.copyWith(fontSize: 10.5, color: J3Colors.textSecondary)),
    );
  }
}

/// Icon in a small bordered square.
class IconBox extends StatelessWidget {
  const IconBox({super.key, required this.icon, this.size = 36});
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: J3Colors.surface,
        borderRadius: J3Radius.medium,
        border: Border.all(color: fx.accentColor.withValues(alpha: 0.55)),
      ),
      child: Icon(icon, size: size * 0.52, color: fx.accentText),
    );
  }
}

// ------------------------------------------------------------ quick actions

class QuickActionsPanel extends ConsumerStatefulWidget {
  const QuickActionsPanel({super.key});

  @override
  ConsumerState<QuickActionsPanel> createState() => _QuickActionsPanelState();
}

class _QuickActionsPanelState extends ConsumerState<QuickActionsPanel> {
  bool _creatingSample = false;

  Future<void> _createSample() async {
    setState(() => _creatingSample = true);
    final activity = ref.read(activityProvider.notifier);
    try {
      final ws = await createSampleWorkspace(ref);
      activity.notify(NoticeKind.success, 'Sample workspace "${ws.name}" is ready and active');
    } catch (e) {
      activity.notify(NoticeKind.error, 'Could not create the sample workspace: $e');
    } finally {
      if (mounted) setState(() => _creatingSample = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final keys = ref.watch(capabilitiesProvider).supports(Capability.keyboardShortcuts);
    final registry = ref.watch(toolRegistryProvider);
    final terminalId = kTerminalRoute.substring('/tool/'.length);
    final hasTerminal = registry.byId(terminalId) != null;

    Widget action({
      required IconData icon,
      required String label,
      required String hint,
      required VoidCallback? onTap,
      String? shortcut,
      bool busy = false,
    }) {
      return HomeTile(
        semanticLabel: '$label. $hint${shortcut != null && keys ? '. Shortcut $shortcut' : ''}',
        tooltip: shortcut != null && keys ? '$label ($shortcut)' : null,
        onTap: busy ? null : onTap,
        child: Row(
          children: [
            busy
                ? const SizedBox(
                    width: 36,
                    height: 36,
                    child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconBox(icon: icon),
            const SizedBox(width: J3Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: J3Space.sm,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(label, style: J3Type.label),
                      if (shortcut != null && keys) ShortcutCap(shortcut),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(hint, style: J3Type.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return NeonPanel(
      kicker: '// QUICK ACTIONS',
      title: 'Jump in',
      icon: Icons.flash_on_outlined,
      child: TileGrid(
        minTileWidth: 200,
        maxCols: 2,
        children: [
          action(
            icon: Icons.search,
            label: 'Command palette',
            hint: 'Search tools and actions',
            shortcut: 'Ctrl+K',
            onTap: () => showCommandPalette(context),
          ),
          action(
            icon: Icons.terminal,
            label: 'Terminal',
            hint: hasTerminal ? 'Typed commands' : 'Not in this build',
            shortcut: 'Ctrl+`',
            onTap: hasTerminal ? () => context.go(kTerminalRoute) : null,
          ),
          action(
            icon: Icons.folder_open_outlined,
            label: 'Workspaces',
            hint: 'Link, import, browse',
            shortcut: 'Ctrl+2',
            onTap: () => context.go('/workspaces'),
          ),
          action(
            icon: Icons.science_outlined,
            label: 'Create sample workspace',
            hint: _creatingSample ? 'Creating files...' : 'Neon Dungeon demo files',
            busy: _creatingSample,
            onTap: _createSample,
          ),
          action(
            icon: Icons.replay,
            label: 'Replay intro',
            hint: 'The laughing skull',
            onTap: () => context.go('/intro?replay=1'),
          ),
          action(
            icon: Icons.settings_outlined,
            label: 'Settings',
            hint: 'Effects, sound, data',
            shortcut: 'Ctrl+,',
            onTap: () => context.go('/settings'),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- recent tools

class RecentToolsPanel extends ConsumerWidget {
  const RecentToolsPanel({super.key});

  static const int limit = 6;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(toolRegistryProvider);
    final caps = ref.watch(capabilitiesProvider);
    final recents = [
      for (final r in ref.watch(userDataProvider.select((u) => u.recentTools)))
        if (registry.byId(r.toolId)?.availableOn(caps) ?? false) (registry.byId(r.toolId)!, r.openedAt),
    ].take(limit).toList();
    final now = DateTime.now();
    return NeonPanel(
      kicker: '// RECENT TOOLS',
      title: 'Recently opened',
      icon: Icons.history,
      child: recents.isEmpty
          ? Text('Tools you open appear here with the time you last used them.', style: J3Type.bodySecondary)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (t, at) in recents)
                  Padding(
                    padding: const EdgeInsets.only(bottom: J3Space.xs),
                    child: HomeTile(
                      semanticLabel: '${t.name}, opened ${Fmt.relative(at, now: now)}',
                      padding: const EdgeInsets.symmetric(horizontal: J3Space.md, vertical: J3Space.sm),
                      onTap: () => context.go(t.route),
                      child: Row(
                        children: [
                          Icon(t.icon, size: 20, color: context.effects.accentText),
                          const SizedBox(width: J3Space.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(t.name, style: J3Type.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                                Text(
                                  '${t.section.label}  |  ${Fmt.relative(at, now: now)}',
                                  style: J3Type.caption,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

// -------------------------------------------------------- recent workspaces

class RecentWorkspacesPanel extends ConsumerWidget {
  const RecentWorkspacesPanel({super.key});

  static const int limit = 5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workspacesProvider);
    final recent = state.recent.take(limit).toList();
    final now = DateTime.now();
    return NeonPanel(
      kicker: '// RECENT WORKSPACES',
      title: 'Workspaces',
      icon: Icons.folder_special_outlined,
      actions: [
        IconButton(
          tooltip: 'Manage workspaces',
          onPressed: () => context.go('/workspaces'),
          icon: const Icon(Icons.open_in_new, size: 18),
        ),
      ],
      child: recent.isEmpty
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No workspaces yet. Link a folder (desktop), import files, or create the sample workspace.',
                  style: J3Type.bodySecondary,
                ),
                const SizedBox(height: J3Space.sm),
                IntrinsicWidth(
                  child: NeonButton.secondary(
                    label: 'Open workspaces',
                    icon: Icons.folder_open_outlined,
                    dense: true,
                    onPressed: () => context.go('/workspaces'),
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final w in recent)
                  Padding(
                    padding: const EdgeInsets.only(bottom: J3Space.xs),
                    child: HomeTile(
                      selected: w.id == state.activeId,
                      semanticLabel:
                          '${w.name}, ${w.kind.label}${w.id == state.activeId ? ', active workspace' : ', tap to make active'}',
                      tooltip: w.id == state.activeId
                          ? 'Active workspace - open it in Workspaces'
                          : 'Make "${w.name}" the active workspace',
                      padding: const EdgeInsets.symmetric(horizontal: J3Space.md, vertical: J3Space.sm),
                      onTap: w.id == state.activeId
                          ? () => context.go('/workspaces')
                          : () => ref.read(workspacesProvider.notifier).setActive(w.id),
                      child: Row(
                        children: [
                          Icon(
                            w.id == state.activeId ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                            size: 18,
                            color: context.effects.accentText,
                          ),
                          const SizedBox(width: J3Space.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(w.name, style: J3Type.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 2),
                                Wrap(
                                  spacing: J3Space.sm,
                                  runSpacing: 2,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    KindBadge(kind: w.kind),
                                    if (w.id == state.activeId)
                                      const StatusBadge(kind: StatusKind.success, text: 'ACTIVE', dense: true),
                                    Text(Fmt.relative(w.lastOpenedAt, now: now), style: J3Type.caption),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

// --------------------------------------------------------- recent activity

class RecentActivityPanel extends ConsumerWidget {
  const RecentActivityPanel({super.key});

  static const int limit = 5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ops = ref.watch(activityProvider.select((s) => s.operations)).take(limit).toList();
    final narrow = MediaQuery.sizeOf(context).width < 480;
    return NeonPanel(
      kicker: '// RECENT ACTIVITY',
      title: 'Last operations',
      icon: Icons.monitor_heart_outlined,
      actions: [
        IconButton(
          tooltip: 'Open the activity log',
          onPressed: () => context.go('/activity'),
          icon: const Icon(Icons.open_in_new, size: 18),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ops.isEmpty)
            Text(
              'No operations yet. Hashes, conversions, profile applies and exports appear here with their real '
              'results.',
              style: J3Type.bodySecondary,
            )
          else
            for (final op in ops)
              Padding(
                padding: const EdgeInsets.only(bottom: J3Space.xs),
                // The shared tile keeps its status badge on one line; on
                // phones cap the text scale so it cannot overflow.
                child: narrow
                    ? MediaQuery.withClampedTextScaling(
                        maxScaleFactor: 1.5,
                        child: OperationTile(op: op, compact: true),
                      )
                    : OperationTile(op: op, compact: true),
              ),
          const SizedBox(height: J3Space.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => context.go('/activity'),
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: const Text('Open activity log'),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ sections

class SectionsPanel extends ConsumerWidget {
  const SectionsPanel({super.key});

  static IconData iconFor(ToolSection s) {
    for (final d in kDestinations) {
      if (d.section == s) return d.icon;
    }
    return Icons.apps;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(toolRegistryProvider);
    final caps = ref.watch(capabilitiesProvider);
    final sections = [
      for (final s in ToolSection.values)
        if (s != ToolSection.system) s,
    ];
    return NeonPanel(
      kicker: '// SECTIONS',
      title: 'Toolbox',
      icon: Icons.apps,
      actions: [TextButton(onPressed: () => context.go('/tools'), child: const Text('All tools'))],
      child: TileGrid(
        minTileWidth: 240,
        maxCols: 3,
        children: [
          for (final s in sections)
            Builder(
              builder: (context) {
                final count = registry.inSection(s, caps).length;
                return HomeTile(
                  semanticLabel: '${s.label}, ${Fmt.count(count, 'tool')}. ${s.tagline}',
                  onTap: () => context.go(s.route),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      IconBox(icon: iconFor(s), size: 40),
                      const SizedBox(width: J3Space.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s.label, style: J3Type.subtitle),
                            const SizedBox(height: 2),
                            Text(s.tagline, style: J3Type.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: J3Space.xs),
                            Text(
                              '${count.toString().padLeft(2, '0')} ${count == 1 ? 'TOOL' : 'TOOLS'}',
                              style: J3Type.code.copyWith(
                                color: context.effects.accentText,
                                fontWeight: FontWeight.w700,
                              ),
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
      ),
    );
  }
}

// ------------------------------------------------------------------ platform

class PlatformPanel extends ConsumerWidget {
  const PlatformPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final caps = ref.watch(capabilitiesProvider);
    final supported = Capability.values.where(caps.supports).length;
    return NeonPanel(
      kicker: '// PLATFORM',
      title: caps.platform.label,
      icon: caps.platform.isMobile ? Icons.smartphone : Icons.desktop_windows_outlined,
      actions: [TextButton(onPressed: () => context.go('/about'), child: const Text('Full matrix'))],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$supported of ${Capability.values.length} capabilities available on this device.',
            style: J3Type.bodySecondary,
          ),
          const SizedBox(height: J3Space.sm),
          TileGrid(
            minTileWidth: 260,
            maxCols: 3,
            children: [
              for (final c in Capability.values)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: J3Space.xs),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        caps.supports(c) ? Icons.check_circle_outline : Icons.remove_circle_outline,
                        size: 16,
                        color: caps.supports(c) ? J3Colors.success : J3Colors.textMuted,
                      ),
                      const SizedBox(width: J3Space.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${c.label}${caps.supports(c) ? '' : ' - not available'}',
                              style: J3Type.caption.copyWith(
                                color: caps.supports(c) ? J3Colors.text : J3Colors.textSecondary,
                              ),
                            ),
                            if (caps.alternativeFor(c) != null)
                              Text(caps.alternativeFor(c)!, style: J3Type.caption.copyWith(fontSize: 11.5)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
