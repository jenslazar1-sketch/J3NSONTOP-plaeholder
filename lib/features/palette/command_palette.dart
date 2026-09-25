import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/commands/terminal_command.dart';
import '../../core/drafts/drafts.dart';
import '../../core/platform/capabilities.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/storage/user_data.dart';
import '../../core/theme/effects.dart';
import '../../core/theme/j3_colors.dart';
import '../../core/theme/j3_spacing.dart';
import '../../core/theme/j3_typography.dart';
import '../../core/tools/tool_registry.dart';
import '../shell/destinations.dart';

/// `draftValueProvider` key through which the palette hands a command line
/// to the terminal, which consumes (resets) it and runs it once. Features do
/// not import each other, so this shared core draft key is the contract; it
/// equals the terminal's `kTerminalPendingCommandKey` (verified by a test).
const String kPaletteTerminalRequestKey = 'system.terminal/pending';

/// One selectable palette row.
class PaletteEntry {
  const PaletteEntry({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.kind,
    this.run,
    this.fillQuery,
    this.completion,
    this.titlePrefix,
    this.shortcut,
    this.route,
    this.keywords = const [],
  }) : assert(run != null || fillQuery != null, 'An entry must run something or fill the query');

  /// Main title; the part that is matched and highlighted.
  final String title;

  /// Muted text before the title, e.g. "Run in terminal: ".
  final String? titlePrefix;
  final String subtitle;
  final IconData icon;

  /// "TOOL", "GO TO", "ACTION", "RECENT", "FAVORITE", "RUN".
  final String kind;
  final List<String> keywords;

  /// Keyboard shortcut hint shown as a keycap on keyboard platforms.
  final String? shortcut;

  /// Runs the entry after the palette closed.
  final void Function(GoRouter router, WidgetRef ref)? run;

  /// Instead of running: replace the query with this text and stay open.
  final String? fillQuery;

  /// Query text inserted by Tab (terminal command mode).
  final String? completion;

  /// Route the entry opens, if any (used to avoid duplicate rows).
  final String? route;
}

/// Splits [text] into spans, marking every case-insensitive occurrence of
/// [terms] with [match].
List<TextSpan> highlightMatches(String text, List<String> terms, {required TextStyle base, required TextStyle match}) {
  final lower = text.toLowerCase();
  if (lower.length != text.length) return [TextSpan(text: text, style: base)];
  final marks = List<bool>.filled(text.length, false);
  for (final t in terms) {
    final term = t.toLowerCase();
    if (term.isEmpty) continue;
    var i = lower.indexOf(term);
    while (i >= 0) {
      for (var j = i; j < i + term.length; j++) {
        marks[j] = true;
      }
      i = lower.indexOf(term, i + term.length);
    }
  }
  final spans = <TextSpan>[];
  var start = 0;
  for (var i = 1; i <= text.length; i++) {
    if (i == text.length || marks[i] != marks[start]) {
      spans.add(TextSpan(text: text.substring(start, i), style: marks[start] ? match : base));
      start = i;
    }
  }
  return spans;
}

/// Opens the searchable command palette. Queries starting with `>` list
/// terminal commands ("Run in terminal: ...").
Future<void> showCommandPalette(BuildContext context, {String initialQuery = ''}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close command palette',
    barrierColor: Colors.black.withValues(alpha: 0.6),
    transitionDuration: context.effects.motion(const Duration(milliseconds: 160)),
    pageBuilder: (ctx, _, _) => CommandPalette(initialQuery: initialQuery),
    transitionBuilder: (ctx, anim, _, child) => FadeTransition(
      opacity: anim,
      child: ScaleTransition(scale: Tween(begin: 0.98, end: 1.0).animate(anim), child: child),
    ),
  );
}

/// The palette dialog body (use [showCommandPalette] to open it).
class CommandPalette extends ConsumerStatefulWidget {
  const CommandPalette({super.key, this.initialQuery = ''});
  final String initialQuery;

  /// Placeholder of the search field (tests use it to find the open palette).
  static const hintText = 'Search tools and actions, or > for commands';

  @override
  ConsumerState<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<CommandPalette> {
  late final TextEditingController _query = TextEditingController(text: widget.initialQuery);
  final FocusNode _focus = FocusNode(debugLabel: 'palette query');
  final ScrollController _scroll = ScrollController();
  int _index = 0;
  double _rowExtent = 60;

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _commandMode => _query.text.trimLeft().startsWith('>');

  /// Command line typed after `>`.
  String get _commandLine => _commandMode ? _query.text.trimLeft().substring(1).trim() : '';

  List<String> get _terms {
    if (_commandMode) {
      final first = _commandLine.split(RegExp(r'\s+')).first;
      return first.isEmpty ? const [] : [first];
    }
    return _query.text.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  }

  List<PaletteEntry> _staticEntries() => [
    for (final d in kDestinations)
      PaletteEntry(
        title: d.label,
        subtitle: 'Go to ${d.label}',
        icon: d.icon,
        kind: 'GO TO',
        keywords: [d.route],
        route: d.route,
        shortcut: d.shortcutDigit != null ? 'Ctrl+${d.shortcutDigit}' : null,
        run: (router, r) => router.go(d.route),
      ),
    PaletteEntry(
      title: 'Terminal',
      subtitle: "Typed command interface for the app's own tools (not a system shell)",
      icon: Icons.terminal,
      kind: 'GO TO',
      keywords: const ['command', 'console', 'cli'],
      shortcut: 'Ctrl+`',
      route: kTerminalRoute,
      run: (router, r) => router.go(kTerminalRoute),
    ),
    const PaletteEntry(
      title: 'Run a terminal command',
      subtitle: 'Type > followed by a command, e.g. > help',
      icon: Icons.chevron_right,
      kind: 'ACTION',
      keywords: ['>', 'command', 'terminal', 'run', 'cli'],
      shortcut: '>',
      fillQuery: '> ',
    ),
    PaletteEntry(
      title: 'About',
      subtitle: 'Version, licenses and credits',
      icon: Icons.info_outline,
      kind: 'GO TO',
      keywords: const ['version', 'license', 'credits'],
      route: '/about',
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
    if (_commandMode) return _commandEntries(_commandLine);
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
        route: t.route,
        shortcut: t.route == kTerminalRoute ? 'Ctrl+`' : null,
        run: (router, r) => router.go(t.route),
      );
    }

    if (q.isEmpty) {
      return _withoutDuplicateRoutes([
        for (final id in user.favorites)
          if (registry.byId(id)?.availableOn(caps) ?? false) toolEntry(id, 'FAVORITE'),
        for (final r in user.recentTools)
          if (!user.favorites.contains(r.toolId) && (registry.byId(r.toolId)?.availableOn(caps) ?? false))
            toolEntry(r.toolId, 'RECENT'),
        ..._staticEntries(),
      ]);
    }
    final tools = [for (final m in registry.search(q, caps: caps)) toolEntry(m.tool.id, 'TOOL')];
    final statics = _staticEntries().where((e) {
      final hay = '${e.title} ${e.subtitle} ${e.keywords.join(' ')}'.toLowerCase();
      return q.split(RegExp(r'\s+')).every(hay.contains);
    });
    return _withoutDuplicateRoutes([...tools, ...statics]);
  }

  /// Keeps the first entry for each route (e.g. the Terminal tool found by
  /// search and the static "Terminal" shortcut).
  static List<PaletteEntry> _withoutDuplicateRoutes(List<PaletteEntry> entries) {
    final seen = <String>{};
    return [
      for (final e in entries)
        if (e.route == null || seen.add(e.route!)) e,
    ];
  }

  /// `>` mode: registered terminal commands.
  List<PaletteEntry> _commandEntries(String line) {
    final registry = ref.read(toolRegistryProvider);
    final tokens = line.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final first = tokens.isEmpty ? '' : tokens.first;
    final exact = first.isEmpty ? null : (registry.command(first) ?? registry.command(first.toLowerCase()));

    PaletteEntry entry(String commandLine, TerminalCommand c, {String? completion}) => PaletteEntry(
      titlePrefix: 'Run in terminal: ',
      title: commandLine,
      subtitle: '${c.summary}  |  ${c.usage}',
      icon: Icons.terminal,
      kind: 'RUN',
      completion: completion,
      run: (router, r) {
        r.read(draftValueProvider(kPaletteTerminalRequestKey).notifier).set(commandLine);
        router.go(kTerminalRoute);
      },
    );

    final out = <PaletteEntry>[];
    if (exact != null) {
      out.add(entry(line, exact, completion: tokens.length == 1 ? '> ${exact.name} ' : null));
    }
    if (tokens.length <= 1) {
      final lower = first.toLowerCase();
      final prefix = <TerminalCommand>[];
      final contains = <TerminalCommand>[];
      for (final c in registry.commands) {
        if (c.hidden || identical(c, exact)) continue;
        final names = [c.name, ...c.aliases].map((n) => n.toLowerCase());
        if (lower.isEmpty || names.any((n) => n.startsWith(lower))) {
          prefix.add(c);
        } else if (names.any((n) => n.contains(lower)) || c.summary.toLowerCase().contains(lower)) {
          contains.add(c);
        }
      }
      for (final c in [...prefix, ...contains]) {
        out.add(entry(c.name, c, completion: '> ${c.name} '));
      }
    }
    return out;
  }

  void _activate(PaletteEntry e) {
    final fill = e.fillQuery;
    if (fill != null) {
      _setQuery(fill);
      return;
    }
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    e.run!(router, ref);
  }

  void _setQuery(String text) {
    _query.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() => _index = 0);
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event, List<PaletteEntry> entries) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
      if (entries.isNotEmpty) {
        final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
        setState(() => _index = (_index + delta).clamp(0, entries.length - 1));
        _ensureVisible();
      }
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (entries.isNotEmpty) _activate(entries[_index.clamp(0, entries.length - 1)]);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab && !HardwareKeyboard.instance.isShiftPressed && entries.isNotEmpty) {
      final completion = entries[_index.clamp(0, entries.length - 1)].completion;
      if (completion != null) {
        _setQuery(completion);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _ensureVisible() {
    if (!_scroll.hasClients) return;
    final top = _index * _rowExtent;
    final view = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _rowExtent > _scroll.offset + view) {
      _scroll.jumpTo(top + _rowExtent - view);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final entries = _entries();
    if (_index >= entries.length) _index = entries.isEmpty ? 0 : entries.length - 1;
    final size = MediaQuery.sizeOf(context);
    final scaler = MediaQuery.textScalerOf(context);
    _rowExtent = math.max(60.0, scaler.scale(14) * 1.2 + scaler.scale(12.5) * 1.3 + 22);
    final keyboard = ref.watch(capabilitiesProvider).supports(Capability.keyboardShortcuts);
    final showKeycaps = keyboard && size.width >= 480;
    final commandMode = _commandMode;
    final terms = _terms;

    final String empty;
    if (commandMode) {
      empty = _commandLine.isEmpty
          ? 'No terminal commands are registered.'
          : 'No terminal command matches "$_commandLine". Try "> help".';
    } else {
      empty = 'No match for "${_query.text}"';
    }
    final footer = keyboard
        ? '${entries.length} results  |  Up/Down select  |  Enter ${commandMode ? 'run' : 'open'}'
              '${commandMode ? '  |  Tab complete' : '  |  > terminal commands'}  |  Esc close'
        : '${entries.length} results  |  tap to ${commandMode ? 'run' : 'open'}'
              '${commandMode ? '' : '  |  type > for terminal commands'}';

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
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: (n, e) => _onKey(n, e, entries),
                    child: Padding(
                      padding: const EdgeInsets.all(J3Space.md),
                      child: TextField(
                        controller: _query,
                        focusNode: _focus,
                        autofocus: true,
                        style: commandMode ? J3Type.code.copyWith(color: J3Colors.text) : J3Type.body,
                        autocorrect: false,
                        enableSuggestions: false,
                        smartQuotesType: SmartQuotesType.disabled,
                        smartDashesType: SmartDashesType.disabled,
                        textInputAction: TextInputAction.go,
                        onSubmitted: (_) {
                          if (entries.isNotEmpty) _activate(entries[_index.clamp(0, entries.length - 1)]);
                        },
                        onChanged: (_) => setState(() => _index = 0),
                        decoration: InputDecoration(
                          prefixIcon: Icon(commandMode ? Icons.terminal : Icons.search, color: fx.accentText),
                          hintText: CommandPalette.hintText,
                          suffixIcon: IconButton(
                            tooltip: keyboard ? 'Close (Esc)' : 'Close',
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close),
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
                            child: Text(empty, style: J3Type.bodySecondary, textAlign: TextAlign.center),
                          )
                        : ListView.builder(
                            controller: _scroll,
                            shrinkWrap: true,
                            itemExtent: _rowExtent,
                            itemCount: entries.length,
                            itemBuilder: (context, i) => _row(entries[i], i, terms, showKeycaps),
                          ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: J3Space.lg, vertical: J3Space.sm),
                    color: J3Colors.surfaceRaised,
                    child: Text(footer, style: J3Type.codeSmall.copyWith(fontSize: 11)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(PaletteEntry e, int i, List<String> terms, bool showKeycaps) {
    final fx = context.effects;
    final selected = i == _index;
    final base = J3Type.label;
    final match = J3Type.label.copyWith(
      color: fx.accentText,
      fontWeight: FontWeight.w700,
      decoration: TextDecoration.underline,
      decorationColor: fx.accentText,
    );
    return Semantics(
      selected: selected,
      child: InkWell(
        onTap: () => _activate(e),
        onHover: (h) {
          if (h && _index != i) setState(() => _index = i);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: J3Space.lg),
          decoration: BoxDecoration(
            color: selected ? J3Colors.selection : null,
            border: Border(left: BorderSide(color: selected ? fx.accentColor : Colors.transparent, width: 3)),
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
                    Text.rich(
                      TextSpan(
                        children: [
                          if (e.titlePrefix != null)
                            TextSpan(
                              text: e.titlePrefix,
                              style: base.copyWith(color: J3Colors.textSecondary, fontWeight: FontWeight.w500),
                            ),
                          ...highlightMatches(e.title, terms, base: base, match: match),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(e.subtitle, style: J3Type.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              if (showKeycaps && e.shortcut != null) ...[
                const SizedBox(width: J3Space.sm),
                _Keycap(label: e.shortcut!),
              ],
              const SizedBox(width: J3Space.sm),
              Text(
                e.kind,
                style: J3Type.codeSmall.copyWith(fontSize: 10, color: selected ? fx.accentText : J3Colors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A keyboard shortcut hint, e.g. `Ctrl+K`.
class _Keycap extends StatelessWidget {
  const _Keycap({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Shortcut $label',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: J3Colors.surfaceRaised,
          borderRadius: J3Radius.small,
          border: Border.all(color: J3Colors.borderStrong),
        ),
        child: Text(label, style: J3Type.codeSmall.copyWith(fontSize: 10.5)),
      ),
    );
  }
}
