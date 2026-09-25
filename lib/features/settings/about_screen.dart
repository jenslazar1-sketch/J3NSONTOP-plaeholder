import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_info.dart';
import '../../core/platform/capabilities.dart';
import '../../core/theme/effects.dart';
import '../../core/theme/j3_colors.dart';
import '../../core/theme/j3_spacing.dart';
import '../../core/theme/j3_typography.dart';
import '../../core/widgets/widgets.dart';
import '../intro/skull_art.dart';
import 'capability_views.dart';
import 'licenses.dart';

/// Identity, scope, capability matrix and credits.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final caps = ref.watch(capabilitiesProvider);
    final fx = context.effects;

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 860;
        final pad = c.maxWidth >= J3Breakpoints.medium ? J3Space.pagePaddingWide : J3Space.pagePadding;

        final identity = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('// ABOUT', style: J3Type.kicker.copyWith(color: fx.accentText)),
            const SizedBox(height: J3Space.sm),
            for (final (i, line) in AppInfo.fullNameLines.indexed)
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  line,
                  style: J3Type.display.copyWith(
                    fontSize: wide ? 40 : 30,
                    letterSpacing: 3,
                    color: i == 0 ? fx.accentText : J3Colors.text,
                    shadows: i == 0 && fx.glow
                        ? [Shadow(color: fx.accentColor.withValues(alpha: 0.7), blurRadius: fx.glowBlur(20))]
                        : null,
                  ),
                ),
              ),
            const SizedBox(height: J3Space.sm),
            Text(AppInfo.tagline, style: J3Type.kicker.copyWith(color: J3Colors.textSecondary)),
            const SizedBox(height: J3Space.md),
            Text(AppInfo.description, style: J3Type.body),
            const SizedBox(height: J3Space.md),
            Wrap(
              spacing: J3Space.sm,
              runSpacing: J3Space.sm,
              children: [
                IntrinsicWidth(
                  child: NeonButton(
                    label: 'Replay intro',
                    icon: Icons.replay,
                    tooltip: 'Watch the laughing-skull intro again',
                    onPressed: () => context.go('/intro?replay=1'),
                  ),
                ),
                IntrinsicWidth(
                  child: NeonButton.secondary(
                    label: 'Open-source licences',
                    icon: Icons.gavel_outlined,
                    onPressed: () => showLicensePage(
                      context: context,
                      applicationName: AppInfo.shortName,
                      applicationVersion: '${AppInfo.version} (build ${AppInfo.buildNumber})',
                      applicationLegalese: AppInfo.scopeStatement,
                      useRootNavigator: true,
                    ),
                  ),
                ),
              ],
            ),
          ],
        );

        final skull = ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 340 : 280),
          child: const LaughingSkullArt(),
        );

        final hero = NeonPanel(
          emphasis: PanelEmphasis.strong,
          padding: const EdgeInsets.all(J3Space.xl),
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    skull,
                    const SizedBox(width: J3Space.xxl),
                    Expanded(child: identity),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(child: skull),
                    const SizedBox(height: J3Space.lg),
                    identity,
                  ],
                ),
        );

        final details = NeonPanel(
          kicker: '// BUILD',
          title: 'Version and identity',
          icon: Icons.fingerprint,
          child: KeyValueTable(
            keyWidth: c.maxWidth < J3Breakpoints.compact ? 110 : 160,
            rows: [
              ('Name', AppInfo.fullName),
              ('Version', AppInfo.version),
              ('Build', '${AppInfo.buildNumber}'),
              ('Application id', AppInfo.applicationId),
              ('Platform', caps.platform.label),
              ('Data', 'Local only (no account, no cloud)'),
            ],
          ),
        );

        final scope = NeonPanel(
          kicker: '// SCOPE',
          title: 'What this app is for',
          icon: Icons.shield_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(AppInfo.scopeStatement, style: J3Type.body),
              const SizedBox(height: J3Space.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.verified_user_outlined, size: 18, color: J3Colors.success),
                  const SizedBox(width: J3Space.sm),
                  Expanded(
                    child: Text(
                      'No telemetry: nothing about you or your files is collected or sent anywhere. Network access '
                      'happens only when you send a request with the HTTP tool.',
                      style: J3Type.bodySecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );

        final matrix = NeonPanel(
          kicker: '// CAPABILITY MATRIX',
          title: 'What works where',
          icon: Icons.grid_on_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Android, iOS and Windows are the delivered platforms; Linux is the development and test target. '
                'Unavailable capabilities always come with a supported alternative inside the app.',
                style: J3Type.caption,
              ),
              const SizedBox(height: J3Space.md),
              CapabilityMatrixTable(current: caps.platform),
            ],
          ),
        );

        final credits = NeonPanel(
          kicker: '// CREDITS',
          title: 'Art, sound and fonts',
          icon: Icons.favorite_border,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _CreditRow(
                icon: Icons.sentiment_very_satisfied_outlined,
                title: 'ASCII skull and icon art',
                text:
                    'Original to this project. The skull was designed from scratch with tool/skull/skull_design.py; '
                    'no third-party art is used.',
              ),
              const _CreditRow(
                icon: Icons.graphic_eq,
                title: 'Intro sound',
                text:
                    'Original and synthesized for this app by tool/sound/generate_intro_sound.py. Optional and off '
                    'by default.',
              ),
              for (final f in kBundledFontLicenses)
                _CreditRow(
                  icon: Icons.font_download_outlined,
                  title: '${f.family} - SIL Open Font License 1.1',
                  text: '${f.usage} ${f.copyright}.',
                  action: TextButton.icon(
                    onPressed: () => showFontLicenseDialog(context, f),
                    icon: const Icon(Icons.description_outlined, size: 18),
                    label: const Text('View licence'),
                  ),
                ),
              const SizedBox(height: J3Space.sm),
              Text(
                'Licences of the Dart and Flutter packages the app is built with are listed under '
                'Open-source licences.',
                style: J3Type.caption,
              ),
            ],
          ),
        );

        final gap = const SizedBox(height: J3Space.lg);
        return SingleChildScrollView(
          padding: pad,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: J3Size.maxContentWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  hero,
                  gap,
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: details),
                        const SizedBox(width: J3Space.lg),
                        Expanded(child: scope),
                      ],
                    )
                  else ...[
                    details,
                    gap,
                    scope,
                  ],
                  gap,
                  matrix,
                  gap,
                  credits,
                  const SizedBox(height: J3Space.xxl),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CreditRow extends StatelessWidget {
  const _CreditRow({required this.icon, required this.title, required this.text, this.action});
  final IconData icon;
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: J3Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: context.effects.accentText),
          const SizedBox(width: J3Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: J3Type.label),
                const SizedBox(height: 2),
                Text(text, style: J3Type.bodySecondary),
                ?action,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The large original ASCII skull in two layers (cranium + jaw). Five quick
/// taps (or Enter presses) or a long press make it laugh: the jaw drops and
/// closes three times while the eyes glow. With reduced motion only the
/// eyes light up.
class LaughingSkullArt extends StatefulWidget {
  const LaughingSkullArt({super.key});

  static const int tapsToLaugh = 5;
  static const Duration tapWindow = Duration(milliseconds: 1800);
  static const Duration laughDuration = Duration(milliseconds: 1400);

  @override
  State<LaughingSkullArt> createState() => _LaughingSkullArtState();
}

class _LaughingSkullArtState extends State<LaughingSkullArt> with SingleTickerProviderStateMixin {
  late final AnimationController _laugh = AnimationController(vsync: this, duration: LaughingSkullArt.laughDuration);
  final List<DateTime> _taps = [];
  bool _focus = false;

  static const double _fontSize = 12;

  @override
  void dispose() {
    _laugh.dispose();
    super.dispose();
  }

  void _tap() {
    final now = DateTime.now();
    _taps
      ..add(now)
      ..removeWhere((t) => now.difference(t) > LaughingSkullArt.tapWindow);
    if (_taps.length >= LaughingSkullArt.tapsToLaugh) {
      _taps.clear();
      _startLaugh();
    }
  }

  void _startLaugh() {
    if (_laugh.isAnimating) return;
    _laugh.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final style = J3Type.ascii.copyWith(fontSize: _fontSize, color: fx.accentColor);
    final painter = TextPainter(
      text: TextSpan(text: 'M', style: style),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    final cellW = painter.width;
    painter.dispose();
    final lineH = _fontSize * (style.height ?? 1.18);
    final width = cellW * kSkullColumns;
    final height = lineH * (kSkullCranium.length + kSkullJaw.length) + lineH * 1.5;

    final skull = AnimatedBuilder(
      animation: _laugh,
      builder: (context, _) {
        final t = _laugh.value;
        final laughing = _laugh.isAnimating;
        final drop = laughing && !fx.reduceMotion ? math.sin(t * 3 * math.pi).abs() * lineH * 1.4 : 0.0;
        final eyeStrength = laughing ? 1.0 : (fx.glow ? 0.25 + 0.2 * fx.intensity : 0.0);
        final radius = cellW * 4.5;
        return SizedBox(
          width: width,
          height: height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (eyeStrength > 0)
                for (final (col, row) in kSkullEyeCentres)
                  Positioned(
                    left: col * cellW - radius,
                    top: row * lineH - radius,
                    width: radius * 2,
                    height: radius * 2,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            (laughing ? J3Colors.text : fx.accentColor).withValues(alpha: 0.55 * eyeStrength),
                            fx.accentColor.withValues(alpha: 0.35 * eyeStrength),
                            fx.accentColor.withValues(alpha: 0),
                          ],
                          stops: const [0, 0.35, 1],
                        ),
                      ),
                    ),
                  ),
              Positioned(
                left: 0,
                top: 0,
                child: AsciiArt(lines: kSkullCranium, style: style, fit: false),
              ),
              Positioned(
                left: 0,
                top: lineH * kSkullCranium.length + drop,
                child: AsciiArt(lines: kSkullJaw, style: style, fit: false),
              ),
            ],
          ),
        );
      },
    );

    return Semantics(
      image: true,
      button: true,
      label: 'J3NSONTOP laughing skull. Tap five times quickly or long-press to make it laugh.',
      excludeSemantics: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (f) => setState(() => _focus = f),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _tap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _tap,
          onLongPress: _startLaugh,
          child: Container(
            key: const ValueKey('about-skull'),
            padding: const EdgeInsets.all(J3Space.xs),
            decoration: BoxDecoration(
              borderRadius: J3Radius.medium,
              border: Border.all(color: _focus ? fx.accentColor : Colors.transparent, width: 2),
            ),
            child: FittedBox(fit: BoxFit.scaleDown, child: skull),
          ),
        ),
      ),
    );
  }
}
