/// Type-aware editor for a single JSON value (string / number / boolean /
/// null, or a new empty object / array).
library;

import 'package:flutter/material.dart';

import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/json_tree_ops.dart';

/// Wrapper so that `null` (a valid JSON value) differs from "cancelled".
class EditedValue {
  const EditedValue(this.value);
  final Object? value;
}

enum ValueKind {
  string('String'),
  number('Number'),
  boolean('Boolean'),
  nul('Null'),
  object('Empty object {}'),
  array('Empty array []');

  const ValueKind(this.label);
  final String label;
}

ValueKind _kindOf(Object? v) => switch (v) {
  String() => ValueKind.string,
  num() => ValueKind.number,
  bool() => ValueKind.boolean,
  null => ValueKind.nul,
  Map<Object?, Object?>() => ValueKind.object,
  _ => ValueKind.array,
};

/// Shows the editor. [keyLabel] adds a key field (for new properties) whose
/// value is validated with [keyValidator].
Future<(String?, EditedValue)?> showValueEditor(
  BuildContext context, {
  required String title,
  Object? initial = '',
  String? keyLabel,
  String? Function(String key)? keyValidator,
}) {
  return showDialog<(String?, EditedValue)>(
    context: context,
    builder: (_) => _ValueEditorDialog(title: title, initial: initial, keyLabel: keyLabel, keyValidator: keyValidator),
  );
}

class _ValueEditorDialog extends StatefulWidget {
  const _ValueEditorDialog({required this.title, required this.initial, this.keyLabel, this.keyValidator});
  final String title;
  final Object? initial;
  final String? keyLabel;
  final String? Function(String key)? keyValidator;

  @override
  State<_ValueEditorDialog> createState() => _ValueEditorDialogState();
}

class _ValueEditorDialogState extends State<_ValueEditorDialog> {
  late ValueKind _kind = _kindOf(widget.initial);
  late final TextEditingController _text = TextEditingController(
    text: switch (widget.initial) {
      String() => widget.initial! as String,
      num() => '${widget.initial}',
      _ => '',
    },
  );
  final TextEditingController _key = TextEditingController();
  late bool _bool = widget.initial == true;
  String? _error;
  String? _keyError;

  @override
  void dispose() {
    _text.dispose();
    _key.dispose();
    super.dispose();
  }

  void _submit() {
    String? key;
    if (widget.keyLabel != null) {
      key = _key.text;
      final ke = widget.keyValidator?.call(key);
      if (ke != null) {
        setState(() => _keyError = ke);
        return;
      }
    }
    try {
      final Object? value = switch (_kind) {
        ValueKind.string => parseScalarInput(ScalarKind.string, _text.text),
        ValueKind.number => parseScalarInput(ScalarKind.number, _text.text),
        ValueKind.boolean => _bool,
        ValueKind.nul => null,
        ValueKind.object => <String, Object?>{},
        ValueKind.array => <Object?>[],
      };
      Navigator.of(context).pop((key, EditedValue(value)));
    } on JsonEditError catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.keyLabel != null) ...[
                TextField(
                  controller: _key,
                  autofocus: true,
                  style: J3Type.code,
                  decoration: InputDecoration(labelText: widget.keyLabel, errorText: _keyError),
                ),
                const SizedBox(height: J3Space.md),
              ],
              ChoiceRow<ValueKind>(
                label: 'Type',
                options: ValueKind.values,
                selected: _kind,
                labelOf: (k) => k.label,
                onSelected: (k) => setState(() {
                  _kind = k;
                  _error = null;
                }),
              ),
              const SizedBox(height: J3Space.md),
              if (_kind == ValueKind.string || _kind == ValueKind.number)
                TextField(
                  controller: _text,
                  autofocus: widget.keyLabel == null,
                  style: J3Type.code,
                  minLines: 1,
                  maxLines: _kind == ValueKind.string ? 6 : 1,
                  keyboardType: _kind == ValueKind.number
                      ? const TextInputType.numberWithOptions(decimal: true, signed: true)
                      : TextInputType.multiline,
                  decoration: InputDecoration(
                    labelText: _kind == ValueKind.number ? 'Number (e.g. 42, -3.5, 1e6)' : 'Text',
                    errorText: _error,
                  ),
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                ),
              if (_kind == ValueKind.boolean)
                ChoiceRow<bool>(
                  label: 'Value',
                  options: const [true, false],
                  selected: _bool,
                  labelOf: (b) => '$b',
                  onSelected: (b) => setState(() => _bool = b),
                ),
              if (_kind == ValueKind.nul) Text('The value will be null.', style: J3Type.bodySecondary),
              if (_kind == ValueKind.object || _kind == ValueKind.array)
                Text('Creates an empty container you can fill from the tree.', style: J3Type.bodySecondary),
            ],
          ),
        ),
      ),
      actions: [
        NeonButton.secondary(label: 'Cancel', dense: true, onPressed: () => Navigator.of(context).pop()),
        NeonButton(label: 'Apply', dense: true, onPressed: _submit),
      ],
    );
  }
}
