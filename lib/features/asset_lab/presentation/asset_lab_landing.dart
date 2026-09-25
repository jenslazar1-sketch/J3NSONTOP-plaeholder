import 'package:flutter/material.dart';

import '../../../core/theme/effects.dart';
import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/tools/tool_definition.dart';
import '../../../core/widgets/widgets.dart';
import '../../shell/section_hub.dart';
import '../domain/image_codec.dart';

/// Decorative pixel-grid banner (cosmetic only; announced as such).
const List<String> _banner = [
  '+--+--+--+--+   ASSET//LAB',
  '|##|  |##|  |   pixels in, pixels out',
  '+--+--+--+--+   local only',
  '|  |##|  |##|',
  '+--+--+--+--+',
];

/// Section landing for the Asset Lab: banner, tool grid and the real
/// decode/encode support matrix.
class AssetLabLanding extends StatelessWidget {
  const AssetLabLanding({super.key});

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final decodes = decodableImageExtensions.map((e) => e.toUpperCase()).toList();
    return SingleChildScrollView(
      padding: J3Space.pagePaddingWide,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: J3Size.maxContentWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '// ${ToolSection.assetLab.label.toUpperCase()}',
                style: J3Type.kicker.copyWith(color: fx.accentText),
              ),
              GlitchText(ToolSection.assetLab.label, style: J3Type.headline),
              const SizedBox(height: J3Space.xs),
              Text(ToolSection.assetLab.tagline, style: J3Type.bodySecondary),
              const SizedBox(height: J3Space.md),
              Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: AsciiArt(
                    lines: _banner,
                    style: J3Type.ascii.copyWith(fontSize: 12, color: fx.accentColor.withValues(alpha: 0.75)),
                    semanticLabel: 'Decorative pixel grid banner',
                  ),
                ),
              ),
              const SizedBox(height: J3Space.lg),
              const SectionHub(section: ToolSection.assetLab, embedded: true),
              const SizedBox(height: J3Space.xl),
              NeonPanel(
                kicker: 'Formats',
                title: 'What the Asset Lab reads and writes',
                icon: Icons.fact_check_outlined,
                emphasis: PanelEmphasis.subtle,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    KeyValueTable(
                      keyWidth: 90,
                      rows: [
                        ('Reads', decodes.toSet().join(' ')),
                        (
                          'Writes',
                          [
                            for (final f in ExportFormat.values)
                              '${f.label}${f.alpha ? '' : ' (no alpha)'}${f.maxSide != null ? ' (<=${f.maxSide}px)' : ''}',
                          ].join(', '),
                        ),
                      ],
                    ),
                    const SizedBox(height: J3Space.sm),
                    Text(
                      'Everything runs on this device with pure-Dart codecs in background isolates. '
                      'Originals are never replaced; outputs get new names.',
                      style: J3Type.caption.copyWith(color: J3Colors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
