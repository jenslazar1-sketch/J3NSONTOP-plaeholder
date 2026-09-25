import 'package:flutter/material.dart';

import '../../app/app_info.dart';
import '../../core/theme/j3_colors.dart';
import '../../core/theme/j3_typography.dart';
import 'intro_fx.dart';

/// The product name with its deliberate line breaks
/// ([AppInfo.fullNameLines]) plus the typed "J3NSONTOP SYSTEM ONLINE".
///
/// Every line sits in its own [FittedBox] inside a column of the available
/// width, and the column is scaled down as a whole when it is taller than
/// the space it gets, so the title never overflows or clips - even at 320 px
/// wide with 2x text scaling. Reveal animations only clip or recolour
/// already laid-out text, so nothing reflows or jitters while it plays.
class IntroTitle extends StatelessWidget {
  const IntroTitle({
    super.key,
    required this.lines,
    required this.tagline,
    required this.cursor,
    required this.accent,
    required this.bloom,
  });

  /// Reveal progress 0..1 per line of [AppInfo.fullNameLines].
  final List<double> lines;

  /// Typing progress 0..1 of [AppInfo.tagline].
  final double tagline;
  final bool cursor;
  final Color accent;

  /// Text glow blur (0 = none).
  final double bloom;

  static const double _gap = 14;

  TextStyle _lineStyle(int i) {
    final glow = bloom > 0 ? [Shadow(color: accent.withValues(alpha: 0.65), blurRadius: bloom)] : null;
    if (i == 0) {
      return J3Type.display.copyWith(fontSize: 46, letterSpacing: 7, height: 1.05, color: accent, shadows: glow);
    }
    return J3Type.display.copyWith(
      fontSize: 30,
      letterSpacing: i == 1 ? 10 : 5,
      height: 1.15,
      color: J3Colors.text,
      shadows: bloom > 0 ? [Shadow(color: accent.withValues(alpha: 0.35), blurRadius: bloom * 0.8)] : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      label: '${AppInfo.fullName}. ${AppInfo.tagline}',
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final column = SizedBox(
              width: constraints.maxWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < AppInfo.fullNameLines.length; i++)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: WipeText(
                        AppInfo.fullNameLines[i],
                        style: _lineStyle(i),
                        progress: i < lines.length ? lines[i] : 1,
                        edge: accent,
                      ),
                    ),
                  const SizedBox(height: _gap),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: TypedText(AppInfo.tagline, progress: tagline, cursor: cursor, accent: accent),
                  ),
                ],
              ),
            );
            return FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.topCenter, child: column);
          },
        ),
      ),
    );
  }
}

/// Text revealed left to right by a clip, with a hot edge at the reveal
/// front. Layout is identical at every progress value.
class WipeText extends StatelessWidget {
  const WipeText(this.text, {super.key, required this.style, required this.progress, required this.edge});

  final String text;
  final TextStyle style;
  final double progress;
  final Color edge;

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    final text = Text(this.text, style: style, maxLines: 1, softWrap: false);
    // Not started: keep the layout, paint nothing (not even the glow).
    if (p <= 0) return Visibility.maintain(visible: false, child: text);
    return CustomPaint(
      foregroundPainter: p < 1 ? _EdgePainter(p, edge) : null,
      child: ClipRect(clipper: _WidthClipper(p), clipBehavior: p >= 1 ? Clip.none : Clip.hardEdge, child: text),
    );
  }
}

class _WidthClipper extends CustomClipper<Rect> {
  _WidthClipper(this.fraction);
  final double fraction;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(-size.width, -size.height, size.width * fraction, size.height * 2);

  @override
  bool shouldReclip(_WidthClipper old) => old.fraction != fraction;
}

class _EdgePainter extends CustomPainter {
  _EdgePainter(this.fraction, this.color);
  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width * fraction;
    final bar = Rect.fromLTWH(x - 1.5, size.height * 0.08, 3, size.height * 0.84);
    canvas.drawRect(bar.inflate(3), Paint()..color = color.withValues(alpha: 0.25));
    canvas.drawRect(bar, Paint()..color = phosphor(color));
  }

  @override
  bool shouldRepaint(_EdgePainter old) => old.fraction != fraction || old.color != color;
}

/// Monospaced text typed character by character, the next characters
/// shown as scrambled glyphs, followed by a block cursor. The untyped rest
/// is laid out transparently so the width never changes.
class TypedText extends StatelessWidget {
  const TypedText(this.text, {super.key, required this.progress, required this.cursor, required this.accent});

  final String text;
  final double progress;
  final bool cursor;
  final Color accent;

  static const String _noise = r'#%&@$*+=/\<>01?';

  static TextStyle get style =>
      J3Type.kicker.copyWith(fontSize: 14, letterSpacing: 3, color: J3Colors.text, fontWeight: FontWeight.w700);

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    final typed = (text.length * p).floor();
    final scrambleEnd = p <= 0 || p >= 1 ? typed : (typed + 2).clamp(0, text.length);
    final scramble = StringBuffer();
    for (var i = typed; i < scrambleEnd; i++) {
      final ch = text[i];
      scramble.write(ch == ' ' ? ' ' : _noise[(i * 31 + typed * 17) % _noise.length]);
    }
    final base = style;
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: text.substring(0, typed)),
          TextSpan(
            text: scramble.toString(),
            style: TextStyle(color: accent.withValues(alpha: 0.85)),
          ),
          TextSpan(
            text: text.substring(scrambleEnd),
            style: const TextStyle(color: Color(0x00000000)),
          ),
          TextSpan(
            text: ' █',
            style: TextStyle(color: cursor ? accent : const Color(0x00000000)),
          ),
        ],
      ),
      maxLines: 1,
      softWrap: false,
    );
  }
}
