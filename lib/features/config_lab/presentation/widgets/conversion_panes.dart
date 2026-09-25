/// Shared conversion UI: the output + itemised report view, the JSON input
/// panel used by "From JSON" panes, and the tracked conversion runner.
library;

import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/conversion_report.dart';
import '../../domain/json_tools.dart' show kSyncParseLimit;
import '../document_io.dart';
import 'lab_widgets.dart';

/// Runs a conversion as a tracked operation; inputs larger than 256 KiB are
/// converted in a background isolate. [compute] must only capture sendable
/// values (text and options), never providers or widgets.
Future<ConversionResult> runConversion(
  Ref ref, {
  required String toolId,
  required String title,
  required int inputLength,
  required ConversionResult Function() compute,
}) {
  return ref
      .read(activityProvider.notifier)
      .run<ConversionResult>(
        toolId: toolId,
        title: '$title (${Fmt.bytes(inputLength)})',
        notify: false,
        body: (op) async => inputLength > kSyncParseLimit ? Isolate.run(compute) : compute(),
        summary: (r) =>
            '${r.report.verdict}: ${r.report.errors.length} error(s), ${r.report.losses.length} change(s), ${r.report.notes.length} note(s)',
        counts: (r) => {
          'errors': r.report.errors.length,
          'changes': r.report.losses.length,
          'notes': r.report.notes.length,
        },
      );
}

/// Output text (copy / save) plus its conversion report.
class ConversionOutputView extends StatelessWidget {
  const ConversionOutputView({
    super.key,
    required this.result,
    required this.toolId,
    required this.fileName,
    required this.mimeType,
    this.stale = false,
    this.onJumpToLine,
    this.onUse,
    this.useLabel = 'Use as editor text',
  });

  final ConversionResult result;
  final String toolId;
  final String fileName;
  final String mimeType;

  /// The source changed after this conversion.
  final bool stale;
  final void Function(int line)? onJumpToLine;

  /// Replaces the editor text with the output (From JSON panes).
  final VoidCallback? onUse;
  final String useLabel;

  @override
  Widget build(BuildContext context) {
    final out = result.output;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (stale) ...[
          const LabHint('The input changed after this conversion. Convert again to refresh.', icon: Icons.history),
          const SizedBox(height: J3Space.sm),
        ],
        ConversionReportView(report: result.report, onJumpToLine: onJumpToLine),
        if (out != null) ...[
          const SizedBox(height: J3Space.md),
          ResultPanel(
            text: out,
            kicker: 'OUTPUT',
            title: '${result.report.to} (${Fmt.bytes(out.length)})',
            fileName: fileName,
            mimeType: mimeType,
            toolId: toolId,
            maxHeight: 360,
            extraActions: [
              if (onUse != null)
                IconButton(tooltip: useLabel, onPressed: onUse, icon: const Icon(Icons.input_rounded, size: 18)),
            ],
          ),
        ],
      ],
    );
  }
}

/// JSON input panel for "From JSON" conversions: editor, open file and a
/// convert button, with options between.
class JsonInputPanel extends ConsumerWidget {
  const JsonInputPanel({
    super.key,
    required this.controller,
    required this.convertLabel,
    required this.onConvert,
    this.options = const [],
    this.busy = false,
    this.hint = '{"key": "value"}',
  });

  final TextEditingController controller;
  final String convertLabel;
  final VoidCallback onConvert;
  final List<Widget> options;
  final bool busy;
  final String hint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NeonPanel(
      kicker: 'JSON INPUT',
      title: 'Source JSON',
      padding: const EdgeInsets.all(J3Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CodeField(controller: controller, label: 'JSON', hint: hint, minLines: 6, maxLines: 14),
          const SizedBox(height: J3Space.sm),
          ...options,
          const SizedBox(height: J3Space.sm),
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              NeonButton.secondary(
                label: 'Open JSON file',
                icon: Icons.folder_open,
                dense: true,
                onPressed: () async {
                  final r = await readInputFile(
                    context,
                    ref,
                    extensions: const ['json', 'txt'],
                    title: 'Open JSON file',
                  );
                  if (r != null) controller.text = r.$1;
                },
              ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, v, _) => NeonButton(
                  label: convertLabel,
                  icon: Icons.swap_horiz,
                  busy: busy,
                  onPressed: v.text.trim().isEmpty ? null : onConvert,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Replaces the editor text with converted output after confirming when
/// the editor has unsaved changes.
Future<void> useAsEditorText(
  BuildContext context,
  WidgetRef ref, {
  required String docKey,
  required TextEditingController editor,
  required String text,
}) async {
  final source = ref.read(docSourceProvider(docKey));
  if (editor.text.trim().isNotEmpty && source.isDirty(editor.text)) {
    final ok = await showJ3Confirm(
      context,
      title: 'Replace the editor text?',
      message: 'The editor has unsaved changes that will be replaced by the converted output.',
      confirmLabel: 'Replace',
      destructive: true,
    );
    if (!ok) return;
  }
  editor.value = TextEditingValue(text: text, selection: const TextSelection.collapsed(offset: 0));
  ref.read(activityProvider.notifier).notify(NoticeKind.info, 'Editor text replaced with the converted output');
}
