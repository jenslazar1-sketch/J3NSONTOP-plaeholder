import 'package:flutter/material.dart';

import '../theme/effects.dart';
import '../theme/j3_colors.dart';
import '../theme/j3_spacing.dart';
import '../theme/j3_typography.dart';
import '../utils/text_codec.dart';

/// Monospaced multi-line input for code, JSON, logs and free text.
/// Shows a live `Ln/Col` + size status line and supports jumping to an
/// error location via [CodeFieldController.jumpTo].
class CodeField extends StatefulWidget {
  const CodeField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.minLines = 6,
    this.maxLines = 18,
    this.readOnly = false,
    this.errorText,
    this.onChanged,
    this.focusNode,
    this.wrap = true,
    this.showStatus = true,
    this.expands = false,
  });

  final TextEditingController controller;
  final String? label;
  final String? hint;
  final int minLines;

  /// Visible lines before scrolling. Ignored when [expands] is true.
  final int maxLines;
  final bool readOnly;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final bool wrap;
  final bool showStatus;

  /// Fill the parent's height (parent must bound the height).
  final bool expands;

  @override
  State<CodeField> createState() => _CodeFieldState();
}

class _CodeFieldState extends State<CodeField> {
  late FocusNode _focus = widget.focusNode ?? FocusNode();

  @override
  void didUpdateWidget(CodeField old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      if (old.focusNode == null) _focus.dispose();
      _focus = widget.focusNode ?? FocusNode();
    }
  }

  @override
  void dispose() {
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final field = TextField(
      controller: widget.controller,
      focusNode: _focus,
      readOnly: widget.readOnly,
      onChanged: widget.onChanged,
      minLines: widget.expands ? null : widget.minLines,
      maxLines: widget.expands ? null : widget.maxLines,
      expands: widget.expands,
      keyboardType: TextInputType.multiline,
      textAlignVertical: TextAlignVertical.top,
      autocorrect: false,
      enableSuggestions: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      style: J3Type.code,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        errorText: widget.errorText,
        alignLabelWithHint: true,
        hintStyle: J3Type.code.copyWith(color: J3Colors.textMuted),
      ),
    );

    if (!widget.showStatus) return field;
    final status = ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final offset = value.selection.baseOffset < 0 ? value.text.length : value.selection.baseOffset;
        final (line, col) = TextCodec.lineColumn(value.text, offset);
        final lines = value.text.isEmpty ? 0 : TextCodec.splitLines(value.text).length;
        return Padding(
          padding: const EdgeInsets.only(top: J3Space.xs, left: J3Space.xs),
          child: Text(
            'Ln $line, Col $col  |  $lines lines  |  ${value.text.length} chars',
            style: J3Type.codeSmall.copyWith(color: _focus.hasFocus ? fx.accentText : J3Colors.textMuted),
          ),
        );
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: widget.expands ? MainAxisSize.max : MainAxisSize.min,
      children: [
        widget.expands ? Expanded(child: field) : field,
        status,
      ],
    );
  }
}

extension CodeFieldJump on TextEditingController {
  /// Moves the caret to a 1-based [line]/[column].
  void jumpTo(int line, int column) {
    final lines = TextCodec.splitLines(text);
    var offset = 0;
    for (var i = 0; i < line - 1 && i < lines.length; i++) {
      offset += lines[i].length + 1;
    }
    offset = (offset + column - 1).clamp(0, text.length);
    selection = TextSelection.collapsed(offset: offset);
  }
}
