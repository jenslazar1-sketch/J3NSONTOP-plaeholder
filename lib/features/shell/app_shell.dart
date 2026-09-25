import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_info.dart';
import '../../core/activity/activity_controller.dart';
import '../../core/platform/capabilities.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme/effects.dart';
import '../../core/theme/j3_colors.dart';
import '../../core/theme/j3_spacing.dart';
import '../../core/theme/j3_typography.dart';
import '../../core/tools/tool_registry.dart';
import '../../core/widgets/ascii_art.dart';
import '../../core/workspace/workspace_controller.dart';
import '../intro/skull_art.dart';
import '../palette/command_palette.dart';
import 'activity_panel.dart';
import 'destinations.dart';
import 'toast_overlay.dart';
import 'tool_host.dart';

/// Responsive application frame:
/// * >= 1200 px: expanded sidebar, top search bar, optional activity panel;
/// * 600-1200 px: compact rail, top bar, activity in an end drawer;
/// * < 600 px: app bar, bottom navigation, drawer with every section.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.location, required this.child});

  /// Current router location (path + query).
  final String location;
  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>();

  String? get _toolId {
    final path = Uri.parse(widget.location).path;
    if (!path.startsWith('/tool/')) return null;
    return Uri.decodeComponent(path.substring('/tool/'.length));
  }

  void _go(String route) {
    if (_scaffold.currentState?.isDrawerOpen ?? false) Navigator.of(context).pop();
    context.go(route);
  }

  Map<ShortcutActivator, VoidCallback> _shortcuts() {
    return {
      const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => showCommandPalette(context),
      const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () => showCommandPalette(context),
      const SingleActivator(LogicalKeyboardKey.keyP, control: true, shift: true): () => showCommandPalette(context),
      const SingleActivator(LogicalKeyboardKey.backquote, control: true): () => _go(kTerminalRoute),
      const SingleActivator(LogicalKeyboardKey.comma, control: true): () => _go('/settings'),
      const SingleActivator(LogicalKeyboardKey.keyJ, control: true): () =>
          ref.read(settingsProvider.notifier).update((s) => s.copyWith(showActivityPanel: !s.showActivityPanel)),
      for (final d in kDestinations)
        if (d.shortcutDigit != null)
          SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + d.shortcutDigit!), control: true): () =>
              _go(d.route),
    };
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final registry = ref.watch(toolRegistryProvider);
    final toolId = _toolId;
    final tool = toolId == null ? null : registry.byId(toolId);
    final current = destinationFor(Uri.parse(widget.location).path, tool?.section);
    final caps = ref.watch(capabilitiesProvider);
    final showPanelSetting = ref.watch(settingsProvider.select((s) => s.showActivityPanel));

    final content = Stack(
      fit: StackFit.expand,
      children: [
        // Tool pages live in the host and stay alive across navigation.
        ToolHost(activeToolId: toolId),
        if (toolId == null) widget.child,
      ],
    );

    final isCompact = width < J3Breakpoints.compact;
    final isExpanded = width >= J3Breakpoints.expanded;
    final showPanel = isExpanded && showPanelSetting;

    Widget body;
    if (isCompact) {
      body = Scaffold(
        key: _scaffold,
        backgroundColor: Colors.transparent,
        appBar: _CompactAppBar(title: tool?.name ?? current?.label ?? AppInfo.shortName),
        drawer: Drawer(
          child: _NavList(current: current, onSelect: _go, dense: false),
        ),
        endDrawer: const Drawer(width: 340, child: ActivityPanel()),
        body: content,
        bottomNavigationBar: _BottomNav(current: current, onSelect: _go),
      );
    } else {
      body = Scaffold(
        key: _scaffold,
        backgroundColor: Colors.transparent,
        endDrawer: isExpanded ? null : const Drawer(width: 340, child: ActivityPanel()),
        body: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Sidebar(expanded: isExpanded, current: current, onSelect: _go),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TopBar(
                      title: tool?.name ?? current?.label ?? 'Home',
                      section: tool?.section.label,
                      showPanelToggle: isExpanded,
                      panelVisible: showPanel,
                      onActivity: () {
                        if (isExpanded) {
                          ref
                              .read(settingsProvider.notifier)
                              .update((s) => s.copyWith(showActivityPanel: !s.showActivityPanel));
                        } else {
                          _scaffold.currentState?.openEndDrawer();
                        }
                      },
                    ),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: content),
                          if (showPanel)
                            SizedBox(
                              width: J3Size.activityPanel,
                              child: ActivityPanel(
                                onClose: () => ref
                                    .read(settingsProvider.notifier)
                                    .update((s) => s.copyWith(showActivityPanel: false)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final framed = Stack(
      fit: StackFit.expand,
      children: [
        body,
        ToastOverlay(alignment: isCompact ? Alignment.topCenter : Alignment.bottomRight),
      ],
    );

    if (!caps.supports(Capability.keyboardShortcuts)) return framed;
    return CallbackShortcuts(
      bindings: _shortcuts(),
      child: Focus(autofocus: true, child: framed),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.expanded, required this.current, required this.onSelect});
  final bool expanded;
  final NavDestination? current;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    return Container(
      width: expanded ? J3Size.railExpanded : J3Size.railCollapsed,
      decoration: BoxDecoration(
        color: J3Colors.surface.withValues(alpha: 0.94),
        border: Border(right: BorderSide(color: fx.accentColor.withValues(alpha: 0.3))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => onSelect('/'),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: J3Space.md, horizontal: expanded ? J3Space.lg : J3Space.sm),
              child: expanded
                  ? Row(
                      children: [
                        SizedBox(
                          width: 44,
                          child: AsciiArt(
                            lines: const [...kMiniSkullCranium, ...kMiniSkullJaw],
                            style: J3Type.ascii.copyWith(fontSize: 6),
                            semanticLabel: 'J3NSONTOP skull logo',
                          ),
                        ),
                        const SizedBox(width: J3Space.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('J3NSONTOP', style: J3Type.title.copyWith(letterSpacing: 2, color: fx.accentText)),
                              Text('MULTITOOL', style: J3Type.kicker.copyWith(color: J3Colors.textSecondary)),
                            ],
                          ),
                        ),
                      ],
                    )
                  : SizedBox(
                      height: 40,
                      child: AsciiArt(
                        lines: const [...kMiniSkullCranium, ...kMiniSkullJaw],
                        style: J3Type.ascii.copyWith(fontSize: 6),
                        semanticLabel: 'J3NSONTOP skull logo',
                      ),
                    ),
            ),
          ),
          const Divider(),
          Expanded(
            child: _NavList(current: current, onSelect: onSelect, dense: !expanded),
          ),
        ],
      ),
    );
  }
}

class _NavList extends StatelessWidget {
  const _NavList({required this.current, required this.onSelect, required this.dense});
  final NavDestination? current;
  final ValueChanged<String> onSelect;

  /// Icon-only rail with small labels.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[
      for (final d in kDestinations)
        _NavItem(d: d, selected: d == current, dense: dense, onTap: () => onSelect(d.route)),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: J3Space.sm),
        child: Divider(),
      ),
      _NavItem(
        d: const NavDestination(
          label: 'Terminal',
          route: kTerminalRoute,
          icon: Icons.terminal,
          selectedIcon: Icons.terminal,
        ),
        selected: false,
        dense: dense,
        onTap: () => onSelect(kTerminalRoute),
      ),
    ];
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: J3Space.sm),
      children: items,
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({required this.d, required this.selected, required this.dense, required this.onTap});
  final NavDestination d;
  final bool selected;
  final bool dense;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final sel = widget.selected;
    final color = sel ? J3Colors.text : (_hover ? J3Colors.text : J3Colors.textSecondary);
    final icon = Icon(sel ? widget.d.selectedIcon : widget.d.icon, size: 22, color: sel ? fx.accentText : color);
    final tile = AnimatedContainer(
      duration: fx.motion(J3Durations.fast),
      margin: const EdgeInsets.symmetric(horizontal: J3Space.sm, vertical: 2),
      padding: EdgeInsets.symmetric(
        horizontal: widget.dense ? 0 : J3Space.md,
        vertical: widget.dense ? J3Space.sm : 10,
      ),
      decoration: BoxDecoration(
        color: sel ? J3Colors.selection : (_hover ? J3Colors.surfaceRaised : Colors.transparent),
        borderRadius: J3Radius.medium,
        border: Border.all(
          color: _focus ? fx.accentColor : (sel ? fx.accentColor.withValues(alpha: 0.5) : Colors.transparent),
          width: _focus ? 2 : 1,
        ),
        boxShadow: sel && fx.glow
            ? [BoxShadow(color: fx.accentColor.withValues(alpha: 0.18), blurRadius: fx.glowBlur(12))]
            : null,
      ),
      child: widget.dense
          ? Column(
              children: [
                icon,
                const SizedBox(height: 2),
                Text(
                  widget.d.label.split(' ').first,
                  style: J3Type.caption.copyWith(fontSize: 10.5, color: color),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            )
          : Row(
              children: [
                icon,
                const SizedBox(width: J3Space.md),
                Expanded(
                  child: Text(
                    widget.d.label,
                    style: J3Type.label.copyWith(color: color),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.d.shortcutDigit != null && _hover)
                  Text('^${widget.d.shortcutDigit}', style: J3Type.codeSmall.copyWith(fontSize: 10)),
              ],
            ),
    );
    return Semantics(
      selected: sel,
      button: true,
      label: widget.d.label,
      excludeSemantics: true,
      child: Tooltip(
        message: widget.dense ? widget.d.label : '',
        child: FocusableActionDetector(
          onShowHoverHighlight: (h) => setState(() => _hover = h),
          onShowFocusHighlight: (f) => setState(() => _focus = f),
          mouseCursor: SystemMouseCursors.click,
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap())},
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onTap, child: tile),
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({
    required this.title,
    required this.section,
    required this.showPanelToggle,
    required this.panelVisible,
    required this.onActivity,
  });

  final String title;
  final String? section;
  final bool showPanelToggle;
  final bool panelVisible;
  final VoidCallback onActivity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fx = context.effects;
    final running = ref.watch(activityProvider.select((s) => s.running.length));
    return Container(
      height: J3Size.topBar,
      padding: const EdgeInsets.symmetric(horizontal: J3Space.lg),
      decoration: BoxDecoration(
        color: J3Colors.background.withValues(alpha: 0.85),
        border: Border(bottom: BorderSide(color: fx.accentColor.withValues(alpha: 0.25))),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (section != null)
                  Text(
                    '// ${section!.toUpperCase()}',
                    style: J3Type.kicker.copyWith(fontSize: 10, color: fx.accentText),
                  ),
                Text(title, style: J3Type.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: J3Space.md),
          Expanded(flex: 4, child: _SearchLauncher()),
          const SizedBox(width: J3Space.md),
          const WorkspaceChip(),
          const SizedBox(width: J3Space.xs),
          Badge(
            isLabelVisible: running > 0,
            label: Text('$running'),
            backgroundColor: fx.accentColor,
            child: IconButton(
              tooltip: showPanelToggle
                  ? (panelVisible ? 'Hide activity (Ctrl+J)' : 'Show activity (Ctrl+J)')
                  : 'Activity',
              onPressed: onActivity,
              isSelected: panelVisible,
              icon: Icon(panelVisible ? Icons.view_sidebar : Icons.view_sidebar_outlined),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchLauncher extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    return Semantics(
      button: true,
      label: 'Search tools (Ctrl+K)',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: J3Radius.medium,
        onTap: () => showCommandPalette(context),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: J3Space.md),
          decoration: BoxDecoration(
            color: J3Colors.inputFill,
            borderRadius: J3Radius.medium,
            border: Border.all(color: J3Colors.border),
          ),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: fx.accentText),
              const SizedBox(width: J3Space.sm),
              Expanded(
                child: Text('Search tools and actions', style: J3Type.bodySecondary, overflow: TextOverflow.ellipsis),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: J3Radius.small,
                  border: Border.all(color: J3Colors.borderStrong),
                ),
                child: Text('Ctrl+K', style: J3Type.codeSmall.copyWith(fontSize: 10.5)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows and switches the active workspace from anywhere.
class WorkspaceChip extends ConsumerWidget {
  const WorkspaceChip({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workspacesProvider);
    final active = state.active;
    final fx = context.effects;
    return PopupMenuButton<String>(
      tooltip: 'Switch workspace',
      onSelected: (v) {
        if (v == '__manage') {
          context.go('/workspaces');
        } else {
          ref.read(workspacesProvider.notifier).setActive(v);
        }
      },
      itemBuilder: (context) => [
        for (final w in state.recent)
          PopupMenuItem(
            value: w.id,
            child: Row(
              children: [
                Icon(
                  w.id == state.activeId ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 16,
                  color: fx.accentText,
                ),
                const SizedBox(width: J3Space.sm),
                Expanded(child: Text(w.name, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: J3Space.sm),
                Text(w.kind.label, style: J3Type.caption),
              ],
            ),
          ),
        if (state.workspaces.isNotEmpty) const PopupMenuDivider(),
        const PopupMenuItem(value: '__manage', child: Text('Manage workspaces...')),
      ],
      child: Container(
        constraints: BoxConstraints(maxWidth: compact ? 140 : 220),
        padding: const EdgeInsets.symmetric(horizontal: J3Space.sm, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: J3Radius.medium,
          border: Border.all(color: active == null ? J3Colors.border : fx.accentColor.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_special_outlined, size: 16, color: fx.accentText),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                active?.name ?? 'No workspace',
                style: J3Type.caption.copyWith(color: J3Colors.text),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }
}

class _CompactAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const _CompactAppBar({required this.title});
  final String title;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(activityProvider.select((s) => s.running.length));
    final fx = context.effects;
    return AppBar(
      titleSpacing: 0,
      title: Text(title, overflow: TextOverflow.ellipsis),
      shape: Border(bottom: BorderSide(color: fx.accentColor.withValues(alpha: 0.25))),
      actions: [
        IconButton(tooltip: 'Search', onPressed: () => showCommandPalette(context), icon: const Icon(Icons.search)),
        const WorkspaceChip(compact: true),
        Builder(
          builder: (ctx) => Badge(
            isLabelVisible: running > 0,
            label: Text('$running'),
            backgroundColor: fx.accentColor,
            child: IconButton(
              tooltip: 'Activity',
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
              icon: const Icon(Icons.monitor_heart_outlined),
            ),
          ),
        ),
      ],
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.current, required this.onSelect});
  final NavDestination? current;
  final ValueChanged<String> onSelect;

  static const _routes = ['/', '/workspaces', '/mods', '/tools', '/activity'];

  @override
  Widget build(BuildContext context) {
    final route = current?.route;
    var index = _routes.indexOf(route ?? '');
    // Sections without their own tab highlight "Tools".
    if (index < 0 && current != null && current!.section != null) index = 3;
    if (index < 0) index = route == '/settings' ? -1 : 0;
    return NavigationBar(
      selectedIndex: index < 0 ? 0 : index,
      onDestinationSelected: (i) => onSelect(_routes[i]),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: const [
        NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Home'),
        NavigationDestination(
          icon: Icon(Icons.folder_open_outlined),
          selectedIcon: Icon(Icons.folder_open),
          label: 'Workspaces',
        ),
        NavigationDestination(icon: Icon(Icons.extension_outlined), selectedIcon: Icon(Icons.extension), label: 'Mods'),
        NavigationDestination(icon: Icon(Icons.apps_outlined), selectedIcon: Icon(Icons.apps), label: 'Tools'),
        NavigationDestination(
          icon: Icon(Icons.monitor_heart_outlined),
          selectedIcon: Icon(Icons.monitor_heart),
          label: 'Activity',
        ),
      ],
    );
  }
}
