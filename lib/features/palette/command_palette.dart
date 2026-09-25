import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/platform/capabilities.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/storage/user_data.dart';
import '../../core/theme/effects.dart';
import '../../core/theme/j3_colors.dart';
import '../../core/theme/j3_spacing.dart';
import '../../core/theme/j3_typography.dart';
import '../../core/tools/tool_registry.dart';
import '../shell/destinations.dart';

/// One selectable palette row.
class PaletteEntry {
  const PaletteEntry({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.kind,
    required this.run,
    this.keywords = const [],
  });

  final String title;
  final String subtitle;
  final IconData icon;

  /// "TOOL", "GO TO", "ACTION", "RECENT", "FAVORITE".
  final String kind;
  final List<String> keywords;
  final void Function(GoRouter router, WidgetRef ref) run;
}

/// Opens the searchable command palette.
Future<void> showCommandPalette(BuildContext context, {String initialQuery = ''}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close command palette',
    barrierColor: Colors.black.withValues(alpha: 0.6),
    transitionDuration: context.effects.motion(const Duration(milliseconds: 160)),
    pageBuilder: (ctx, _, _) => _CommandPalette(initialQuery: initialQuery),
    transitionBuilder: (ctx, anim, _, child) => FadeTransition(
      opacity: anim,
      child: ScaleTransition(scale: Tween(begin: 0.98, end: 1.0).animate(anim), child: child),
    ),
  );
}

class _CommandPalette extends ConsumerStatefulWidget {
  const _CommandPalette({required this.initialQuery});
  final String initialQuery;

  @override
  ConsumerState<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<_CommandPalette> {
  late final TextEditingController _query = TextEditingController(text: widget.initialQuery);
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();
  int _index = 0;

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<PaletteEntry> _staticEntries() => [
    for (final d in kDestinations)
      PaletteEntry(
        title: d.label,
        subtitle: 'Go to ${d.label}${d.shortcutDigit != null ? '  (Ctrl+${d.shortcutDigit})' : ''}',
        icon: d.icon,
        kind: 'GO TO',
        keywords: [d.route],
        run: (router, r) => router.go(d.route),
      ),
    PaletteEntry(
      title: 'Terminal',
      subtitle: 'Typed command interface for the app\'s tools  (Ctrl+`)',
      icon: Icons.terminal,
      kind: 'GO TO',
      keywords: const ['command', 'console', 'cli'],
      run: (router, r) => router.go(kTerminalRoute),
    ),
    PaletteEntry(
      title: 'About',
      subtitle: 'Version, licenses and credits',
      icon: Icons.info_outline,
      kind: 'GO TO',
      keywords: const ['version', 'license', 'credits'],
      run: (router, r) => router.go('/about'),
    ),
    PaletteEntry(
      title: 'Replay intro',
      subtitle: 'Watch the laughing skull again',
      icon: Icons.replay,
      kind: 'ACTION',
      keywords: const ['skull', 'splash', 'animation'],
      run: (router, r) => router.go('/intro?replay=1'),
    ),
    PaletteEntry(
      title: 'Toggle low-effects mode',
      subtitle: 'Disable scanlines, particles, bloom and glitches',
      icon: Icons.blur_off,
      kind: 'ACTION',
      keywords: const ['performance', 'effects', 'battery', 'accessibility'],
      run: (router, r) => r.read(settingsProvider.notifier).update((s) => s.copyWith(lowEffects: !s.lowEffects)),
    ),
    PaletteEntry(
      title: 'Toggle sound',
      subtitle: 'Optional interface and intro sounds',
      icon: Icons.volume_up_outlined,
      kind: 'ACTION',
      keywords: const ['mute', 'audio'],
      run: (router, r) => r.read(settingsProvider.notifier).update((s) => s.copyWith(sound: !s.sound)),
    ),
  ];

  List<PaletteEntry> _entries() {
    final registry = ref.read(toolRegistryProvider);
    final caps = ref.read(capabilitiesProvider);
    final user = ref.read(userDataProvider);
    final q = _query.text.trim().toLowerCase();

    PaletteEntry toolEntry(String id, String kind) {
      final t = registry.byId(id)!;
      return PaletteEntry(
        title: t.name,
        subtitle: '${t.section.label}  |  ${t.description}',
        icon: t.icon,
        kind: kind,
        run: (router, r) => router.go(t.route),
      );
    }

    if (q.isEmpty) {
      return [
        for (final id in user.favorites)
          if (registry.byId(id)?.availableOn(caps) ?? false) toolEntry(id, 'FAVORITE'),
        for (final r in user.recentTools)
          if (!user.favorites.contains(r.toolId) && (registry.byId(r.toolId)?.availableOn(caps) ?? false))
            toolEntry(r.toolId, 'RECENT'),
        ..._staticEntries(),
      ];
    }
    final tools = [for (final m in registry.search(q, caps: caps)) toolEntry(m.tool.id, 'TOOL')];
    final statics = _staticEntries().where((e) {
      final hay = '${e.title} ${e.subtitle} ${e.keywords.join(' ')}'.toLowerCase();
      return q.split(RegExp(r'\s+')).every(hay.contains);
    });
    return [...tools, ...statics];
  }

  void _run(PaletteEntry e) {
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    e.run(router, ref);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event, List<PaletteEntry> entries) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _index = (_index + 1).clamp(0, entries.length - 1));
      _ensureVisible();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _index = (_index - 1).clamp(0, entries.length - 1));
      _ensureVisible();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (entries.isNotEmpty) _run(entries[_index.clamp(0, entries.length - 1)]);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _ensureVisible() {
    if (!_scroll.hasClients) return;
    const rowHeight = 60.0;
    final top = _index * rowHeight;
    final view = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + rowHeight > _scroll.offset + view) {
      _scroll.jumpTo(top + rowHeight - view);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final entries = _entries();
    if (_index >= entries.length) _index = entries.isEmpty ? 0 : entries.length - 1;
    final size = MediaQuery.sizeOf(context);
    return SafeArea(
      child: Align(
        alignment: const Alignment(0, -0.6),
        child: Padding(
          padding: const EdgeInsets.all(J3Space.lg),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 680, maxHeight: size.height * 0.75),
            child: Material(
              color: J3Colors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: J3Radius.large,
                side: BorderSide(color: fx.accentColor.withValues(alpha: 0.8)),
              ),
              elevation: 12,
              shadowColor: fx.accentColor.withValues(alpha: 0.5),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Focus(
                    onKeyEvent: (n, e) => _onKey(n, e, entries),
                    child: Padding(
                      padding: const EdgeInsets.all(J3Space.md),
                      child: TextField(
                        controller: _query,
                        focusNode: _focus,
                        autofocus: true,
                        style: J3Type.body,
                        onChanged: (_) => setState(() => _index = 0),
                        decoration: InputDecoration(
                          prefixIcon: Icon(Icons.search, color: fx.accentText),
                          hintText: 'Search tools, sections and actions...',
                          suffixIcon: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text('ESC', style: J3Type.codeSmall.copyWith(color: J3Colors.textMuted)),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Divider(),
                  Flexible(
                    child: entries.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(J3Space.xl),
                            child: Text(
                              'No match for "${_query.text}"',
                              style: J3Type.bodySecondary,
                              textAlign: TextAlign.center,
                            ),
                          )
                        : ListView.builder(
                            controller: _scroll,
                            shrinkWrap: true,
                            itemExtent: 60,
                            itemCount: entries.length,
                            itemBuilder: (context, i) {
                              final e = entries[i];
                              final selected = i == _index;
                              return InkWell(
                                onTap: () => _run(e),
                                onHover: (h) {
                                  if (h) setState(() => _index = i);
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: J3Space.lg),
                                  decoration: BoxDecoration(
                                    color: selected ? J3Colors.selection : null,
                                    border: Border(
                                      left: BorderSide(color: selected ? fx.accentColor : Colors.transparent, width: 3),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(e.icon, size: 20, color: selected ? fx.accentText : J3Colors.textSecondary),
                                      const SizedBox(width: J3Space.md),
                                      Expanded(
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              e.title,
                                              style: J3Type.label,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            Text(
                                              e.subtitle,
                                              style: J3Type.caption,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: J3Space.sm),
                                      Text(
                                        e.kind,
                                        style: J3Type.codeSmall.copyWith(
                                          fontSize: 10,
                                          color: selected ? fx.accentText : J3Colors.textMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: J3Space.lg, vertical: J3Space.sm),
                    color: J3Colors.surfaceRaised,
                    child: Text(
                      '${entries.length} results   |   Up/Down select   |   Enter open   |   Esc close',
                      style: J3Type.codeSmall.copyWith(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
