import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/platform/file_access.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/text_codec.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/line_endings.dart';
import '../shared.dart';
import '../text_batch.dart';

const String kLineEndingsToolId = 'files.line_endings';

final lineEndingBatchProvider =
    NotifierProvider<TextBatchController<LineEndingChange>, TextBatchState<LineEndingChange>>(
      () => TextBatchController<LineEndingChange>(kLineEndingsToolId, 'Convert'),
    );

/// Line Endings tool: analyse and convert LF / CRLF / CR.
class LineEndingsPage extends ConsumerWidget {
  const LineEndingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.draft<TextOrFiles>('$kLineEndingsToolId/mode', TextOrFiles.text);
    final target = ref.draft<LineEnding>('$kLineEndingsToolId/target', LineEnding.lf);

    final options = NeonPanel(
      kicker: 'Convert',
      title: 'Target line ending',
      icon: Icons.keyboard_return,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChoiceRow<TextOrFiles>(
            label: 'Input',
            options: TextOrFiles.values,
            selected: mode,
            labelOf: (m) => m.label,
            onSelected: (m) => ref.setDraft('$kLineEndingsToolId/mode', m),
          ),
          const SizedBox(height: J3Space.md),
          ChoiceRow<LineEnding>(
            label: 'Convert to',
            options: lineEndingTargets,
            selected: target,
            labelOf: lineEndingChoiceLabel,
            onSelected: (t) {
              ref.setDraft('$kLineEndingsToolId/target', t);
              ref.read(lineEndingBatchProvider.notifier).invalidateResults();
            },
          ),
        ],
      ),
    );

    if (mode == TextOrFiles.text) {
      return ToolScaffold(
        toolId: kLineEndingsToolId,
        inputs: [options, const _TextInput()],
        results: [_TextAnalysis(target: target)],
      );
    }
    return ToolScaffold(
      toolId: kLineEndingsToolId,
      inputs: [
        options,
        BatchSourcePanel<LineEndingChange>(toolId: kLineEndingsToolId, provider: lineEndingBatchProvider),
      ],
      results: [
        BatchResultsPanel<LineEndingChange>(
          toolId: kLineEndingsToolId,
          provider: lineEndingBatchProvider,
          transform: () => lineEndingTransform(target),
          describeStats: (s) => s.describe(),
          applyLabel: 'Convert files',
          exportSuffix: '-${target.label.toLowerCase()}',
        ),
      ],
    );
  }
}

class _TextInput extends ConsumerWidget {
  const _TextInput();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NeonPanel(
      kicker: 'Input',
      title: 'Text',
      icon: Icons.notes,
      child: CodeField(
        key: const Key('le.text'),
        controller: ref.watch(draftTextProvider('$kLineEndingsToolId/text')),
        label: 'Paste text to analyse',
        minLines: 6,
        maxLines: 14,
      ),
    );
  }
}

class _TextAnalysis extends ConsumerWidget {
  const _TextAnalysis({required this.target});
  final LineEnding target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(draftTextProvider('$kLineEndingsToolId/text'));
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: c,
      builder: (context, v, _) {
        final text = v.text;
        if (text.isEmpty) {
          return const NeonPanel(
            emphasis: PanelEmphasis.subtle,
            child: EmptyState(
              glyph: '[ CR LF ]',
              title: 'Paste text to analyse',
              message: 'Or switch to Files to convert workspace files in place (with backups).',
            ),
          );
        }
        final before = countLineEndings(text);
        final converted = convertLineEndings(text, target);
        final after = countLineEndings(converted);
        final lines = TextCodec.splitLines(text).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NeonPanel(
              kicker: 'Analysis',
              title: before.total == 0 ? 'No line breaks' : 'Detected: ${before.kind.label}',
              icon: Icons.analytics_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CountsRow(label: 'Before', counts: before),
                  const SizedBox(height: J3Space.sm),
                  _CountsRow(label: 'After', counts: after),
                  const SizedBox(height: J3Space.sm),
                  Wrap(
                    spacing: J3Space.sm,
                    runSpacing: J3Space.xs,
                    children: [
                      if (before.mixed)
                        const StatusBadge(kind: StatusKind.warning, text: 'MIXED line endings')
                      else
                        const StatusBadge(kind: StatusKind.success, text: 'consistent'),
                      StatusBadge(
                        kind: converted == text ? StatusKind.neutral : StatusKind.info,
                        text: converted == text
                            ? 'already ${target.label}'
                            : '${before.total - (target == LineEnding.lf
                                      ? before.lf
                                      : target == LineEnding.crlf
                                      ? before.crlf
                                      : before.cr)} to change',
                      ),
                      Text('$lines lines', style: J3Type.caption),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: J3Space.md),
            NeonPanel(
              kicker: 'Preview',
              title: 'Converted (first 40 lines, endings shown)',
              icon: Icons.visibility_outlined,
              actions: [
                IconButton(
                  tooltip: 'Copy converted text',
                  onPressed: () async {
                    await ref.read(fileAccessProvider).copyText(converted);
                    ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Copied ${after.total} lines');
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                ),
                IconButton(
                  tooltip: 'Save / export converted text',
                  onPressed: () => saveOutput(
                    context,
                    ref,
                    suggestedName: 'converted-${target.label.toLowerCase()}.txt',
                    bytes: Uint8List.fromList(utf8.encode(converted)),
                    mimeType: 'text/plain',
                    toolId: kLineEndingsToolId,
                  ),
                  icon: const Icon(Icons.save_alt_rounded, size: 18),
                ),
              ],
              child: Container(
                constraints: const BoxConstraints(maxHeight: 320),
                padding: const EdgeInsets.all(J3Space.md),
                decoration: BoxDecoration(
                  color: J3Colors.inputFill,
                  borderRadius: J3Radius.small,
                  border: Border.all(color: J3Colors.border),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    visualizeLineEndings(converted),
                    key: const Key('le.preview'),
                    style: J3Type.codeSmall.copyWith(color: J3Colors.text),
                  ),
                ),
              ),
            ),
            const SizedBox(height: J3Space.sm),
            const InfoLine('Markers: «LF», «CRLF», «CR». Files keep their encoding when converted in Files mode.'),
          ],
        );
      },
    );
  }
}

class _CountsRow extends StatelessWidget {
  const _CountsRow({required this.label, required this.counts});
  final String label;
  final LineEndingCounts counts;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: J3Space.sm,
      runSpacing: J3Space.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('$label:', style: J3Type.label),
        StatTile(label: 'LF', value: '${counts.lf}', icon: Icons.subdirectory_arrow_left),
        StatTile(label: 'CRLF', value: '${counts.crlf}', icon: Icons.keyboard_return),
        StatTile(label: 'CR', value: '${counts.cr}', icon: Icons.keyboard_tab),
      ],
    );
  }
}
