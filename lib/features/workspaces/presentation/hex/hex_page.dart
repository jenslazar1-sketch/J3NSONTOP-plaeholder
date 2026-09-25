import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/platform/file_access.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../data/hex_pager.dart';
import '../../domain/hex_math.dart';
import '../shared/requests.dart';
import '../shared/ws_widgets.dart';
import 'hex_state.dart';

class HexViewerPage extends ConsumerStatefulWidget {
  const HexViewerPage({super.key});

  @override
  ConsumerState<HexViewerPage> createState() => _HexViewerPageState();
}

class _HexViewerPageState extends ConsumerState<HexViewerPage> {
  final ScrollController _scroll = ScrollController();
  int _scrolledSeq = 0;
  String? _jumpError;
  String? _patternError;
  int _bytesPerRow = 16;

  late final HexController _ctrl = ref.read(hexProvider.notifier);
  late final TextEditingController _jump = ref.read(draftTextProvider('${WsTools.hex}/jump'));
  late final TextEditingController _search = ref.read(draftTextProvider('${WsTools.hex}/search'));

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final input = await pickInputFile(context, ref, title: 'Open in Hex Viewer');
    if (input == null) return;
    await _ctrl.open(input.path);
  }

  void _maybeHandleRequest() {
    if (!ref.read(hexRequestProvider.notifier).hasPending) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final req = ref.read(hexRequestProvider.notifier).claim();
      if (req == null) return;
      await _ctrl.open(req.path);
      if (req.offset != null) _ctrl.scrollTo(req.offset!);
    });
  }

  /// Whole pixels: fractional extents lose precision with millions of rows.
  double _rowExtent(BuildContext context) =>
      (MediaQuery.textScalerOf(context).scale(J3Type.codeSmall.fontSize!) * 1.4 + 6).ceilToDouble();

  void _maybeScroll(HexState s, double extent) {
    if (s.scrollSeq == _scrolledSeq || s.scrollToOffset == null) return;
    _scrolledSeq = s.scrollSeq;
    final row = s.scrollToOffset! ~/ _bytesPerRow;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final viewport = _scroll.position.viewportDimension;
      final target = (row * extent - viewport / 3).clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.jumpTo(target);
    });
  }

  void _doJump() {
    final s = ref.read(hexProvider);
    try {
      final off = HexFormat.parseOffset(_jump.text);
      if (off >= s.size) throw FormatException('Offset is beyond the end of the file (${s.size} bytes)');
      setState(() => _jumpError = null);
      _ctrl
        ..selectOffset(off)
        ..scrollTo(off);
    } on FormatException catch (e) {
      setState(() => _jumpError = e.message);
    }
  }

  BytePattern? _pattern() {
    final s = ref.read(hexProvider);
    try {
      final pat = s.mode == HexSearchMode.hex
          ? BytePattern.parseHex(_search.text)
          : BytePattern.text(_search.text, caseSensitive: s.caseSensitive);
      setState(() => _patternError = null);
      return pat;
    } on FormatException catch (e) {
      setState(() => _patternError = e.message);
      return null;
    }
  }

  Future<void> _find({required bool forward}) async {
    final s = ref.read(hexProvider);
    final path = s.path;
    final pat = _pattern();
    if (path == null || pat == null || s.searchOpId != null) return;
    final from = forward
        ? (s.matchOffset != null ? s.matchOffset! + 1 : (s.selection?.$1 ?? 0))
        : (s.matchOffset != null ? s.matchOffset! - 1 : s.size - 1);
    final activity = ref.read(activityProvider.notifier);
    try {
      final (hit, wrapped) = await activity.run<(int?, bool)>(
        toolId: WsTools.hex,
        title: 'Search ${pat.length} byte(s) in ${s.displayName ?? 'file'}',
        cancellable: true,
        notify: false,
        body: (op) async {
          _ctrl.searchStarted(op.id);
          void progress(double f) => op.progress(f, 'Scanning');
          int? hit = forward
              ? await HexSearch.findNext(path, pat, from: from, token: op.token, onProgress: progress)
              : await HexSearch.findPrevious(path, pat, from: from, token: op.token, onProgress: progress);
          var wrapped = false;
          if (hit == null && (forward ? from > 0 : from < s.size - 1)) {
            wrapped = true;
            hit = forward
                ? await HexSearch.findNext(path, pat, from: 0, token: op.token, onProgress: progress)
                : await HexSearch.findPrevious(path, pat, from: s.size - 1, token: op.token, onProgress: progress);
          }
          return (hit, wrapped);
        },
        summary: (r) => r.$1 == null ? 'No match' : 'Match at 0x${HexFormat.offset(r.$1!)}',
      );
      _ctrl.searchFinished(
        offset: hit,
        length: pat.length,
        message: hit == null
            ? 'No match in the whole file'
            : 'Match at 0x${HexFormat.offset(hit)} ($hit)${wrapped ? ' - wrapped around' : ''}',
      );
    } catch (e) {
      _ctrl.searchFinished(message: e.toString());
    }
  }

  Future<void> _count() async {
    final s = ref.read(hexProvider);
    final path = s.path;
    final pat = _pattern();
    if (path == null || pat == null || s.searchOpId != null) return;
    try {
      final n = await ref
          .read(activityProvider.notifier)
          .run<int>(
            toolId: WsTools.hex,
            title: 'Count matches in ${s.displayName ?? 'file'}',
            cancellable: true,
            body: (op) {
              _ctrl.searchStarted(op.id);
              return HexSearch.count(path, pat, token: op.token, onProgress: (f) => op.progress(f, 'Scanning'));
            },
            summary: (n) => Fmt.count(n, 'match', 'matches'),
          );
      _ctrl.searchFinished(message: '${Fmt.count(n, 'match', 'matches')}${n >= 100000 ? ' (stopped at 100000)' : ''}');
    } catch (e) {
      _ctrl.searchFinished(message: e.toString());
    }
  }

  Future<void> _copyRows() async {
    final text = await _ctrl.selectedRowsText(_bytesPerRow);
    if (text.isEmpty) return;
    await ref.read(fileAccessProvider).copyText(text);
    final rows = '\n'.allMatches(text).length;
    ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Copied ${Fmt.count(rows, 'row')} as hex text');
  }

  int _fitBytesPerRow(double width, BuildContext context, int digits) {
    final charW = MediaQuery.textScalerOf(context).scale(J3Type.codeSmall.fontSize!) * 0.61;
    double need(int bpr) => (digits + 3 + bpr * 3 + (bpr > 8 ? 1 : 0) + 3 + bpr) * charW + J3Space.lg;
    if (need(16) <= width) return 16;
    return 8;
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(hexProvider);
    ref.watch(hexRequestProvider);
    _maybeHandleRequest();
    final pager = _ctrl.pager;

    return ToolScaffold(
      toolId: WsTools.hex,
      headerActions: [NeonIconButton(icon: Icons.file_open_outlined, tooltip: 'Open file', onPressed: _pick)],
      children: [
        if (s.error != null) WsErrorBanner(error: s.error!, action: 'Reading the file', onDismiss: _ctrl.clearError),
        if (s.loading) const LoadingState(label: 'Opening file...'),
        if (s.path == null && !s.loading)
          NeonPanel(
            emphasis: PanelEmphasis.subtle,
            child: EmptyState(
              glyph: '[ 0x ]',
              title: 'No file open',
              message:
                  'Inspect any file byte by byte. Files of any size open instantly: only the visible pages '
                  'are read.',
              action: FitButton(NeonButton(label: 'Open file', icon: Icons.file_open_outlined, onPressed: _pick)),
            ),
          ),
        if (s.path != null && pager != null) ...[
          _controls(s, pager),
          LayoutBuilder(
            builder: (context, c) {
              final layout0 = pager.layout();
              final bpr = _fitBytesPerRow(c.maxWidth, context, layout0.offsetDigits);
              _bytesPerRow = bpr;
              final layout = pager.layout(bpr);
              final extent = _rowExtent(context);
              _maybeScroll(s, extent);
              final charW = MediaQuery.textScalerOf(context).scale(J3Type.codeSmall.fontSize!) * 0.61;
              final rowWidth = (layout.offsetDigits + 3 + bpr * 3 + (bpr > 8 ? 1 : 0) + 3 + bpr) * charW + J3Space.lg;
              final list = ListView.builder(
                controller: _scroll,
                itemCount: layout.rowCount,
                itemExtent: extent,
                itemBuilder: (context, row) => _HexRow(
                  row: row,
                  layout: layout,
                  pager: pager,
                  state: s,
                  onTap: () =>
                      _ctrl.selectOffset(layout.rowOffset(row), extend: HardwareKeyboard.instance.isShiftPressed),
                  onLongPress: () => _ctrl.selectOffset(layout.rowOffset(row), extend: true),
                  onNeedData: () => _ctrl.ensureRange(layout.rowOffset(row), 64 * bpr),
                ),
              );
              return NeonPanel(
                padding: const EdgeInsets.all(J3Space.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ListenableBuilder(listenable: _scroll, builder: (context, _) => _statusLine(s, layout)),
                    const SizedBox(height: J3Space.xs),
                    if (layout.rowCount == 0)
                      const EmptyState(glyph: '[ ]', title: 'Empty file', message: '0 bytes')
                    else
                      Container(
                        // Sized to the rows (a few for tiny files), capped for large ones.
                        height: math.min(listViewportHeight(context), math.max(3, layout.rowCount) * extent + 2),
                        decoration: BoxDecoration(
                          color: J3Colors.inputFill,
                          borderRadius: J3Radius.small,
                          border: Border.all(color: J3Colors.border),
                        ),
                        child: rowWidth <= c.maxWidth
                            ? Scrollbar(controller: _scroll, child: list)
                            : SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: SizedBox(
                                  width: rowWidth,
                                  child: Scrollbar(controller: _scroll, child: list),
                                ),
                              ),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ],
    );
  }

  Widget _statusLine(HexState s, HexLayout layout) {
    final sel = s.selection;
    final firstRow = _scroll.hasClients ? (_scroll.offset / _rowExtent(context)).floor() : 0;
    final page = layout.rowCount == 0
        ? 0
        : layout.pageOf(math.min(layout.rowOffset(firstRow), math.max(0, s.size - 1)));
    return ButtonWrap(
      spacing: J3Space.md,
      runSpacing: J3Space.xs,
      children: [
        Text('${Fmt.bytes(s.size)} (${s.size} bytes)', style: J3Type.codeSmall),
        Text(
          'page ${page + 1}/${math.max(1, layout.pageCount)} of ${Fmt.bytes(layout.pageSize)}',
          style: J3Type.codeSmall,
        ),
        Text('${_ctrl.pager?.cachedPages ?? 0} pages cached', style: J3Type.codeSmall),
        if (sel != null)
          Text(
            'selected 0x${HexFormat.offset(layout.rowOffset(layout.rowOf(sel.$1)))}'
            '..0x${HexFormat.offset(math.min(s.size - 1, layout.rowOffset(layout.rowOf(sel.$2)) + layout.bytesPerRow - 1))}',
            style: J3Type.codeSmall.copyWith(color: context.effects.accentText),
          ),
      ],
    );
  }

  Widget _controls(HexState s, HexPager pager) {
    final searching = s.searchOpId != null;
    return NeonPanel(
      padding: const EdgeInsets.all(J3Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.memory, color: context.effects.accentText, size: 20),
              const SizedBox(width: J3Space.sm),
              Expanded(
                child: PathText(s.displayName ?? '', style: J3Type.code.copyWith(color: J3Colors.text)),
              ),
              NeonIconButton(icon: Icons.close, tooltip: 'Close file', onPressed: _ctrl.close),
            ],
          ),
          const Align(
            alignment: Alignment.centerLeft,
            child: StatusBadge(kind: StatusKind.info, text: 'READ-ONLY', dense: true),
          ),
          const SizedBox(height: J3Space.sm),
          ButtonWrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 200,
                child: TextField(
                  controller: _jump,
                  style: J3Type.code,
                  decoration: InputDecoration(labelText: 'Offset (dec or 0x hex)', errorText: _jumpError),
                  onSubmitted: (_) => _doJump(),
                ),
              ),
              NeonButton.secondary(label: 'Go', icon: Icons.my_location, onPressed: _doJump),
              NeonButton.ghost(
                label: 'Copy rows',
                icon: Icons.copy_rounded,
                tooltip: 'Copy the selected rows as hex text (tap a row, Shift+tap or long-press to extend)',
                onPressed: s.selection == null ? null : _copyRows,
              ),
            ],
          ),
          const SizedBox(height: J3Space.sm),
          ChoiceRow<HexSearchMode>(
            label: 'Search for',
            options: HexSearchMode.values,
            selected: s.mode,
            labelOf: (m) => m.label,
            onSelected: _ctrl.setMode,
          ),
          const SizedBox(height: J3Space.sm),
          ButtonWrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _search,
                  style: J3Type.code,
                  decoration: InputDecoration(
                    labelText: s.mode == HexSearchMode.hex ? 'Bytes, e.g. DE AD ?? EF' : 'Text',
                    errorText: _patternError,
                  ),
                  onSubmitted: (_) => _find(forward: true),
                ),
              ),
              if (s.mode == HexSearchMode.text)
                FilterChip(
                  label: const Text('Aa'),
                  tooltip: 'Match case (ASCII letters)',
                  selected: s.caseSensitive,
                  onSelected: _ctrl.setCaseSensitive,
                ),
              NeonIconButton(
                icon: Icons.keyboard_arrow_up,
                tooltip: 'Previous match',
                onPressed: searching ? null : () => _find(forward: false),
              ),
              NeonIconButton(
                icon: Icons.keyboard_arrow_down,
                tooltip: 'Next match',
                onPressed: searching ? null : () => _find(forward: true),
              ),
              NeonButton.ghost(label: 'Count', onPressed: searching ? null : _count),
            ],
          ),
          if (s.searchOpId != null) ...[
            const SizedBox(height: J3Space.sm),
            OperationProgress(operationId: s.searchOpId!, label: 'Searching'),
          ],
          if (s.searchMessage != null) ...[
            const SizedBox(height: J3Space.xs),
            Semantics(
              liveRegion: true,
              child: Text(s.searchMessage!, style: J3Type.codeSmall.copyWith(color: J3Colors.text)),
            ),
          ],
        ],
      ),
    );
  }
}

class _HexRow extends StatelessWidget {
  const _HexRow({
    required this.row,
    required this.layout,
    required this.pager,
    required this.state,
    required this.onTap,
    required this.onLongPress,
    required this.onNeedData,
  });

  final int row;
  final HexLayout layout;
  final HexPager pager;
  final HexState state;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onNeedData;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final offset = layout.rowOffset(row);
    final bytes = pager.readCached(offset, layout.rowLength(row));
    final sel = state.selection;
    final selected = sel != null && row >= layout.rowOf(sel.$1) && row <= layout.rowOf(sel.$2);
    final offsetText = HexFormat.offset(offset, layout.offsetDigits);
    Widget content;
    if (bytes == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onNeedData());
      content = Text('$offsetText | loading...', style: J3Type.codeSmall.copyWith(color: J3Colors.textMuted));
    } else {
      final mStart = state.matchOffset;
      final mEnd = mStart == null ? null : mStart + state.matchLength;
      bool hit(int i) => mStart != null && offset + i >= mStart && offset + i < mEnd!;
      final hl = TextStyle(
        backgroundColor: J3Colors.selection,
        color: J3Colors.text,
        fontWeight: FontWeight.w700,
        decoration: TextDecoration.underline,
        decorationColor: fx.accentText,
      );
      final spans = <TextSpan>[
        TextSpan(
          text: '$offsetText | ',
          style: TextStyle(color: fx.accentText),
        ),
      ];
      for (var i = 0; i < layout.bytesPerRow; i++) {
        if (i > 0) spans.add(TextSpan(text: i % 8 == 0 ? '  ' : ' '));
        spans.add(
          i < bytes.length
              ? TextSpan(text: HexFormat.byte(bytes[i]), style: hit(i) ? hl : null)
              : const TextSpan(text: '  '),
        );
      }
      spans.add(const TextSpan(text: ' | '));
      final ascii = HexFormat.asciiColumn(bytes);
      for (var i = 0; i < ascii.length; i++) {
        spans.add(TextSpan(text: ascii[i], style: hit(i) ? hl : null));
      }
      content = Text.rich(
        TextSpan(
          style: J3Type.codeSmall.copyWith(color: J3Colors.text),
          children: spans,
        ),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
      );
    }
    return Material(
      color: selected ? J3Colors.surfaceHigh : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: J3Space.sm),
          child: Align(alignment: Alignment.centerLeft, child: content),
        ),
      ),
    );
  }
}
