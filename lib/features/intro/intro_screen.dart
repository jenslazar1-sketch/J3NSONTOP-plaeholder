import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_info.dart';
import '../../core/platform/capabilities.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme/effects.dart';
import '../../core/theme/j3_colors.dart';
import '../../core/theme/j3_spacing.dart';
import '../../core/theme/j3_typography.dart';
import '../../core/widgets/neon_button.dart';
import 'intro_fx.dart';
import 'intro_sound.dart';
import 'intro_timeline.dart';
import 'intro_title.dart';
import 'skull_rig.dart';

/// Keys of the intro's interactive and measurable parts.
abstract final class IntroKeys {
  static const Key skip = ValueKey<String>('intro-skip');
  static const Key mute = ValueKey<String>('intro-mute');
  static const Key skipToggle = ValueKey<String>('intro-skip-toggle');
  static const Key continueButton = ValueKey<String>('intro-continue');
  static const Key cranium = ValueKey<String>('intro-skull-cranium');
  static const Key jaw = ValueKey<String>('intro-skull-jaw');
  static const Key glitch = ValueKey<String>('intro-glitch');
  static const Key signal = ValueKey<String>('intro-signal');
  static const Key title = ValueKey<String>('intro-title');
  static const Key skull = ValueKey<String>('intro-skull');
}

/// The first-launch laughing-skull intro (about 4.2 s; see [IntroTimeline]
/// and docs/INTRO.md):
///
/// darkness -> red signal flicker -> scanline reveal with the eyes igniting
/// -> three "HA" pulses (jaw drops and snaps shut, head bobs) -> glitch
/// burst -> title + "J3NSONTOP SYSTEM ONLINE" -> fade and scanline wipe ->
/// [onFinished] (called exactly once).
///
/// * SKIP (and Esc, or Enter/Space when no control has focus) finishes
///   immediately.
/// * "Skip intro on launch" persists `AppSettings.skipIntro`.
/// * Sound plays only when enabled in settings; MUTE stops it instantly and
///   persists `sound = false`.
/// * Reduced motion shows a static skull and title with a Continue button
///   and continues automatically after 1.2 s.
/// * Low-effects mode (intensity 0) drops the flicker and the glitch.
///
/// Nothing here delays app initialisation: the app is fully initialised
/// before and while the intro plays.
class IntroScreen extends ConsumerStatefulWidget {
  const IntroScreen({super.key, required this.onFinished, this.replay = false});

  final VoidCallback onFinished;

  /// Opened on request (`/intro?replay=1`) rather than on launch.
  final bool replay;

  /// Reduced motion: time before continuing automatically.
  static const Duration staticAutoContinue = Duration(milliseconds: 1200);

  @override
  ConsumerState<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends ConsumerState<IntroScreen> with SingleTickerProviderStateMixin {
  final FocusNode _focus = FocusNode(debugLabel: 'intro');
  final SkullMetricsCache _metrics = SkullMetricsCache();

  AnimationController? _anim;
  IntroTimeline? _timeline;
  Timer? _autoContinue;
  IntroSound? _sound;
  bool _started = false;
  bool _finished = false;
  bool _muted = false;

  @override
  void initState() {
    super.initState();
    PaintingBinding.instance.systemFonts.addListener(_onFontsChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final fx = context.effects;
    if (fx.reduceMotion) {
      _autoContinue = Timer(IntroScreen.staticAutoContinue, _finish);
      return;
    }
    final timeline = _timeline = IntroTimeline(decorative: fx.decorativeMotion);
    final anim = _anim = AnimationController(vsync: this, duration: timeline.duration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _finish();
      });
    anim.forward();
    if (fx.sound && ref.read(capabilitiesProvider).supports(Capability.audio)) {
      final sound = _sound = ref.read(introSoundProvider)();
      unawaited(
        sound.start(
          volume: fx.volume,
          position: () => Duration(microseconds: ((timeline.soundOffset + anim.value * timeline.total) * 1e6).round()),
        ),
      );
    }
  }

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(_onFontsChanged);
    _autoContinue?.cancel();
    _anim?.dispose();
    _sound?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFontsChanged() {
    if (mounted) setState(_metrics.invalidate);
  }

  /// Ends the intro: stops everything and calls [IntroScreen.onFinished]
  /// exactly once. Used by skip, Continue, auto-continue and completion.
  void _finish() {
    if (_finished) return;
    _finished = true;
    _autoContinue?.cancel();
    _anim?.stop();
    _sound?.stop();
    widget.onFinished();
  }

  void _mute() {
    setState(() => _muted = true);
    _sound?.stop();
    _persist((s) => s.copyWith(sound: false));
  }

  void _setSkipOnLaunch(bool value) => _persist((s) => s.copyWith(skipIntro: value));

  void _persist(AppSettings Function(AppSettings s) change) {
    unawaited(
      ref.read(settingsProvider.notifier).update(change).catchError((Object e) {
        debugPrint('Intro could not save settings: $e');
      }),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _finish();
      return KeyEventResult.handled;
    }
    // Enter/Space skip only when no control (toggle, mute) has the focus,
    // so they keep activating the focused control.
    final activate =
        key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.space;
    if (activate && _focus.hasPrimaryFocus) {
      _finish();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final anim = _anim;
    final timeline = _timeline;
    final skipOnLaunch = ref.watch(settingsProvider.select((s) => s.skipIntro));
    Widget body;
    if (anim == null || timeline == null) {
      body = _scene(context, _IntroFrame.still, skipOnLaunch);
    } else {
      body = AnimatedBuilder(
        animation: anim,
        builder: (context, _) => _scene(context, _IntroFrame.at(timeline, anim.value * timeline.total), skipOnLaunch),
      );
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Focus(focusNode: _focus, autofocus: true, onKeyEvent: _onKey, child: body),
    );
  }

  Widget _scene(BuildContext context, _IntroFrame f, bool skipOnLaunch) {
    final fx = context.effects;
    final isStatic = _anim == null;
    final accent = fx.accentColor;
    final bloom = fx.glowBlur(10);

    final content = Column(
      children: [
        _topBar(fx),
        Expanded(child: _stage(context, f)),
        _bottomBar(isStatic, skipOnLaunch),
      ],
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        if (f.cover > 0)
          IgnorePointer(
            child: ColoredBox(color: kIntroDark.withValues(alpha: f.cover)),
          ),
        SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRect(
                clipper: WipeClipper(f.wipe),
                clipBehavior: f.wipe > 0 ? Clip.hardEdge : Clip.none,
                child: Opacity(opacity: f.opacity, child: content),
              ),
              if (f.wipe > 0 && f.wipe < 1)
                IgnorePointer(
                  child: CustomPaint(
                    painter: WipePainter(position: f.wipe, accent: accent, bloom: bloom, opacity: 1),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _topBar(EffectsConfig fx) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(J3Space.lg, J3Space.md, J3Space.md, 0),
      child: Row(
        children: [
          if (widget.replay)
            Flexible(
              child: Text('REPLAY', style: J3Type.kicker, overflow: TextOverflow.ellipsis),
            ),
          const Spacer(),
          if (fx.sound && !_muted)
            NeonIconButton(key: IntroKeys.mute, icon: Icons.volume_up_rounded, tooltip: 'Mute', onPressed: _mute),
          const SizedBox(width: J3Space.xs),
          NeonButton.secondary(
            key: IntroKeys.skip,
            label: 'SKIP >>',
            semanticLabel: 'Skip intro',
            tooltip: 'Skip intro (Esc)',
            onPressed: _finish,
          ),
        ],
      ),
    );
  }

  Widget _bottomBar(bool isStatic, bool skipOnLaunch) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(J3Space.lg, J3Space.sm, J3Space.lg, J3Space.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isStatic)
            Padding(
              padding: const EdgeInsets.only(bottom: J3Space.md),
              child: NeonButton(
                key: IntroKeys.continueButton,
                label: 'Continue',
                icon: Icons.arrow_forward_rounded,
                onPressed: _finish,
              ),
            ),
          MergeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(key: IntroKeys.skipToggle, value: skipOnLaunch, onChanged: _setSkipOnLaunch),
                const SizedBox(width: J3Space.sm),
                Flexible(
                  child: GestureDetector(
                    onTap: () => _setSkipOnLaunch(!skipOnLaunch),
                    child: Text('Skip intro on launch', style: J3Type.caption.copyWith(color: J3Colors.textSecondary)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stage(BuildContext context, _IntroFrame f) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final skull = _skull(context, f);
        // The title is laid out from the first frame (invisible until its
        // reveal), so nothing moves when it appears.
        final title = KeyedSubtree(key: IntroKeys.title, child: _title(context, f));
        // Short landscape screens: skull left, title right.
        if (w > h * 1.3 && h < 560) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: J3Space.lg),
            child: Row(
              children: [
                Expanded(flex: 5, child: skull),
                const SizedBox(width: J3Space.lg),
                Expanded(flex: 6, child: Center(child: title)),
              ],
            ),
          );
        }
        final skullHeight = (h * 0.6).clamp(0.0, 600.0);
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(height: skullHeight, width: w, child: skull),
            const SizedBox(height: J3Space.md),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: J3Space.lg),
                child: title,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _title(BuildContext context, _IntroFrame f) {
    final fx = context.effects;
    return IntroTitle(
      lines: f.titleLines,
      tagline: f.tagline,
      cursor: f.cursor,
      accent: fx.accentColor,
      bloom: fx.glowBlur(14),
    );
  }

  Widget _skull(BuildContext context, _IntroFrame f) {
    final fx = context.effects;
    final accent = fx.accentColor;
    final style = skullTextStyle(color: accent, shadows: skullGlyphGlow(fx));
    final metrics = _metrics.of(style);
    const art = SkullArt.full;
    final size = SkullRig.sizeFor(art, metrics);
    final gridHeight = art.rows * metrics.lineHeight;
    final glow = SkullGlow.of(fx);

    Widget rig({required bool keyed}) => SkullRig(
      art: art,
      metrics: metrics,
      style: style,
      pose: f.pose,
      glow: glow,
      craniumKey: keyed ? IntroKeys.cranium : null,
      jawKey: keyed ? IntroKeys.jaw : null,
    );

    Widget skull = rig(keyed: true);

    if (f.glitch > 0) {
      final slices = glitchSlices(
        frame: f.glitchFrame,
        height: gridHeight,
        strength: f.glitch,
        maxShift: metrics.advance * (1.2 + 2.2 * fx.intensity),
      );
      final split = metrics.advance * (0.25 + 0.55 * fx.intensity) * f.glitch;
      skull = Stack(
        clipBehavior: Clip.none,
        children: [
          KeyedSubtree(
            key: IntroKeys.glitch,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Transform.translate(
                  offset: Offset(-split, 0),
                  child: ColorFiltered(
                    colorFilter: ColorFilter.mode(kGlitchCyan.withValues(alpha: 0.55), BlendMode.srcIn),
                    child: rig(keyed: false),
                  ),
                ),
                Transform.translate(
                  offset: Offset(split, split * 0.25),
                  child: ColorFiltered(
                    colorFilter: ColorFilter.mode(kGlitchMagenta.withValues(alpha: 0.5), BlendMode.srcIn),
                    child: rig(keyed: false),
                  ),
                ),
              ],
            ),
          ),
          ClipPath(clipper: BandsExcludedClipper(slices), child: skull),
          for (final s in slices)
            ClipRect(
              clipper: BandClipper(s.top, s.bottom),
              child: Transform.translate(offset: Offset(s.dx, 0), child: rig(keyed: false)),
            ),
        ],
      );
    }

    if (f.reveal < 1) {
      final y = gridHeight * f.reveal;
      final hot = phosphor(accent, 0.85);
      skull = ClipRect(
        clipper: RevealClipper(y),
        child: fx.decorativeMotion
            ? ShaderMask(
                blendMode: BlendMode.srcATop,
                shaderCallback: (rect) {
                  final stop = (y / rect.height).clamp(0.0, 1.0);
                  final trail = (metrics.lineHeight * 2.2 / rect.height).clamp(0.0, 1.0);
                  return LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [hot.withValues(alpha: 0), hot.withValues(alpha: 0), hot.withValues(alpha: 0.9), hot],
                    stops: [0, (stop - trail).clamp(0.0, 1.0), (stop - 0.002).clamp(0.0, 1.0), stop],
                  ).createShader(rect);
                },
                child: skull,
              )
            : skull,
      );
    }

    final stage = SizedBox.fromSize(
      size: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (fx.glow && f.pose.eyeGlow > 0)
            Positioned.fill(
              child: CustomPaint(
                painter: HazePainter(
                  strength: f.pose.eyeGlow * (0.4 + 0.6 * fx.intensity),
                  accent: accent,
                  centre: const Offset(0.5, 0.45),
                ),
              ),
            ),
          Positioned.fill(child: skull),
          if (f.signal > 0)
            Positioned.fill(
              child: KeyedSubtree(
                key: IntroKeys.signal,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: SignalLinePainter(
                          brightness: f.signal,
                          extent: f.signalWidth,
                          accent: accent,
                          bloom: fx.glowBlur(6),
                        ),
                      ),
                    ),
                    Positioned(
                      left: size.width * 0.5 - size.width * 0.72 * f.signalWidth,
                      top: size.height * 0.46 + 6,
                      child: Opacity(
                        opacity: f.signal,
                        child: Text('SIGNAL', style: J3Type.kicker.copyWith(color: accent)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (f.revealing && fx.decorativeMotion)
            Positioned.fill(
              child: CustomPaint(
                painter: ScanBeamPainter(
                  y: gridHeight * f.reveal,
                  accent: accent,
                  bloom: fx.glowBlur(8),
                  lineHeight: metrics.lineHeight,
                ),
              ),
            ),
        ],
      ),
    );

    return Semantics(
      image: true,
      label: 'J3NSONTOP laughing skull',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.all(J3Space.sm),
          child: FittedBox(
            key: IntroKeys.skull,
            fit: BoxFit.contain,
            child: RepaintBoundary(child: stage),
          ),
        ),
      ),
    );
  }
}

/// Everything the scene needs for one frame, sampled from the timeline.
@immutable
class _IntroFrame {
  const _IntroFrame({
    required this.pose,
    required this.reveal,
    required this.revealing,
    required this.signal,
    required this.signalWidth,
    required this.glitch,
    required this.glitchFrame,
    required this.titleLines,
    required this.tagline,
    required this.cursor,
    required this.cover,
    required this.opacity,
    required this.wipe,
  });

  factory _IntroFrame.at(IntroTimeline tl, double t) => _IntroFrame(
    pose: tl.pose(t),
    reveal: tl.reveal(t),
    revealing: tl.revealing(t),
    signal: tl.signal(t),
    signalWidth: tl.signalWidth(t),
    glitch: tl.glitch(t),
    glitchFrame: tl.glitchFrame(t),
    titleLines: [for (var i = 0; i < AppInfo.fullNameLines.length; i++) tl.titleLine(i, t)],
    tagline: tl.tagline(t),
    cursor: tl.cursorOn(t),
    cover: tl.cover(t),
    opacity: tl.sceneOpacity(t),
    wipe: tl.wipe(t),
  );

  /// Reduced motion: the final composition, nothing moving.
  static const _IntroFrame still = _IntroFrame(
    pose: SkullPose.closed,
    reveal: 1,
    revealing: false,
    signal: 0,
    signalWidth: 0,
    glitch: 0,
    glitchFrame: 0,
    titleLines: [1, 1, 1],
    tagline: 1,
    cursor: true,
    cover: 0,
    opacity: 1,
    wipe: 0,
  );

  final SkullPose pose;
  final double reveal;
  final bool revealing;
  final double signal;
  final double signalWidth;
  final double glitch;
  final int glitchFrame;
  final List<double> titleLines;
  final double tagline;
  final bool cursor;
  final double cover;
  final double opacity;
  final double wipe;
}
