import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_info.dart';
import '../../core/activity/activity_controller.dart';
import '../../core/platform/capabilities.dart';
import '../../core/theme/effects.dart';
import '../../core/theme/j3_colors.dart';
import '../../core/theme/j3_spacing.dart';
import '../../core/theme/j3_typography.dart';
import '../../core/widgets/widgets.dart';
import '../intro/skull_art.dart';

/// Remembers that the hero title already glitched in this app session, so
/// the effect plays once on first show and not on every return to Home.
class HeroGlitchPlayed extends Notifier<bool> {
  @override
  bool build() => false;

  void mark() => state = true;
}

final heroGlitchPlayedProvider = NotifierProvider<HeroGlitchPlayed, bool>(HeroGlitchPlayed.new);

/// Message posted when the skull easter egg is found.
const String kSkullLaughNotice = 'HA HA HA — you found the skull';

/// Dashboard hero: full product name, mini skull logo (with its easter egg)
/// and the live system line.
class HomeHero extends ConsumerStatefulWidget {
  const HomeHero({super.key});

  @override
  ConsumerState<HomeHero> createState() => _HomeHeroState();
}

class _HomeHeroState extends ConsumerState<HomeHero> {
  late final bool _glitchOnMount;

  @override
  void initState() {
    super.initState();
    _glitchOnMount = !ref.read(heroGlitchPlayedProvider);
    if (_glitchOnMount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(heroGlitchPlayedProvider.notifier).mark();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final caps = ref.watch(capabilitiesProvider);
    final running = ref.watch(activityProvider.select((s) => s.running.length));

    return NeonPanel(
      emphasis: PanelEmphasis.strong,
      padding: EdgeInsets.zero,
      child: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 760;
          final titleSize = wide ? 50.0 : (c.maxWidth >= 480 ? 40.0 : 32.0);
          final name = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (i, line) in AppInfo.fullNameLines.indexed)
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: GlitchText(
                    line,
                    glitchOnMount: _glitchOnMount,
                    style: J3Type.display.copyWith(
                      fontSize: titleSize,
                      height: 1.02,
                      letterSpacing: i == 0 ? 6 : 4,
                      color: i == 0 ? fx.accentText : J3Colors.text,
                      shadows: i == 0 && fx.glow
                          ? [Shadow(color: fx.accentColor.withValues(alpha: 0.75), blurRadius: fx.glowBlur(24))]
                          : null,
                    ),
                  ),
                ),
            ],
          );

          final statusLine = Wrap(
            spacing: J3Space.md,
            runSpacing: J3Space.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const LiveIndicator(),
                  const SizedBox(width: J3Space.sm),
                  Flexible(
                    child: Text(AppInfo.tagline, style: J3Type.kicker.copyWith(color: J3Colors.success)),
                  ),
                ],
              ),
              Text(
                'v${AppInfo.version}  |  ${caps.platform.label}  |  '
                '${running == 0 ? 'idle' : '$running running'}',
                style: J3Type.codeSmall,
              ),
            ],
          );

          final skull = MiniLaughingSkull(
            size: wide ? 132 : 92,
            onLaugh: () => ref.read(activityProvider.notifier).notify(NoticeKind.info, kSkullLaughNotice),
          );

          final body = wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    skull,
                    const SizedBox(width: J3Space.xl),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          name,
                          const SizedBox(height: J3Space.md),
                          statusLine,
                        ],
                      ),
                    ),
                    const SizedBox(width: J3Space.xl),
                    const SizedBox(width: 240, child: CosmeticBootLog()),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(alignment: Alignment.centerLeft, child: skull),
                    const SizedBox(height: J3Space.md),
                    name,
                    const SizedBox(height: J3Space.md),
                    statusLine,
                  ],
                );

          return Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: J3Radius.medium,
                    child: CustomPaint(
                      painter: _HeroGridPainter(color: fx.accentColor, strength: 0.4 + 0.6 * fx.intensity),
                    ),
                  ),
                ),
              ),
              Padding(padding: EdgeInsets.all(wide ? J3Space.xl : J3Space.lg), child: body),
            ],
          );
        },
      ),
    );
  }
}

/// Faint diagonal rule lines behind the hero (static).
class _HeroGridPainter extends CustomPainter {
  _HeroGridPainter({required this.color, required this.strength});
  final Color color;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.8, -0.6),
          radius: 1.3,
          colors: [
            color.withValues(alpha: 0.10 * strength),
            Colors.transparent,
          ],
        ).createShader(rect),
    );
    final line = Paint()
      ..color = color.withValues(alpha: 0.05 * strength)
      ..strokeWidth = 1;
    for (double x = -size.height; x < size.width; x += 18) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), line);
    }
  }

  @override
  bool shouldRepaint(_HeroGridPainter old) => old.color != color || old.strength != strength;
}

/// Pulsing "online" dot. Static when motion is reduced or effects are off.
class LiveIndicator extends StatefulWidget {
  const LiveIndicator({super.key});

  @override
  State<LiveIndicator> createState() => _LiveIndicatorState();
}

class _LiveIndicatorState extends State<LiveIndicator> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.effects.decorativeMotion) {
      if (!_c.isAnimating) _c.repeat(reverse: true);
    } else {
      _c
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = 0.45 + 0.55 * _c.value;
          return Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: J3Colors.success.withValues(alpha: t),
              boxShadow: fx.glow
                  ? [
                      BoxShadow(
                        color: J3Colors.success.withValues(alpha: 0.6 * t),
                        blurRadius: fx.glowBlur(10),
                      ),
                    ]
                  : null,
            ),
          );
        },
      ),
    );
  }
}

/// Decorative boot text. Clearly labelled as cosmetic, excluded from
/// screen readers, static, and deliberately silly so it is never mistaken
/// for real status.
class CosmeticBootLog extends StatelessWidget {
  const CosmeticBootLog({super.key});

  static const List<String> lines = [
    '> neon bus .......... lit',
    '> skull humour ...... loaded',
    '> sarcasm filter .... off',
    '> coffee level ...... critical',
  ];

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.all(J3Space.sm),
        decoration: BoxDecoration(
          color: J3Colors.background.withValues(alpha: 0.6),
          borderRadius: J3Radius.small,
          border: Border.all(color: J3Colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('// cosmetic - not real activity', style: J3Type.codeSmall.copyWith(fontSize: 10.5)),
            const SizedBox(height: J3Space.xs),
            for (final l in lines)
              Text(
                l,
                style: J3Type.codeSmall.copyWith(fontSize: 11, color: J3Colors.textMuted),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
              ),
          ],
        ),
      ),
    );
  }
}

/// The compact skull logo. Five quick taps (or Enter presses) make it laugh:
/// the jaw layer drops and closes three times while the eyes light up. With
/// reduced motion only the eyes flash. [onLaugh] fires once per laugh.
class MiniLaughingSkull extends StatefulWidget {
  const MiniLaughingSkull({super.key, required this.onLaugh, this.size = 88});

  final VoidCallback onLaugh;

  /// Width of the logo in logical pixels.
  final double size;

  static const int tapsToLaugh = 5;
  static const Duration tapWindow = Duration(milliseconds: 1800);
  static const Duration laughDuration = Duration(milliseconds: 1200);

  @override
  State<MiniLaughingSkull> createState() => _MiniLaughingSkullState();
}

class _MiniLaughingSkullState extends State<MiniLaughingSkull> with SingleTickerProviderStateMixin {
  late final AnimationController _laugh = AnimationController(vsync: this, duration: MiniLaughingSkull.laughDuration);
  final List<DateTime> _taps = [];
  bool _focus = false;
  bool _hover = false;

  static const double _font = 10;
  static const List<int> _eyeRows = [2, 3];
  static const List<int> _eyeCols = [3, 9];

  @override
  void dispose() {
    _laugh.dispose();
    super.dispose();
  }

  void _tap() {
    final now = DateTime.now();
    _taps
      ..add(now)
      ..removeWhere((t) => now.difference(t) > MiniLaughingSkull.tapWindow);
    if (_taps.length >= MiniLaughingSkull.tapsToLaugh && !_laugh.isAnimating) {
      _taps.clear();
      _laugh.forward(from: 0);
      widget.onLaugh();
    }
  }

  /// Splits the cranium into the steady layer (eye pupils blanked) and an
  /// eye layer on the same grid, so lit eyes can be drawn in another colour
  /// without disturbing column alignment.
  static (List<String>, List<String>) _eyeLayers() {
    final width = kMiniSkullCranium.fold<int>(0, (m, l) => math.max(m, l.length));
    final base = <String>[];
    final eyes = <String>[];
    for (var r = 0; r < kMiniSkullCranium.length; r++) {
      final line = kMiniSkullCranium[r].padRight(width).split('');
      final eye = List.filled(width, ' ');
      if (_eyeRows.contains(r)) {
        for (final c in _eyeCols) {
          if (c < line.length && line[c] == '-') {
            line[c] = ' ';
            eye[c] = '#';
          }
        }
      }
      base.add(line.join());
      eyes.add(eye.join());
    }
    return (base, eyes);
  }

  static final (List<String>, List<String>) _layers = _eyeLayers();

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final style = J3Type.ascii.copyWith(
      fontSize: _font,
      color: fx.accentColor,
      shadows: fx.glow ? [Shadow(color: fx.accentColor.withValues(alpha: 0.7), blurRadius: fx.glowBlur(8))] : null,
    );
    final lineH = _font * (style.height ?? 1.18);

    final art = AnimatedBuilder(
      animation: _laugh,
      builder: (context, _) {
        final laughing = _laugh.isAnimating;
        final drop = laughing && !fx.reduceMotion ? math.sin(_laugh.value * 3 * math.pi).abs() * lineH * 0.9 : 0.0;
        final eyeStyle = style.copyWith(
          color: J3Colors.text,
          shadows: [
            Shadow(color: fx.accentColor, blurRadius: 6),
            Shadow(color: fx.accentColor, blurRadius: 12),
          ],
        );
        return Padding(
          padding: EdgeInsets.only(bottom: lineH),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AsciiArt(lines: laughing ? _layers.$1 : kMiniSkullCranium, style: style, fit: false),
                  Transform.translate(
                    offset: Offset(0, drop),
                    child: AsciiArt(lines: kMiniSkullJaw, style: style, fit: false),
                  ),
                ],
              ),
              if (laughing)
                Positioned(
                  left: 0,
                  top: 0,
                  child: AsciiArt(lines: _layers.$2, style: eyeStyle, fit: false),
                ),
            ],
          ),
        );
      },
    );

    return Semantics(
      button: true,
      image: true,
      label: 'J3NSONTOP skull logo',
      excludeSemantics: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (f) => setState(() => _focus = f),
        onShowHoverHighlight: (h) => setState(() => _hover = h),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _tap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          key: const ValueKey('home-skull'),
          behavior: HitTestBehavior.opaque,
          onTap: _tap,
          child: AnimatedContainer(
            duration: fx.motion(J3Durations.fast),
            width: widget.size,
            padding: const EdgeInsets.all(J3Space.sm),
            decoration: BoxDecoration(
              color: J3Colors.background.withValues(alpha: 0.55),
              borderRadius: J3Radius.medium,
              border: Border.all(
                color: _focus ? fx.accentColor : (_hover ? fx.accentColor.withValues(alpha: 0.5) : J3Colors.border),
                width: _focus ? 2 : 1,
              ),
              boxShadow: fx.glow
                  ? [
                      BoxShadow(
                        color: fx.accentColor.withValues(alpha: 0.18),
                        blurRadius: fx.glowBlur(18),
                        spreadRadius: -4,
                      ),
                    ]
                  : null,
            ),
            child: FittedBox(fit: BoxFit.contain, child: art),
          ),
        ),
      ),
    );
  }
}
