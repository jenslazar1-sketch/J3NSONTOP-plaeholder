import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/activity/activity_controller.dart';
import '../../../core/drafts/drafts.dart';
import '../../../core/text/diff.dart';
import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/text_diff.dart';
import 'dev_widgets.dart';
import 'diff_controller.dart';

enum DiffView {
  unified('Unified'),
  sideBySide('Side by side');

  const DiffView(this.label);
  final String label;
}

class DiffPage extends ConsumerStatefulWidget {
  const DiffPage({super.key});
  static const id = 'dev.diff';

  /// Inputs up to this many characters are compared automatically.
  static const int autoCompareChars = 200000;

  @override
  ConsumerState<DiffPage> createState() => _DiffPageState();
}

class _DiffPageState extends ConsumerState<DiffPage> {
  static const _k = DiffPage.id;
  final _debounce = Debouncer(const Duration(milliseconds: 250));
  late final TextEditingController _a = ref.read(draftTextProvider('$_k/a'));
  late final TextEditingController _b = ref.read(draftTextProvider('$_k/b'));
  (String, String)? _last;
  bool _loadingA = false, _loadingB = false;

  @override
  void initState() {
    super.initState();
    _a.addListener(_onChanged);
    _b.addListener(_onChanged);
    _last = (_a.text, _b.text);
  }

  @override
  void dispose() {
    _a.removeListener(_onChanged);
    _b.removeListener(_onChanged);
    _debounce.dispose();
    super.dispose();
  }

  bool get _ignoreWs => ref.read(draftValueProvider('$_k/ignoreWs')) == true;
  bool get _ignoreCase => ref.read(draftValueProvider('$_k/ignoreCase')) == true;

  bool get _small => _a.text.length + _b.text.length <= DiffPage.autoCompareChars;

  void _onChanged() {
    final now = (_a.text, _b.text);
    if (now == _last) return;
    _last = now;
    if (_small) {
      _debounce(_compare);
    } else {
      setState(() {}); // show the "press Compare" hint
    }
  }

  void _compare() {
    _debounce.cancel();
    if (_a.text.isEmpty && _b.text.isEmpty) {
      ref.read(diffToolProvider.notifier).clear();
      return;
    }
    ref.read(diffToolProvider.notifier).compare(_a.text, _b.text, ignoreWhitespace: _ignoreWs, ignoreCase: _ignoreCase);
  }

  void _setOption(String key, bool v) {
    ref.setDraft('$_k/$key', v);
    if (_small) _compare();
  }

  Future<void> _open(bool left) async {
    setState(() => left ? _loadingA = true : _loadingB = true);
    try {
      final f = await pickTextFile(context, ref, maxBytes: TextDiff.maxBytes);
      if (f == null) return;
      ref.setDraft('$_k/name${left ? 'A' : 'B'}', f.name);
      (left ? _a : _b).text = f.text;
      if (f.lossy) {
        ref
            .read(activityProvider.notifier)
            .notify(NoticeKind.warning, '${f.name} was decoded as Latin-1 (not valid UTF-8).');
      }
      if (!_small) _compare();
    } finally {
      if (mounted) setState(() => left ? _loadingA = false : _loadingB = false);
    }
  }

  void _swap() {
    final a = _a.text, na = ref.read(draftValueProvider('$_k/nameA'));
    _a.text = _b.text;
    _b.text = a;
    ref.setDraft('$_k/nameA', ref.read(draftValueProvider('$_k/nameB')));
    ref.setDraft('$_k/nameB', na);
  }

  Widget _side(bool left, TextEditingController c, String name, bool loading) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              left ? 'LEFT (old): $name' : 'RIGHT (new): $name',
              style: J3Type.kicker,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'Open file for the ${left ? 'left' : 'right'} side',
            onPressed: loading ? null : () => _open(left),
            icon: loading
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.file_open_outlined, size: 18),
          ),
          InputActions(
            controller: c,
            what: left ? 'left side' : 'right side',
            onChanged: () => ref.setDraft('$_k/name${left ? 'A' : 'B'}', null),
          ),
        ],
      ),
      CodeField(
        key: Key('dev.diff.${left ? 'a' : 'b'}'),
        controller: c,
        minLines: 6,
        maxLines: 14,
        hint: left ? 'Original text' : 'Changed text',
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final ignoreWs = ref.draft<bool>('$_k/ignoreWs', false);
    final ignoreCase = ref.draft<bool>('$_k/ignoreCase', false);
    final view = ref.draft<DiffView>('$_k/view', DiffView.unified);
    final context3 = ref.draft<int>('$_k/context', 3);
    final nameA = ref.draft<String?>('$_k/nameA', null) ?? 'a';
    final nameB = ref.draft<String?>('$_k/nameB', null) ?? 'b';
    final state = ref.watch(diffToolProvider);

    final editor = CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): _compare},
      child: NeonPanel(
        kicker: 'INPUT',
        title: 'Texts to compare',
        icon: Icons.difference_outlined,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, c) {
                final a = _side(true, _a, nameA, _loadingA);
                final b = _side(false, _b, nameB, _loadingB);
                if (c.maxWidth < 760) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      a,
                      const SizedBox(height: J3Space.md),
                      b,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: a),
                    const SizedBox(width: J3Space.md),
                    Expanded(child: b),
                  ],
                );
              },
            ),
            const MiniHeader('Options'),
            Wrap(
              spacing: J3Space.lg,
              children: [
                SizedBox(
                  width: 300,
                  child: OptionSwitch(
                    label: 'Ignore whitespace',
                    description: 'Runs of spaces/tabs compare equal; leading/trailing ignored.',
                    value: ignoreWs,
                    onChanged: (v) => _setOption('ignoreWs', v),
                  ),
                ),
                SizedBox(
                  width: 300,
                  child: OptionSwitch(
                    label: 'Ignore case',
                    value: ignoreCase,
                    onChanged: (v) => _setOption('ignoreCase', v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: J3Space.sm),
            ActionWrap(
              children: [
                NeonButton(
                  key: const Key('dev.diff.compare'),
                  label: 'Compare',
                  icon: Icons.compare_arrows,
                  busy: state.running,
                  tooltip: 'Compare now (Ctrl+Enter)',
                  onPressed: _compare,
                ),
                NeonButton.ghost(label: 'Swap sides', icon: Icons.swap_horiz, onPressed: _swap),
              ],
            ),
            if (!_small) const HelpText('Large inputs: press Compare (runs in a background worker).'),
          ],
        ),
      ),
    );

    return ToolScaffold(toolId: _k, children: [editor, ..._results(state, view, context3, nameA, nameB)]);
  }

  List<Widget> _results(DiffToolState state, DiffView view, int ctx, String nameA, String nameB) {
    if (state.error != null) {
      return [StatusBanner(kind: StatusKind.error, title: 'Cannot compare', message: state.error!.message)];
    }
    final o = state.outcome;
    if (o == null) {
      if (state.running) return [const LoadingState(label: 'Comparing in a background worker...')];
      return [
        const EmptyState(
          title: 'Paste or open two texts',
          message: 'Small inputs are compared as you type.',
          glyph: '[ -a +b ]',
        ),
      ];
    }
    final r = o.result;
    final contextLines = ctx < 0 ? null : ctx;
    final opts = [if (state.ignoreWhitespace) 'whitespace ignored', if (state.ignoreCase) 'case ignored'];
    String unifiedText() => o.unified(oldName: nameA, newName: nameB, context: contextLines ?? 1 << 30);
    return [
      if (state.running) const StatusLine(kind: StatusKind.running, text: 'Updating...'),
      if (r.truncated)
        StatusBanner(
          kind: StatusKind.warning,
          title: 'Diff truncated by the edit budget',
          message:
              'The texts differ in more than ${o.editBudget} places inside the changed block, so the rest of that '
              'block is shown as one deletion plus one insertion instead of a minimal diff.',
        ),
      NeonPanel(
        kicker: 'RESULT',
        title: r.identical ? 'Identical' : 'Differences',
        emphasis: r.identical ? PanelEmphasis.success : PanelEmphasis.normal,
        actions: [
          IconButton(
            tooltip: 'Copy unified diff',
            onPressed: r.identical ? null : () => copyToClipboard(ref, unifiedText(), what: 'unified diff'),
            icon: const Icon(Icons.copy_rounded, size: 18),
          ),
          IconButton(
            tooltip: 'Save unified diff',
            onPressed: r.identical
                ? null
                : () => saveOutput(
                    context,
                    ref,
                    suggestedName: 'changes.diff',
                    bytes: Uint8List.fromList(utf8.encode(unifiedText())),
                    mimeType: 'text/x-diff',
                    toolId: _k,
                  ),
            icon: const Icon(Icons.save_alt_rounded, size: 18),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ActionWrap(
              children: [
                StatusBadge(
                  kind: r.identical ? StatusKind.success : StatusKind.info,
                  text: r.identical ? 'IDENTICAL' : '${r.insertions + r.deletions} CHANGED LINES',
                ),
                StatusBadge(kind: StatusKind.success, text: '+${r.insertions} added'),
                StatusBadge(kind: StatusKind.error, text: '-${r.deletions} removed'),
                StatusBadge(kind: StatusKind.neutral, text: '=${o.unchanged} same'),
              ],
            ),
            const SizedBox(height: J3Space.xs),
            Text(
              '${o.linesA} -> ${o.linesB} lines${opts.isEmpty ? '' : '  |  ${opts.join(', ')}'}',
              style: J3Type.caption,
            ),
            const SizedBox(height: J3Space.md),
            Wrap(
              spacing: J3Space.lg,
              runSpacing: J3Space.sm,
              children: [
                ChoiceRow<DiffView>(
                  label: 'View',
                  options: DiffView.values,
                  selected: view,
                  labelOf: (v) => v.label,
                  onSelected: (v) => ref.setDraft('$_k/view', v),
                ),
                ChoiceRow<int>(
                  label: 'Context lines',
                  options: const [3, 10, -1],
                  selected: ctx,
                  labelOf: (c) => c < 0 ? 'All' : '$c',
                  onSelected: (c) => ref.setDraft('$_k/context', c),
                ),
              ],
            ),
            const SizedBox(height: J3Space.md),
            if (!r.identical)
              DiffListView(key: ValueKey((o, view, contextLines)), outcome: o, view: view, context: contextLines)
            else
              const Text('No differences with the current options.', style: J3Type.bodySecondary),
          ],
        ),
      ),
    ];
  }
}

/// Virtualised diff rows with line numbers, +/- markers and colours.
class DiffListView extends StatefulWidget {
  const DiffListView({super.key, required this.outcome, required this.view, required this.context, this.height = 520});
  final TextDiffOutcome outcome;
  final DiffView view;
  final int? context;
  final double height;

  @override
  State<DiffListView> createState() => _DiffListViewState();
}

class _DiffListViewState extends State<DiffListView> {
  static const int _maxLineChars = 2000;
  late final List<DiffRow> _unified = TextDiff.unifiedRows(widget.outcome.result, widget.context);
  late final List<SideBySideRow> _sides = widget.view == DiffView.sideBySide
      ? TextDiff.sideBySideRows(widget.outcome.result, widget.context)
      : const [];
  final Map<int, (List<WordSpan>, List<WordSpan>)> _words = {};
  late final int _gutter = [
    widget.outcome.linesA,
    widget.outcome.linesB,
    1,
  ].reduce((a, b) => a > b ? a : b).toString().length;

  static String _clip(String s) =>
      s.length > _maxLineChars ? '${s.substring(0, _maxLineChars)} ... (+${s.length - _maxLineChars} chars)' : s;

  static const _insertBg = Color(0x1F34E39A);
  static const _deleteBg = Color(0x24FF5C6C);
  static const _insertHi = Color(0x5534E39A);
  static const _deleteHi = Color(0x60FF5C6C);

  Widget _num(int? n) => SizedBox(
    width: _gutter * 8.5 + 10,
    child: Text(
      n?.toString() ?? '',
      style: J3Type.codeSmall.copyWith(color: J3Colors.textMuted),
      textAlign: TextAlign.right,
    ),
  );

  Widget _marker(DiffOp op) {
    final (ch, color) = switch (op) {
      DiffOp.insert => ('+', J3Colors.success),
      DiffOp.delete => ('-', J3Colors.error),
      DiffOp.equal => (' ', J3Colors.textMuted),
    };
    return SizedBox(
      width: 18,
      child: Text(
        ch,
        style: J3Type.code.copyWith(color: color, fontWeight: FontWeight.w700),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _gap(int hidden) => Container(
    padding: const EdgeInsets.symmetric(vertical: 4),
    color: J3Colors.surfaceRaised,
    alignment: Alignment.center,
    child: Text('... $hidden unchanged line${hidden == 1 ? '' : 's'} ...', style: J3Type.codeSmall),
  );

  Color? _bg(DiffOp op) => switch (op) {
    DiffOp.insert => _insertBg,
    DiffOp.delete => _deleteBg,
    DiffOp.equal => null,
  };

  Widget _unifiedRow(int i) {
    final row = _unified[i];
    final l = row.line;
    if (l == null) return _gap(row.hidden);
    final text = l.op == DiffOp.delete ? widget.outcome.oldText(l) : l.text;
    return Container(
      color: _bg(l.op),
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _num(l.oldLine),
          const SizedBox(width: 4),
          _num(l.newLine),
          _marker(l.op),
          Expanded(child: Text(_clip(text), style: J3Type.code)),
        ],
      ),
    );
  }

  Widget _cell(DiffLine? l, List<WordSpan>? spans, {required bool left}) {
    if (l == null) return const SizedBox.shrink();
    final op = l.op;
    final text = left ? widget.outcome.oldText(l) : l.text;
    final hi = op == DiffOp.insert ? _insertHi : _deleteHi;
    final content = spans == null
        ? Text(_clip(text), style: J3Type.code)
        : Text.rich(
            TextSpan(
              style: J3Type.code,
              children: [
                for (final s in spans)
                  TextSpan(
                    text: s.text,
                    style: s.changed ? TextStyle(backgroundColor: hi, decoration: TextDecoration.underline) : null,
                  ),
              ],
            ),
          );
    return Container(
      color: _bg(op),
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _num(left ? l.oldLine : l.newLine),
          _marker(op == DiffOp.equal ? DiffOp.equal : (left ? DiffOp.delete : DiffOp.insert)),
          Expanded(child: content),
        ],
      ),
    );
  }

  Widget _sideRow(int i) {
    final row = _sides[i];
    if (row.isGap) return _gap(row.hidden);
    (List<WordSpan>, List<WordSpan>)? words;
    if (row.isChangedPair) {
      words = _words.putIfAbsent(i, () => TextDiff.wordDiff(widget.outcome.oldText(row.left!), row.right!.text));
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _cell(row.left, words?.$1, left: true)),
          const VerticalDivider(width: 9, thickness: 1, color: J3Colors.border),
          Expanded(child: _cell(row.right, words?.$2, left: false)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final side = widget.view == DiffView.sideBySide;
    final count = side ? _sides.length : _unified.length;
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: J3Colors.inputFill,
        borderRadius: J3Radius.small,
        border: Border.all(color: J3Colors.border),
      ),
      child: SelectionArea(
        child: Scrollbar(
          child: ListView.builder(itemCount: count, itemBuilder: (context, i) => side ? _sideRow(i) : _unifiedRow(i)),
        ),
      ),
    );
  }
}
