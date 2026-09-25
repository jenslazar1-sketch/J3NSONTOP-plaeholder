import 'package:flutter/material.dart';

import '../theme/j3_colors.dart';
import '../theme/j3_spacing.dart';
import '../theme/j3_typography.dart';

/// Labelled switch row with an explanation line. Whole row is tappable and
/// keyboard-focusable.
class OptionSwitch extends StatelessWidget {
  const OptionSwitch({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.description,
  });

  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: J3Space.xs),
        title: Text(label, style: J3Type.body),
        subtitle: description == null ? null : Text(description!, style: J3Type.caption),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

/// A compact choice between a few enum-like options.
class ChoiceRow<T> extends StatelessWidget {
  const ChoiceRow({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    required this.onSelected,
    required this.labelOf,
  });

  final String label;
  final List<T> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final String Function(T) labelOf;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: J3Type.caption),
        const SizedBox(height: J3Space.xs),
        Wrap(
          spacing: J3Space.sm,
          runSpacing: J3Space.sm,
          children: [
            for (final o in options)
              ChoiceChip(
                label: Text(labelOf(o)),
                selected: o == selected,
                onSelected: (_) => onSelected(o),
                showCheckmark: false,
              ),
          ],
        ),
      ],
    );
  }
}

/// Key/value metadata table (monospace values, selectable).
class KeyValueTable extends StatelessWidget {
  const KeyValueTable({super.key, required this.rows, this.keyWidth = 150});
  final List<(String, String)> rows;
  final double keyWidth;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: keyWidth, child: Text(k, style: J3Type.caption)),
                Expanded(child: SelectableText(v, style: J3Type.code.copyWith(color: J3Colors.text))),
              ],
            ),
          ),
      ],
    );
  }
}

/// Numeric text field with min/max validation.
class NumberField extends StatelessWidget {
  const NumberField({
    super.key,
    required this.controller,
    required this.label,
    this.min,
    this.max,
    this.allowDecimal = false,
    this.onChanged,
    this.width = 140,
  });

  final TextEditingController controller;
  final String label;
  final num? min;
  final num? max;
  final bool allowDecimal;
  final ValueChanged<String>? onChanged;
  final double width;

  String? validate(String v) {
    final n = allowDecimal ? double.tryParse(v) : int.tryParse(v);
    if (n == null) return allowDecimal ? 'Number' : 'Whole number';
    if (min != null && n < min!) return '>= $min';
    if (max != null && n > max!) return '<= $max';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) => TextField(
          controller: controller,
          onChanged: onChanged,
          keyboardType: TextInputType.numberWithOptions(decimal: allowDecimal, signed: (min ?? 0) < 0),
          style: J3Type.code,
          decoration: InputDecoration(labelText: label, errorText: value.text.isEmpty ? null : validate(value.text)),
        ),
      ),
    );
  }
}
