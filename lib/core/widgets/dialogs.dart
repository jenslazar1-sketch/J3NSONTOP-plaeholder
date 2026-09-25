import 'package:flutter/material.dart';

import '../theme/j3_colors.dart';
import '../theme/j3_spacing.dart';
import '../theme/j3_typography.dart';
import 'neon_button.dart';

/// Confirmation dialog. Destructive confirmations use the danger style and
/// default focus on Cancel.
Future<bool> showJ3Confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool destructive = false,
  List<String> details = const [],
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          Icon(destructive ? Icons.warning_amber_rounded : Icons.help_outline, color: destructive ? J3Colors.warning : J3Colors.info),
          const SizedBox(width: J3Space.sm),
          Expanded(child: Text(title)),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message, style: J3Type.body),
              if (details.isNotEmpty) ...[
                const SizedBox(height: J3Space.md),
                for (final d in details.take(30)) Text('> $d', style: J3Type.codeSmall),
                if (details.length > 30) Text('... ${details.length - 30} more', style: J3Type.caption),
              ],
            ],
          ),
        ),
      ),
      actions: [
        NeonButton.secondary(label: cancelLabel, onPressed: () => Navigator.of(ctx).pop(false), dense: true),
        destructive
            ? NeonButton.danger(label: confirmLabel, onPressed: () => Navigator.of(ctx).pop(true), dense: true)
            : NeonButton(label: confirmLabel, onPressed: () => Navigator.of(ctx).pop(true), dense: true),
      ],
    ),
  );
  return result ?? false;
}

/// Single text input dialog with validation.
Future<String?> showJ3TextInput(
  BuildContext context, {
  required String title,
  String? label,
  String initial = '',
  String confirmLabel = 'OK',
  String? Function(String value)? validator,
  bool monospace = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _TextInputDialog(
      title: title,
      label: label,
      initial: initial,
      confirmLabel: confirmLabel,
      validator: validator,
      monospace: monospace,
    ),
  );
}

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.confirmLabel,
    required this.validator,
    required this.monospace,
  });

  final String title;
  final String? label;
  final String initial;
  final String confirmLabel;
  final String? Function(String value)? validator;
  final bool monospace;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _c = TextEditingController(text: widget.initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
    final err = widget.validator?.call(_c.text);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.of(context).pop(_c.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        child: TextField(
          controller: _c,
          autofocus: true,
          style: widget.monospace ? J3Type.code : J3Type.body,
          decoration: InputDecoration(labelText: widget.label, errorText: _error),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        NeonButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop(), dense: true),
        NeonButton(label: widget.confirmLabel, onPressed: _submit, dense: true),
      ],
    );
  }
}
