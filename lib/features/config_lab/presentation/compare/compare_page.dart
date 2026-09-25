import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/text/diff.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/compare.dart';
import '../../domain/config_format.dart';
import '../../domain/semantic_diff.dart';
import '../document_io.dart';
import '../widgets/lab_widgets.dart';
import 'compare_controller.dart';

class ComparePage extends ConsumerStatefulWidget {
  const ComparePage({super.key});

  @override
  ConsumerState<ComparePage> createState() => _ComparePageState();
}

class _ComparePageState extends ConsumerState<ComparePage> {
  late final TextEditingController _a = ref.read(draftTextProvider(kCompareAKey));
  late final TextEditingController _b = ref.read(draftTextProvider(kCompareBKey));
  final FocusNode _focusA = FocusNode();
  final FocusNode _focusB = FocusNode();

  CompareController get _c => ref.read(compareProvider.notifier);

  @override
  void dispose() {
    _focusA.dispose();
    _focusB.dispose();
    super.dispose();
  }

  void _notify(NoticeKind kind, String message) => ref.read(activityProvider.notifier).notify(kind, message);

  Future<void> _open(bool sideA) async {
    final r = await readInputFile(
      context,
      ref,
      extensions: const ['json', 'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf', 'txt'],
      title: 'Open ${sideA ? 'A (before)' : 'B (after)'}',
    );
    if (r == null) return;
    (sideA ? _a : _b).text = r.$1;
    _c.setName(sideA, r.$2.displayName);
  }

  Future<void> _compare() async {
    if (_a.text.trim().isEmpty && _b.text.trim().isEmpty) {
      _notify(NoticeKind.info, 'Paste or open two documents to compare.');
      return;
    }
    try {
      await _c.compare();
    } catch (e) {
      _notify(NoticeKind.error, 'Comparison failed: $e');
    }
  }

  String _report(CompareState s) => compareReport(s.result!, nameA: s.resultNameA, nameB: s.resultNameB);

  Future<void> _export(CompareState s) async {
    await saveOutput(
      context,
      ref,
      suggestedName: 'config-comparison.txt',
      bytes: Uint8List.fromList(utf8.encode(_report(s))),
      mimeType: 'text/plain',
      toolId: kCompareToolId,
    );
  }

  void _jump(bool sideA, int line, int column) {
    (sideA ? _focusA : _focusB).requestFocus();
    (sideA ? _a : _b).jumpTo(line, column);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(compareProvider);
    final r = s.result;
    return ToolScaffold(
      toolId: kCompareToolId,
      children: [
        LayoutBuilder(
          builder: (context, c) {
            final inputA = _inputPanel(s, true);
            final inputB = _inputPanel(s, false);
            if (c.maxWidth >= 900) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: inputA),
                  const SizedBox(width: J3Space.lg),
                  Expanded(child: inputB),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                inputA,
                const SizedBox(height: J3Space.lg),
                inputB,
              ],
            );
          },
        ),
        _optionsPanel(s),
        if (r != null) ..._results(s, r),
      ],
    );
  }

  Widget _inputPanel(CompareState s, bool sideA) {
    final controller = sideA ? _a : _b;
    final manual = sideA ? s.formatA : s.formatB;
    final name = sideA ? s.nameA : s.nameB;
    return NeonPanel(
      kicker: sideA ? 'A // BEFORE' : 'B // AFTER',
      title: name,
      padding: const EdgeInsets.all(J3Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, v, _) {
              // Detection preview only for moderate sizes (it parses on the UI thread).
              final detected = v.text.trim().isEmpty || v.text.length > 64 * 1024 ? null : _c.resolved(sideA, v.text);
              return ChoiceRow<ConfigFormat?>(
                label: 'Format',
                options: const [null, ...ConfigFormat.values],
                selected: manual,
                labelOf: (f) =>
                    f == null ? 'Auto${manual == null && detected != null ? ' (${detected.label})' : ''}' : f.label,
                onSelected: (f) => _c.setFormat(sideA, f),
              );
            },
          ),
          const SizedBox(height: J3Space.sm),
          CodeField(
            controller: controller,
            focusNode: sideA ? _focusA : _focusB,
            label: sideA ? 'Document A' : 'Document B',
            minLines: 8,
            maxLines: 16,
            wrap: false,
          ),
          const SizedBox(height: J3Space.sm),
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              NeonButton.secondary(
                label: 'Open file',
                icon: Icons.folder_open,
                dense: true,
                onPressed: () => _open(sideA),
              ),
              NeonButton.ghost(
                label: 'Clear',
                icon: Icons.backspace_outlined,
                dense: true,
                onPressed: () {
                  controller.clear();
                  _c.setName(sideA, sideA ? 'A' : 'B');
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _optionsPanel(CompareState s) {
    return NeonPanel(
      kicker: 'COMPARE',
      title: 'Semantic and text comparison',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LabHint(
            'Semantic diff compares the parsed data (key order ignored, arrays aligned). The text diff compares '
            'lines. Formats can differ: JSON on one side and YAML on the other is fine.',
          ),
          LabSwitch(
            label: 'Ignore whitespace in the text diff',
            value: s.ignoreWhitespace,
            onChanged: _c.setIgnoreWhitespace,
          ),
          ChoiceRow<DiffView>(
            label: 'Text diff view',
            options: DiffView.values,
            selected: s.view,
            labelOf: (v) => v == DiffView.unified ? 'Unified' : 'Side by side',
            onSelected: _c.setView,
          ),
          const SizedBox(height: J3Space.md),
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              NeonButton(label: 'Compare', icon: Icons.compare_arrows, busy: s.busy, onPressed: _compare),
              NeonButton.ghost(label: 'Swap A / B', icon: Icons.swap_vert, onPressed: _c.swap),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _results(CompareState s, CompareResult r) {
    final sem = r.semantic;
    final stale = s.comparedA != _a.text || s.comparedB != _b.text;
    return [
      NeonPanel(
        kicker: 'SUMMARY',
        title: '${s.resultNameA} (${r.a.format.label}) vs ${s.resultNameB} (${r.b.format.label})',
        actions: [
          IconButton(
            tooltip: 'Copy report',
            onPressed: () => copyWithNotice(ref, _report(s), 'comparison report'),
            icon: const Icon(Icons.copy_all_rounded, size: 18),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (stale) ...[
              const LabHint('The inputs changed after this comparison. Compare again to refresh.', icon: Icons.history),
              const SizedBox(height: J3Space.sm),
            ],
            Wrap(
              spacing: J3Space.sm,
              runSpacing: J3Space.sm,
              children: [
                if (sem != null && sem.identical) const StatusBadge(kind: StatusKind.success, text: 'SAME DATA'),
                if (sem != null) ...[
                  StatusBadge(kind: StatusKind.success, text: '+${sem.added} ADDED'),
                  StatusBadge(kind: StatusKind.error, text: '-${sem.removed} REMOVED'),
                  StatusBadge(kind: StatusKind.warning, text: '~${sem.changed} CHANGED'),
                  StatusBadge(kind: StatusKind.info, text: '!${sem.typeChanged} TYPE'),
                ],
                StatusBadge(
                  kind: r.text.identical ? StatusKind.success : StatusKind.neutral,
                  text: r.text.identical ? 'TEXT IDENTICAL' : 'TEXT +${r.text.insertions} -${r.text.deletions}',
                ),
              ],
            ),
            for (final n in {...r.a.notes, ...r.b.notes}) ...[const SizedBox(height: J3Space.xs), LabHint(n)],
            if (sem != null && sem.identical && !r.text.identical) ...[
              const SizedBox(height: J3Space.xs),
              const LabHint('Same data, different text: only formatting, order or comments differ.'),
            ],
            const SizedBox(height: J3Space.md),
            Align(
              alignment: Alignment.centerLeft,
              child: NeonButton.secondary(
                label: 'Export report',
                icon: Icons.save_alt_rounded,
                dense: true,
                onPressed: () => _export(s),
              ),
            ),
          ],
        ),
      ),
      if (!r.a.ok)
        ParseErrorPanel(error: r.a.error!, kicker: 'A: PARSE ERROR', onJump: (l) => _jump(true, l.line, l.column)),
      if (!r.b.ok)
        ParseErrorPanel(error: r.b.error!, kicker: 'B: PARSE ERROR', onJump: (l) => _jump(false, l.line, l.column)),
      if (sem != null && !sem.identical) _semanticPanel(sem),
      _textPanel(s, r),
    ];
  }

  Widget _semanticPanel(SemanticDiffResult sem) {
    return NeonPanel(
      kicker: 'SEMANTIC DIFF',
      title: '${sem.changes.length} change(s) in the data',
      child: Container(
        constraints: const BoxConstraints(maxHeight: 380),
        decoration: BoxDecoration(
          color: J3Colors.inputFill,
          borderRadius: J3Radius.small,
          border: Border.all(color: J3Colors.border),
        ),
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: sem.changes.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) => _changeTile(sem.changes[i]),
        ),
      ),
    );
  }

  Widget _changeTile(SemanticChange c) {
    final kind = switch (c.kind) {
      ChangeKind.added => StatusKind.success,
      ChangeKind.removed => StatusKind.error,
      ChangeKind.changed => StatusKind.warning,
      ChangeKind.typeChanged => StatusKind.info,
    };
    final detail = switch (c.kind) {
      ChangeKind.added => changeValueText(c.newValue),
      ChangeKind.removed => changeValueText(c.oldValue),
      _ => '${changeValueText(c.oldValue)}  ->  ${changeValueText(c.newValue)}',
    };
    return Padding(
      padding: const EdgeInsets.all(J3Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusBadge(kind: kind, text: c.kind.label, dense: true),
              SelectableText(c.pathLabel, style: J3Type.code.copyWith(color: J3Colors.text)),
            ],
          ),
          const SizedBox(height: 2),
          Text(detail, style: J3Type.codeSmall, maxLines: 3, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _textPanel(CompareState s, CompareResult r) {
    final lines = r.text.lines;
    return NeonPanel(
      kicker: 'TEXT DIFF',
      title: r.text.identical
          ? 'No line differences${r.ignoreWhitespace ? ' (whitespace ignored)' : ''}'
          : '+${r.text.insertions} / -${r.text.deletions} lines${r.text.truncated ? ' (coarse: very different inputs)' : ''}',
      actions: [
        IconButton(
          tooltip: 'Copy unified diff',
          onPressed: r.text.identical ? null : () => copyWithNotice(ref, r.unified, 'unified diff'),
          icon: const Icon(Icons.copy_rounded, size: 18),
        ),
      ],
      child: r.text.identical
          ? Text('The two texts are line-for-line identical.', style: J3Type.bodySecondary)
          : Container(
              height: 420,
              decoration: BoxDecoration(
                color: J3Colors.inputFill,
                borderRadius: J3Radius.small,
                border: Border.all(color: J3Colors.border),
              ),
              child: s.view == DiffView.unified ? _unified(lines) : _sideBySide(sideBySide(r.text)),
            ),
    );
  }

  static Color? _bg(DiffOp op) => switch (op) {
    DiffOp.insert => J3Colors.success.withValues(alpha: 0.10),
    DiffOp.delete => J3Colors.error.withValues(alpha: 0.10),
    DiffOp.equal => null,
  };

  Widget _unified(List<DiffLine> lines) {
    return ListView.builder(
      itemCount: lines.length,
      itemBuilder: (context, i) {
        final l = lines[i];
        final prefix = switch (l.op) {
          DiffOp.insert => '+',
          DiffOp.delete => '-',
          DiffOp.equal => ' ',
        };
        return Container(
          color: _bg(l.op),
          padding: const EdgeInsets.symmetric(horizontal: J3Space.sm, vertical: 1),
          child: Text(
            '${'${l.oldLine ?? ''}'.padLeft(4)} ${'${l.newLine ?? ''}'.padLeft(4)} $prefix ${l.text}',
            style: J3Type.codeSmall.copyWith(color: l.op == DiffOp.equal ? J3Colors.textMuted : J3Colors.text),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }

  Widget _sideBySide(List<SideBySideRow> rows) {
    Widget cell(DiffLine? l, bool left) {
      final op = l?.op ?? DiffOp.equal;
      final no = left ? l?.oldLine : l?.newLine;
      final mark = l == null ? ' ' : (op == DiffOp.equal ? ' ' : (left ? '-' : '+'));
      return Expanded(
        child: Container(
          color: l == null ? J3Colors.surface : _bg(op),
          padding: const EdgeInsets.symmetric(horizontal: J3Space.xs, vertical: 1),
          child: Text(
            l == null ? '' : '${'${no ?? ''}'.padLeft(4)} $mark ${l.text}',
            style: J3Type.codeSmall.copyWith(color: op == DiffOp.equal ? J3Colors.textMuted : J3Colors.text),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, i) => Row(
        children: [
          cell(rows[i].left, true),
          const SizedBox(width: 1, height: 18, child: ColoredBox(color: J3Colors.border)),
          cell(rows[i].right, false),
        ],
      ),
    );
  }
}
