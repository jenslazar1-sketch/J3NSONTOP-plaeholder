import 'package:flutter/material.dart';

import '../theme/j3_typography.dart';

/// Renders fixed-width ASCII art without wrapping. Each line is one [Text]
/// with a strut so rows never drift; the block scales down to fit narrow
/// screens instead of wrapping or clipping.
class AsciiArt extends StatelessWidget {
  const AsciiArt({super.key, required this.lines, this.style = J3Type.ascii, this.fit = true, this.semanticLabel});

  final List<String> lines;
  final TextStyle style;
  final bool fit;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final width = lines.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    final block = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in lines)
          Text(
            l.padRight(width),
            style: style,
            softWrap: false,
            maxLines: 1,
            overflow: TextOverflow.visible,
            strutStyle: StrutStyle(
              fontFamily: style.fontFamily,
              fontSize: style.fontSize,
              height: style.height,
              forceStrutHeight: true,
            ),
            textScaler: TextScaler.noScaling,
          ),
      ],
    );
    final content = ExcludeSemantics(
      child: fit ? FittedBox(fit: BoxFit.scaleDown, child: block) : block,
    );
    if (semanticLabel == null) return content;
    return Semantics(label: semanticLabel, image: true, child: content);
  }
}
