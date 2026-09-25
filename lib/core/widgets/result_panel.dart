import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../activity/activity_controller.dart';
import '../theme/effects.dart';
import '../theme/j3_colors.dart';
import '../theme/j3_spacing.dart';
import '../theme/j3_typography.dart';
import '../utils/text_codec.dart';
import 'io_flows.dart';
import 'neon_panel.dart';

/// Displays textual output with Copy / Save / Share actions. Large outputs
/// switch to a virtualised line list so the UI stays responsive.
class ResultPanel extends ConsumerWidget {
  const ResultPanel({
    super.key,
    required this.text,
    this.title = 'Result',
    this.kicker = 'OUTPUT',
    this.fileName = 'result.txt',
    this.mimeType = 'text/plain',
    this.toolId = 'core.result',
    this.maxHeight = 420,
    this.lineNumbers = false,
    this.extraActions = const [],
    this.emphasis = PanelEmphasis.normal,
    this.footer,
  });

  final String text;
  final String title;
  final String kicker;
  final String fileName;
  final String mimeType;
  final String toolId;
  final double maxHeight;
  final bool lineNumbers;
  final List<Widget> extraActions;
  final PanelEmphasis emphasis;
  final Widget? footer;

  static const int _virtualizeAbove = 2000;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = TextCodec.splitLines(text);
    final virtualize = lines.length > _virtualizeAbove || lineNumbers;
    final gutter = lines.length.toString().length;

    Widget body;
    if (text.isEmpty) {
      body = Text('(empty)', style: J3Type.codeSmall.copyWith(color: J3Colors.textMuted));
    } else if (virtualize) {
      body = SizedBox(
        height: maxHeight,
        child: SelectionArea(
          child: Scrollbar(
            child: ListView.builder(
              itemCount: lines.length,
              itemExtent: 20,
              itemBuilder: (context, i) => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (lineNumbers)
                    SizedBox(
                      width: gutter * 9.0 + 14,
                      child: Text('${i + 1}'.padLeft(gutter), style: J3Type.codeSmall.copyWith(color: J3Colors.textMuted)),
                    ),
                  Expanded(child: Text(lines[i], style: J3Type.code, softWrap: false, overflow: TextOverflow.fade)),
                ],
              ),
            ),
          ),
        ),
      );
    } else {
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Scrollbar(
          child: SingleChildScrollView(child: SelectableText(text, style: J3Type.code)),
        ),
      );
    }

    return NeonPanel(
      kicker: kicker,
      title: title,
      emphasis: emphasis,
      actions: [
        ...extraActions,
        IconButton(
          tooltip: 'Copy',
          onPressed: text.isEmpty
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Copied ${text.length} characters');
                },
          icon: const Icon(Icons.copy_rounded, size: 18),
        ),
        IconButton(
          tooltip: 'Save / export',
          onPressed: text.isEmpty
              ? null
              : () => saveOutput(context, ref, suggestedName: fileName, bytes: Uint8List.fromList(utf8.encode(text)), mimeType: mimeType, toolId: toolId),
          icon: const Icon(Icons.save_alt_rounded, size: 18),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(J3Space.md),
            decoration: BoxDecoration(
              color: J3Colors.inputFill,
              borderRadius: J3Radius.small,
              border: Border.all(color: J3Colors.border),
            ),
            child: body,
          ),
          if (footer != null) ...[const SizedBox(height: J3Space.sm), footer!],
          if (virtualize && text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: J3Space.xs),
              child: Text('${lines.length} lines', style: J3Type.codeSmall.copyWith(color: context.effects.accentText)),
            ),
        ],
      ),
    );
  }
}
