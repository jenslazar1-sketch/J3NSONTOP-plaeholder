import 'package:flutter/material.dart';

import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../domain/color_model.dart';
import 'checkerboard.dart';

/// Flutter colour for a user colour value (data, not UI styling).
Color toFlutterColor(Rgba c) => Color(c.argb32);

/// Square swatch that shows alpha over a checkerboard.
class ColorSwatchBox extends StatelessWidget {
  const ColorSwatchBox({super.key, required this.color, this.size = 28, this.selected = false});
  final Rgba color;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: J3Radius.small,
        border: Border.all(color: selected ? J3Colors.text : J3Colors.borderStrong, width: selected ? 2 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Checkerboard(cell: 5, child: ColoredBox(color: toFlutterColor(color))),
    );
  }
}

/// Colour entry: swatch + HEX field (validated) + optional presets.
class ColorChoiceField extends StatefulWidget {
  const ColorChoiceField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.allowAlpha = false,
    this.presets = const [],
    this.width = 200,
  });

  final String label;
  final Rgba value;
  final ValueChanged<Rgba> onChanged;
  final bool allowAlpha;
  final List<(String, Rgba)> presets;
  final double width;

  @override
  State<ColorChoiceField> createState() => _ColorChoiceFieldState();
}

class _ColorChoiceFieldState extends State<ColorChoiceField> {
  late final TextEditingController _c = TextEditingController(text: ColorFormat.hex(widget.value));
  String? _error;

  @override
  void didUpdateWidget(ColorChoiceField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      Rgba? current;
      try {
        current = ColorFormat.parseHex(_c.text);
      } on FormatException {
        current = null;
      }
      if (current != widget.value) {
        _c.text = ColorFormat.hex(widget.value);
        _error = null;
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _onText(String v) {
    try {
      final c = ColorFormat.parseHex(v);
      if (!widget.allowAlpha && !c.isOpaque) {
        setState(() => _error = 'Must be opaque (no alpha)');
        return;
      }
      setState(() => _error = null);
      widget.onChanged(c);
    } on FormatException catch (e) {
      setState(() => _error = e.message.length > 60 ? 'Use #RGB or #RRGGBB' : e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 10, right: J3Space.sm),
              child: ColorSwatchBox(color: widget.value, size: 32),
            ),
            Flexible(
              child: SizedBox(
                width: widget.width,
                child: TextField(
                  controller: _c,
                  style: J3Type.code,
                  onChanged: _onText,
                  decoration: InputDecoration(
                    labelText: widget.label,
                    errorText: _error,
                    errorMaxLines: 2,
                    helperText: widget.allowAlpha ? '#RGB, #RRGGBB, #RRGGBBAA' : '#RGB or #RRGGBB',
                  ),
                ),
              ),
            ),
          ],
        ),
        if (widget.presets.isNotEmpty) ...[
          const SizedBox(height: J3Space.xs),
          Wrap(
            spacing: J3Space.xs,
            runSpacing: J3Space.xs,
            children: [
              for (final (name, c) in widget.presets)
                ActionChip(
                  avatar: ColorSwatchBox(color: c, size: 16),
                  label: Text(name),
                  tooltip: 'Use $name (${ColorFormat.hex(c)})',
                  onPressed: () {
                    _c.text = ColorFormat.hex(c);
                    setState(() => _error = null);
                    widget.onChanged(c);
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Common flatten/background presets.
const List<(String, Rgba)> backgroundPresets = [
  ('White', Rgba(255, 255, 255)),
  ('Black', Rgba(0, 0, 0)),
  ('J3 black', Rgba(5, 5, 7)),
  ('Neon red', Rgba(255, 22, 59)),
];
