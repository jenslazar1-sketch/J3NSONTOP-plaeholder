import 'package:flutter/material.dart';

import '../../../../core/widgets/widgets.dart';

/// The kit's [OptionSwitch] inside its own transparent [Material]. NeonPanel
/// paints a filled DecoratedBox; without a Material between the panel and
/// the switch's ListTile, Flutter asserts that the tile's ink would be
/// hidden. The transparent Material makes the ripple visible and keeps the
/// panel look unchanged.
class PanelSwitch extends StatelessWidget {
  const PanelSwitch({super.key, required this.label, required this.value, required this.onChanged, this.description});

  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: OptionSwitch(label: label, description: description, value: value, onChanged: onChanged),
  );
}
