import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/platform/file_access.dart';
import '../../../../core/text/diff.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/text_codec.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/line_endings.dart';
import '../../domain/whitespace.dart';
import '../shared.dart';
import '../text_batch.dart';

const String kWhitespaceToolId = 'files.whitespace';

/// Inputs above this size are previewed on request instead of live.
const int kLivePreviewChars = 256 * 1024;

final whitespaceBatchProvider = NotifierProvider<TextBatchController<WhitespaceStats>, TextBatchState<WhitespaceStats>>(
  () => TextBatchController<WhitespaceStats>(kWhitespaceToolId, 'Clean'),
);

/// Current options (draft value, survives tool switches).
WhitespaceOptions readWhitespaceOptions(WidgetRef ref) =>
    ref.draft<WhitespaceOptions>('$kWhitespaceToolId/options', const WhitespaceOptions());

/// Same as [readWhitespaceOptions] without subscribing (for initState).
WhitespaceOptions readWhitespaceOptionsOnce(WidgetRef ref) {
  final v = ref.read(draftValueProvider('$kWhitespaceToolId/options'));
  return v is WhitespaceOptions ? v : const WhitespaceOptions();
}

/// Whitespace Cleanup tool.
class WhitespacePage extends ConsumerWidget {
  const WhitespacePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.draft<TextOrFiles>('$kWhitespaceToolId/mode', TextOrFiles.text);
    final options = readWhitespaceOptions(ref);

    final modePanel = NeonPanel(
      kicker: 'Mode',
      title: 'Input',
      icon: Icons.tune,
      child: ChoiceRow<TextOrFiles>(
        label: 'Clean',
        options: TextOrFiles.values,
        selected: mode,
        labelOf: (m) => m.label,
        onSelected: (m) => ref.setDraft('$kWhitespaceToolId/mode', m),
      ),
    );

    if (mode == TextOrFiles.text) {
      return ToolScaffold(
        toolId: kWhitespaceToolId,
        inputs: [modePanel, const _OptionsPanel(), const _TextInput()],
        results: [_TextPreview(options: options)],
      );
    }
    return ToolScaffold(
      toolId: kWhitespaceToolId,
      inputs: [
        modePanel,
        const _OptionsPanel(),
        BatchSourcePanel<WhitespaceStats>(toolId: kWhitespaceToolId, provider: whitespaceBatchProvider),
      ],
      results: [
        BatchResultsPanel<WhitespaceStats>(
          toolId: kWhitespaceToolId,
          provider: whitespaceBatchProvider,
          transform: () => whitespaceTransform(options),
          describeStats: (s) {
            final d = s.describe();
            return d.isEmpty ? 'clean' : d.join('; ');
          },
          applyLabel: 'Clean files',
          exportSuffix: '-clean',
        ),
      ],
    );
  }
}

class _OptionsPanel extends ConsumerStatefulWidget {
  const _OptionsPanel();

  @override
  ConsumerState<_OptionsPanel> createState() => _OptionsPanelState();
}

class _OptionsPanelState extends ConsumerState<_OptionsPanel> {
  @override
  void initState() {
    super.initState();
    // Seed the number fields once, before anything listens to them.
    final o = readWhitespaceOptionsOnce(ref);
    final tabCtl = ref.read(draftTextProvider('$kWhitespaceToolId/tabWidth'));
    final blankCtl = ref.read(draftTextProvider('$kWhitespaceToolId/maxBlank'));
    if (tabCtl.text.isEmpty) tabCtl.text = '${o.tabWidth}';
    if (blankCtl.text.isEmpty) blankCtl.text = '${o.maxBlankLines}';
  }

  @override
  Widget build(BuildContext context) {
    final o = readWhitespaceOptions(ref);
    final tabCtl = ref.watch(draftTextProvider('$kWhitespaceToolId/tabWidth'));
    final blankCtl = ref.watch(draftTextProvider('$kWhitespaceToolId/maxBlank'));

    void set(WhitespaceOptions next) {
      ref.setDraft('$kWhitespaceToolId/options', next);
      ref.read(whitespaceBatchProvider.notifier).invalidateResults();
    }

    return NeonPanel(
      kicker: 'Rules',
      title: 'Cleanup options',
      icon: Icons.cleaning_services_outlined,
      child: InkSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OptionSwitch(
              label: 'Trim trailing whitespace',
              description: 'Spaces and tabs at the end of each line',
              value: o.trimTrailing,
              onChanged: (v) => set(o.copyWith(trimTrailing: v)),
            ),
            OptionSwitch(
              label: 'Collapse blank lines',
              description: 'Runs of blank lines longer than the maximum below',
              value: o.collapseBlankLines,
              onChanged: (v) => set(o.copyWith(collapseBlankLines: v)),
            ),
            if (o.collapseBlankLines)
              Padding(
                padding: const EdgeInsets.only(left: J3Space.lg, bottom: J3Space.sm),
                child: NumberField(
                  controller: blankCtl,
                  label: 'Max blank lines',
                  min: 0,
                  max: 10,
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n != null && n >= 0 && n <= 10) set(o.copyWith(maxBlankLines: n));
                  },
                ),
              ),
            OptionSwitch(
              label: 'Exactly one final newline',
              description: 'Remove trailing blank lines, add a missing last line break',
              value: o.ensureFinalNewline,
              onChanged: (v) => set(o.copyWith(ensureFinalNewline: v)),
            ),
            OptionSwitch(
              label: 'Strip UTF-8 BOM',
              description: 'Files are saved as plain UTF-8 (UTF-16 keeps its BOM)',
              value: o.stripBom,
              onChanged: (v) => set(o.copyWith(stripBom: v)),
            ),
            OptionSwitch(
              label: 'Fix special spaces',
              description: 'NBSP/figure spaces → space; remove zero-width spaces and word joiners (ZWJ/ZWNJ kept)',
              value: o.replaceSpecialSpaces,
              onChanged: (v) => set(o.copyWith(replaceSpecialSpaces: v)),
            ),
            OptionSwitch(
              label: 'Normalise line endings',
              description: 'Otherwise each line keeps its own ending',
              value: o.normalizeLineEndings,
              onChanged: (v) => set(o.copyWith(normalizeLineEndings: v)),
            ),
            if (o.normalizeLineEndings)
              Padding(
                padding: const EdgeInsets.only(left: J3Space.lg, bottom: J3Space.sm),
                child: ChoiceRow<LineEnding>(
                  label: 'Line ending',
                  options: lineEndingTargets,
                  selected: o.lineEnding,
                  labelOf: lineEndingChoiceLabel,
                  onSelected: (e) => set(o.copyWith(lineEnding: e)),
                ),
              ),
            const SizedBox(height: J3Space.sm),
            ChoiceRow<IndentMode>(
              label: 'Indentation',
              options: IndentMode.values,
              selected: o.indentMode,
              labelOf: (m) => m.label,
              onSelected: (m) => set(o.copyWith(indentMode: m)),
            ),
            if (o.indentMode != IndentMode.keep) ...[
              const SizedBox(height: J3Space.sm),
              NumberField(
                controller: tabCtl,
                label: 'Tab width',
                min: 1,
                max: 16,
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null && n >= 1 && n <= 16) set(o.copyWith(tabWidth: n));
                },
              ),
            ],
            if (o.indentMode == IndentMode.tabsToSpaces)
              OptionSwitch(
                label: 'Also expand tabs inside lines',
                description: 'Off keeps tab-separated data (TSV) intact',
                value: o.expandInnerTabs,
                onChanged: (v) => set(o.copyWith(expandInnerTabs: v)),
              ),
          ],
        ),
      ),
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
        key: const Key('ws.text'),
        controller: ref.watch(draftTextProvider('$kWhitespaceToolId/text')),
        label: 'Paste text to clean',
        minLines: 6,
        maxLines: 14,
      ),
    );
  }
}

class _TextPreview extends ConsumerStatefulWidget {
  const _TextPreview({required this.options});
  final WhitespaceOptions options;

  @override
  ConsumerState<_TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends ConsumerState<_TextPreview> {
  /// Snapshot requested for preview when the input is too large for live.
  String? _requested;

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(draftTextProvider('$kWhitespaceToolId/text'));
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: c,
      builder: (context, v, _) {
        final text = v.text;
        if (text.isEmpty) {
          return const NeonPanel(
            emphasis: PanelEmphasis.subtle,
            child: EmptyState(
              glyph: '[ ·→· ]',
              title: 'Paste text to preview the cleanup',
              message: 'Changed lines are shown with invisible characters made visible.',
            ),
          );
        }
        if (text.length > kLivePreviewChars && _requested != text) {
          return NeonPanel(
            kicker: 'Preview',
            title: 'Large input',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Live preview pauses above ${kLivePreviewChars ~/ 1024}K characters so typing stays smooth.',
                  style: J3Type.bodySecondary,
                ),
                const SizedBox(height: J3Space.sm),
                NeonButton(
                  label: 'Preview now',
                  icon: Icons.visibility,
                  onPressed: () => setState(() => _requested = text),
                ),
              ],
            ),
          );
        }
        final result = cleanWhitespace(text, widget.options);
        final oldLines = TextCodec.splitLines(text).length;
        final newLines = TextCodec.splitLines(result.text).length;
        final diff = LineDiff.diffText(
          text,
          result.text,
          options: DiffOptions(maxEditDistance: previewDiffBudget(oldLines, newLines)),
        );
        return _PreviewBody(input: text, result: result, diff: diff);
      },
    );
  }
}

class _PreviewBody extends ConsumerWidget {
  const _PreviewBody({required this.input, required this.result, required this.diff});
  final String input;
  final WhitespaceResult result;
  final DiffResult diff;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final changes = result.stats.describe();
    final rows = _diffRows(diff);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeonPanel(
          kicker: 'Preview',
          title: result.changed ? 'Changes' : 'Already clean',
          icon: Icons.difference_outlined,
          emphasis: result.changed ? PanelEmphasis.normal : PanelEmphasis.success,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                children: [
                  StatTile(label: 'Lines changed', value: '${result.stats.linesChanged}', icon: Icons.edit_note),
                  StatTile(label: 'Diff −', value: '${diff.deletions}', icon: Icons.remove),
                  StatTile(label: 'Diff +', value: '${diff.insertions}', icon: Icons.add),
                ],
              ),
              const SizedBox(height: J3Space.sm),
              if (changes.isEmpty)
                const StatusBadge(kind: StatusKind.success, text: 'nothing to clean with these rules')
              else
                for (final c in changes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: InfoLine(c, icon: Icons.check),
                  ),
              if (result.stats.lineEndingsChanged > 0)
                const InfoLine('Line-ending-only changes are counted above; the diff compares line content.'),
              if (diff.truncated)
                const InfoLine(
                  'Many changes: the diff below is simplified to whole blocks.',
                  icon: Icons.warning_amber,
                ),
            ],
          ),
        ),
        if (rows.isNotEmpty) ...[
          const SizedBox(height: J3Space.md),
          NeonPanel(
            kicker: 'Diff',
            title: 'Changed lines (· space, → tab, ° no-break space, ¤ zero-width)',
            icon: Icons.compare,
            child: Container(
              padding: const EdgeInsets.all(J3Space.sm),
              decoration: BoxDecoration(
                color: J3Colors.inputFill,
                borderRadius: J3Radius.small,
                border: Border.all(color: J3Colors.border),
              ),
              child: BoundedList(
                itemCount: rows.length,
                inlineUpTo: 60,
                maxHeight: 360,
                itemBuilder: (context, i) => rows[i],
              ),
            ),
          ),
        ],
        const SizedBox(height: J3Space.md),
        NeonPanel(
          kicker: 'Output',
          title: 'Cleaned text',
          icon: Icons.output,
          actions: [
            IconButton(
              tooltip: 'Copy cleaned text',
              onPressed: () async {
                await ref.read(fileAccessProvider).copyText(result.text);
                ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Copied cleaned text');
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
            ),
            IconButton(
              tooltip: 'Save / export cleaned text',
              onPressed: () => saveOutput(
                context,
                ref,
                suggestedName: 'cleaned.txt',
                bytes: Uint8List.fromList(utf8.encode(result.text)),
                mimeType: 'text/plain',
                toolId: kWhitespaceToolId,
              ),
              icon: const Icon(Icons.save_alt_rounded, size: 18),
            ),
            IconButton(
              tooltip: 'Replace the input with the cleaned text',
              onPressed: result.changed
                  ? () => ref.read(draftTextProvider('$kWhitespaceToolId/text')).text = result.text
                  : null,
              icon: const Icon(Icons.published_with_changes, size: 18),
            ),
          ],
          child: Text(
            '${result.text.length} characters, ${TextCodec.splitLines(result.text).length} lines',
            style: J3Type.caption,
          ),
        ),
      ],
    );
  }
}

/// Changed lines with two lines of context; unchanged runs are collapsed.
List<Widget> _diffRows(DiffResult diff, {int context = 2, int maxRows = 600}) {
  final lines = diff.lines;
  final keep = List<bool>.filled(lines.length, false);
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].op == DiffOp.equal) continue;
    for (var j = (i - context).clamp(0, lines.length); j <= (i + context).clamp(0, lines.length - 1); j++) {
      keep[j] = true;
    }
  }
  final out = <Widget>[];
  var skipped = 0;
  for (var i = 0; i < lines.length && out.length < maxRows; i++) {
    if (!keep[i]) {
      skipped++;
      continue;
    }
    if (skipped > 0) {
      out.add(_gap(skipped));
      skipped = 0;
    }
    out.add(_DiffRow(line: lines[i]));
  }
  if (out.length >= maxRows) out.add(_gap(-1));
  return out;
}

Widget _gap(int n) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 2),
  child: Text(n < 0 ? '… more changes not shown' : '… $n unchanged line(s)', style: J3Type.caption),
);

class _DiffRow extends StatelessWidget {
  const _DiffRow({required this.line});
  final DiffLine line;

  @override
  Widget build(BuildContext context) {
    final (prefix, color, bg) = switch (line.op) {
      DiffOp.delete => ('-', J3Colors.error, J3Colors.error.withValues(alpha: 0.08)),
      DiffOp.insert => ('+', J3Colors.success, J3Colors.success.withValues(alpha: 0.08)),
      DiffOp.equal => (' ', J3Colors.textSecondary, Colors.transparent),
    };
    final number = line.op == DiffOp.insert ? line.newLine : line.oldLine;
    return Container(
      color: bg,
      child: Text(
        '$prefix${'${number ?? ''}'.padLeft(5)}  ${showInvisibles(line.text)}',
        style: J3Type.codeSmall.copyWith(color: color),
      ),
    );
  }
}
