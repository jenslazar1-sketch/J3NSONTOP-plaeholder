import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/platform/capabilities.dart';
import '../../../../core/platform/file_access.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/log_model.dart';
import '../shared.dart';
import 'log_controller.dart';

/// Characters of one line that are rendered (the full line is kept for
/// copy/export).
const int kMaxRenderedLineChars = 2000;

IconData severityIcon(LogSeverity s) => switch (s) {
  LogSeverity.fatal => Icons.dangerous_outlined,
  LogSeverity.error => Icons.error_outline,
  LogSeverity.warn => Icons.warning_amber_rounded,
  LogSeverity.info => Icons.info_outline,
  LogSeverity.debug => Icons.bug_report_outlined,
  LogSeverity.trace => Icons.manage_search,
  LogSeverity.other => Icons.notes,
};

Color severityColor(LogSeverity s) => switch (s) {
  LogSeverity.fatal => J3Colors.error,
  LogSeverity.error => J3Colors.error,
  LogSeverity.warn => J3Colors.warning,
  LogSeverity.info => J3Colors.info,
  LogSeverity.debug => J3Colors.textSecondary,
  LogSeverity.trace => J3Colors.textMuted,
  LogSeverity.other => J3Colors.textMuted,
};

String _tag(LogSeverity s) => switch (s) {
  LogSeverity.fatal => 'F',
  LogSeverity.error => 'E',
  LogSeverity.warn => 'W',
  LogSeverity.info => 'I',
  LogSeverity.debug => 'D',
  LogSeverity.trace => 'T',
  LogSeverity.other => '·',
};

/// Log Viewer tool.
class LogViewerPage extends ConsumerWidget {
  const LogViewerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasDoc = ref.watch(logViewerProvider.select((s) => s.doc != null));
    return ToolScaffold(
      toolId: kLogsToolId,
      children: [
        const _OpenPanel(),
        if (hasDoc) ...[const _FilterPanel(), const _LogListPanel()],
      ],
    );
  }
}

class _OpenPanel extends ConsumerWidget {
  const _OpenPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(logViewerProvider);
    final ctl = ref.read(logViewerProvider.notifier);
    final doc = st.doc;
    return NeonPanel(
      kicker: 'Log',
      title: doc?.name ?? 'Open a log file',
      icon: Icons.receipt_long_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ButtonWrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              NeonButton(
                key: const Key('logs.open'),
                label: doc == null ? 'Open log...' : 'Open another...',
                icon: Icons.file_open_outlined,
                busy: st.loading,
                onPressed: () async {
                  final sel = await pickInputFile(context, ref, title: 'Open a log file');
                  if (sel == null) return;
                  await ctl.load(
                    FileItem(
                      path: sel.path,
                      label: sel.displayName,
                      inWorkspace: sel.fromWorkspace,
                      size: await File(sel.path).length(),
                    ),
                  );
                },
              ),
              if (doc != null)
                Text(
                  '${doc.lines.length} lines · ${Fmt.bytes(doc.fileBytes)} · ${doc.encodingLabel} · '
                  '${doc.lineEndings.total == 0 ? 'one line' : doc.lineEndings.kind.label}',
                  style: J3Type.caption,
                ),
            ],
          ),
          if (st.loading) ...[
            const SizedBox(height: J3Space.md),
            OperationProgressPanel(operationId: st.loadOpId, label: 'Reading lines...'),
          ],
          if (st.loadError != null) ...[
            const SizedBox(height: J3Space.md),
            ErrorPanel(title: 'Cannot open log', error: st.loadError!),
          ],
          if (doc != null && doc.truncated) ...[
            const SizedBox(height: J3Space.md),
            StatusBanner(
              key: const Key('logs.truncated'),
              kind: StatusKind.warning,
              title: 'TRUNCATED',
              message: '${doc.truncationNotice()} Export and search cover the loaded part only.',
            ),
          ],
          if (doc != null && doc.malformed) ...[
            const SizedBox(height: J3Space.md),
            const StatusBanner(
              kind: StatusKind.info,
              title: 'Not valid UTF-8',
              message: 'Decoded as Latin-1 so every byte is shown; some characters may look wrong.',
            ),
          ],
          if (doc == null && !st.loading) ...[
            const SizedBox(height: J3Space.md),
            const EmptyState(
              glyph: '[ >_< ]',
              title: 'No log loaded',
              message:
                  'Reads up to $kMaxLogLines lines / 64 MB. Detects [ERROR], level=warn, JSON "level", Android '
                  'logcat (E/Tag:) and more. Try logs/game.log in the sample workspace.',
            ),
          ],
        ],
      ),
    );
  }
}

class _FilterPanel extends ConsumerWidget {
  const _FilterPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(logViewerProvider);
    final ctl = ref.read(logViewerProvider.notifier);
    final doc = st.doc!;
    final query = ref.watch(draftTextProvider('$kLogsToolId/query'));
    final regex = ref.draft<bool>('$kLogsToolId/regex', false);
    final caseSensitive = ref.draft<bool>('$kLogsToolId/case', false);
    final pos = ctl.currentMatchPosition();

    void run() => ctl.search(LogQuery(query.text, regex: regex, caseSensitive: caseSensitive));

    return NeonPanel(
      kicker: 'Filter',
      title: '${st.visible.length} of ${doc.lines.length} lines shown',
      icon: Icons.filter_alt_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              for (final s in LogSeverity.values)
                FilterChip(
                  key: Key('logs.sev.${s.name}'),
                  avatar: Icon(severityIcon(s), size: 16, color: severityColor(s)),
                  label: Text('${s.label} ${doc.count(s)}'),
                  selected: st.enabled.contains(s),
                  showCheckmark: false,
                  tooltip: st.enabled.contains(s) ? 'Hide ${s.label} lines' : 'Show ${s.label} lines',
                  onSelected: (_) => ctl.toggleSeverity(s),
                ),
            ],
          ),
          const SizedBox(height: J3Space.xs),
          ButtonWrap(
            spacing: J3Space.xs,
            children: [
              NeonButton.ghost(label: 'All levels', dense: true, onPressed: () => ctl.setAllSeverities(true)),
              NeonButton.ghost(
                label: 'Warnings and worse',
                dense: true,
                onPressed: () => ctl.onlySeverity(LogSeverity.warn),
              ),
              NeonButton.ghost(label: 'Errors only', dense: true, onPressed: () => ctl.onlySeverity(LogSeverity.error)),
            ],
          ),
          const Divider(height: J3Space.xl),
          TextField(
            key: const Key('logs.query'),
            controller: query,
            style: J3Type.code,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => run(),
            decoration: InputDecoration(
              labelText: regex ? 'Search (regular expression)' : 'Search',
              prefixIcon: const Icon(Icons.search, size: 18),
              errorText: st.searchError,
              errorMaxLines: 3,
              suffixIcon: query.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () {
                        query.clear();
                        ctl.clearSearch();
                      },
                      icon: const Icon(Icons.close, size: 18),
                    ),
            ),
          ),
          const SizedBox(height: J3Space.sm),
          ButtonWrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChip(
                key: const Key('logs.regex'),
                label: const Text('.* Regex'),
                selected: regex,
                tooltip: 'Treat the search as a regular expression (runs in a time-limited worker)',
                onSelected: (v) => ref.setDraft('$kLogsToolId/regex', v),
              ),
              FilterChip(
                label: const Text('Aa Match case'),
                selected: caseSensitive,
                onSelected: (v) => ref.setDraft('$kLogsToolId/case', v),
              ),
              FilterChip(
                key: const Key('logs.onlyMatches'),
                label: const Text('Only matching lines'),
                selected: st.onlyMatches,
                onSelected: st.search == null ? null : ctl.setOnlyMatches,
              ),
              NeonButton(
                key: const Key('logs.search'),
                label: 'Search',
                icon: Icons.search,
                dense: true,
                busy: st.searching,
                onPressed: run,
              ),
              if (st.searching)
                NeonButton.ghost(
                  label: 'Cancel',
                  icon: Icons.stop_circle_outlined,
                  dense: true,
                  onPressed: ctl.cancelSearch,
                ),
            ],
          ),
          if (st.search != null) ...[
            const SizedBox(height: J3Space.sm),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${st.search!.count} matching line(s)'
                    '${st.visibleMatches.length != st.search!.count ? ', ${st.visibleMatches.length} in the filter' : ''}'
                    '${pos == null ? '' : ' · at $pos'}',
                    key: const Key('logs.matchCount'),
                    style: J3Type.code.copyWith(color: context.effects.accentText),
                  ),
                ),
                IconButton(
                  tooltip: 'Previous match (Shift+F3)',
                  onPressed: st.visibleMatches.isEmpty ? null : () => ctl.stepMatch(-1),
                  icon: const Icon(Icons.keyboard_arrow_up),
                ),
                IconButton(
                  key: const Key('logs.next'),
                  tooltip: 'Next match (F3)',
                  onPressed: st.visibleMatches.isEmpty ? null : () => ctl.stepMatch(1),
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _LogListPanel extends ConsumerStatefulWidget {
  const _LogListPanel();

  @override
  ConsumerState<_LogListPanel> createState() => _LogListPanelState();
}

class _LogListPanelState extends ConsumerState<_LogListPanel> {
  final ScrollController _v = ScrollController();
  final ScrollController _h = ScrollController();
  final FocusNode _focus = FocusNode(debugLabel: 'log-list');
  final GlobalKey _centerKey = GlobalKey();
  final TextEditingController _goto = TextEditingController();

  /// Visible position shown at the anchor (top area) of the list.
  int _anchorPos = 0;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  void _onFocus() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _v.dispose();
    _h.dispose();
    _focus.dispose();
    _goto.dispose();
    super.dispose();
  }

  /// Row height of the last build (fixed-height mode), for context rows.
  double _rowExtent = 0;
  bool _wrapMode = false;

  /// Rebuilds the list with [docIndex] as the center sliver's first row, so
  /// the jump is exact even with wrapped (variable-height) rows, then shows
  /// up to three rows of context above it.
  void _jumpTo(int docIndex) {
    final visible = ref.read(logViewerProvider).visible;
    final pos = _positionOf(visible, docIndex);
    setState(() => _anchorPos = pos);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_v.hasClients) return;
      final context = _wrapMode ? 0 : math.min(pos, 3);
      _v.jumpTo(-context * _rowExtent);
    });
  }

  static int _positionOf(List<int> visible, int docIndex) {
    var lo = 0, hi = visible.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (visible[mid] < docIndex) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo.clamp(0, visible.isEmpty ? 0 : visible.length - 1);
  }

  Future<void> _copy() async {
    final ctl = ref.read(logViewerProvider.notifier);
    final n = ref.read(logViewerProvider).selected.length;
    if (n == 0) return;
    await ref.read(fileAccessProvider).copyText(ctl.selectedText());
    ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Copied $n line(s)');
  }

  Future<void> _export({required bool selectedOnly}) async {
    final ctl = ref.read(logViewerProvider.notifier);
    final st = ref.read(logViewerProvider);
    final text = ctl.exportText(selectedOnly: selectedOnly);
    final base = st.doc!.name.split('/').last.replaceAll(RegExp(r'\.[^.]*$'), '');
    await saveOutput(
      context,
      ref,
      suggestedName: '$base-${selectedOnly ? 'selection' : 'filtered'}.log',
      bytes: Uint8List.fromList(utf8.encode(text)),
      mimeType: 'text/plain',
      toolId: kLogsToolId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(logViewerProvider);
    final ctl = ref.read(logViewerProvider.notifier);
    final caps = ref.watch(capabilitiesProvider);
    final wrap = ref.draft<bool>('$kLogsToolId/wrap', false);
    final checkboxes = ref.draft<bool>('$kLogsToolId/checkboxes', caps.platform.isMobile);
    final doc = st.doc!;
    final visible = st.visible;

    ref.listen(logViewerProvider.select((s) => s.jumpSeq), (_, _) {
      final target = ref.read(logViewerProvider).jumpTarget;
      if (target != null) _jumpTo(target);
    });
    if (_anchorPos >= visible.length) _anchorPos = visible.isEmpty ? 0 : visible.length - 1;

    final scaler = MediaQuery.textScalerOf(context);
    const codeStyle = J3Type.code;
    final lineH = scaler.scale(codeStyle.fontSize!) * codeStyle.height!;
    final rowH = math.max(checkboxes ? 44.0 : 0.0, lineH + 6);
    _rowExtent = rowH;
    _wrapMode = wrap;
    final painter = TextPainter(
      text: const TextSpan(text: 'M', style: codeStyle),
      textScaler: scaler,
      textDirection: TextDirection.ltr,
    )..layout();
    final charW = painter.width;
    painter.dispose();
    final digits = '${doc.lines.length}'.length;
    final gutterW = charW * (digits + 1) + 8;
    final tagW = charW * 2 + 4;
    final checkboxW = checkboxes ? 44.0 : 0.0;
    final lead = checkboxW + gutterW + tagW + 12;
    final longest = math.min(doc.longestLine, kMaxRenderedLineChars + 20);

    Widget row(int pos) {
      final idx = visible[pos];
      return _LogRow(
        key: ValueKey(idx),
        index: idx,
        text: doc.lines[idx],
        severity: doc.severityOf(idx),
        selected: st.selected.contains(idx),
        current: st.currentMatch == idx,
        match: st.search?.matchSet.contains(idx) ?? false,
        highlight: st.search,
        gutterWidth: gutterW,
        tagWidth: tagW,
        checkbox: checkboxes,
        wrap: wrap,
        height: wrap ? null : rowH,
        onTap: () {
          _focus.requestFocus();
          final keys = HardwareKeyboard.instance;
          ctl.tapLine(
            idx,
            range: keys.isShiftPressed,
            toggle: checkboxes || keys.isControlPressed || keys.isMetaPressed,
          );
        },
        onLongPress: () {
          if (!checkboxes) ref.setDraft('$kLogsToolId/checkboxes', true);
          ctl.tapLine(idx, toggle: true);
        },
      );
    }

    final height = (MediaQuery.sizeOf(context).height * 0.65).clamp(280.0, 900.0);

    Widget listFor(double width) {
      final before = SliverChildBuilderDelegate((c, i) => row(_anchorPos - 1 - i), childCount: _anchorPos);
      final after = SliverChildBuilderDelegate((c, i) => row(_anchorPos + i), childCount: visible.length - _anchorPos);
      return CustomScrollView(
        controller: _v,
        center: _centerKey,
        slivers: wrap
            ? [SliverList(delegate: before), SliverList(key: _centerKey, delegate: after)]
            : [
                SliverFixedExtentList(itemExtent: rowH, delegate: before),
                SliverFixedExtentList(key: _centerKey, itemExtent: rowH, delegate: after),
              ],
      );
    }

    final listArea = LayoutBuilder(
      builder: (context, c) {
        if (visible.isEmpty) {
          return const Center(
            child: EmptyState(glyph: '[ -_- ]', title: 'No lines match the filters'),
          );
        }
        if (wrap) {
          return Scrollbar(controller: _v, child: listFor(c.maxWidth));
        }
        final contentW = math.max(c.maxWidth, lead + longest * charW + 16);
        return Scrollbar(
          controller: _v,
          notificationPredicate: (n) => n.depth == 1,
          child: Scrollbar(
            controller: _h,
            child: SingleChildScrollView(
              controller: _h,
              scrollDirection: Axis.horizontal,
              child: SizedBox(width: contentW, height: c.maxHeight, child: listFor(contentW)),
            ),
          ),
        );
      },
    );

    return NeonPanel(
      kicker: 'Lines',
      title: st.selected.isEmpty ? 'Click, shift-click or ctrl-click to select' : '${st.selected.length} selected',
      icon: Icons.view_list_outlined,
      padding: const EdgeInsets.all(J3Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ButtonWrap(
            spacing: J3Space.xs,
            runSpacing: J3Space.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChip(
                key: const Key('logs.wrap'),
                label: const Text('Wrap'),
                avatar: const Icon(Icons.wrap_text, size: 16),
                selected: wrap,
                onSelected: (v) => ref.setDraft('$kLogsToolId/wrap', v),
              ),
              FilterChip(
                key: const Key('logs.checkboxes'),
                label: const Text('Checkboxes'),
                avatar: const Icon(Icons.checklist, size: 16),
                selected: checkboxes,
                tooltip: 'Tap lines to add/remove them (touch friendly)',
                onSelected: (v) => ref.setDraft('$kLogsToolId/checkboxes', v),
              ),
              NeonButton.ghost(
                key: const Key('logs.selectMatches'),
                label: 'Select matches',
                dense: true,
                onPressed: st.visibleMatches.isEmpty ? null : ctl.selectAllMatches,
              ),
              NeonButton.ghost(label: 'Select shown', dense: true, onPressed: ctl.selectAllVisible),
              NeonButton.ghost(label: 'Clear', dense: true, onPressed: st.selected.isEmpty ? null : ctl.clearSelection),
              IconButton(
                key: const Key('logs.copy'),
                tooltip: 'Copy selected lines (Ctrl+C)',
                onPressed: st.selected.isEmpty ? null : _copy,
                icon: const Icon(Icons.copy_rounded, size: 18),
              ),
              NeonButton.secondary(
                key: const Key('logs.exportSelected'),
                label: 'Export selected',
                icon: Icons.save_alt_rounded,
                dense: true,
                onPressed: st.selected.isEmpty ? null : () => _export(selectedOnly: true),
              ),
              NeonButton.secondary(
                key: const Key('logs.exportFiltered'),
                label: 'Export shown',
                icon: Icons.save_alt_rounded,
                dense: true,
                onPressed: visible.isEmpty ? null : () => _export(selectedOnly: false),
              ),
              SizedBox(
                width: 150,
                child: TextField(
                  controller: _goto,
                  keyboardType: TextInputType.number,
                  style: J3Type.code,
                  decoration: const InputDecoration(labelText: 'Go to line', isDense: true),
                  onSubmitted: (v) {
                    final n = int.tryParse(v.trim());
                    if (n != null) ctl.jumpToLine(n);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: J3Space.sm),
          CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.keyC, control: true): _copy,
              const SingleActivator(LogicalKeyboardKey.keyC, meta: true): _copy,
              const SingleActivator(LogicalKeyboardKey.keyA, control: true): ctl.selectAllVisible,
              const SingleActivator(LogicalKeyboardKey.keyA, meta: true): ctl.selectAllVisible,
              const SingleActivator(LogicalKeyboardKey.escape): ctl.clearSelection,
              const SingleActivator(LogicalKeyboardKey.f3): () => ctl.stepMatch(1),
              const SingleActivator(LogicalKeyboardKey.f3, shift: true): () => ctl.stepMatch(-1),
            },
            child: Focus(
              focusNode: _focus,
              child: Container(
                height: height,
                decoration: BoxDecoration(
                  color: J3Colors.inputFill,
                  borderRadius: J3Radius.small,
                  border: Border.all(color: _focus.hasFocus ? context.effects.accentColor : J3Colors.border),
                ),
                child: ClipRRect(borderRadius: J3Radius.small, child: listArea),
              ),
            ),
          ),
          const SizedBox(height: J3Space.xs),
          Text(
            'Ctrl+C copy · Ctrl+A select shown · Esc clear · F3 next match · long-press for checkboxes',
            style: J3Type.caption,
          ),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({
    super.key,
    required this.index,
    required this.text,
    required this.severity,
    required this.selected,
    required this.current,
    required this.match,
    required this.highlight,
    required this.gutterWidth,
    required this.tagWidth,
    required this.checkbox,
    required this.wrap,
    required this.height,
    required this.onTap,
    required this.onLongPress,
  });

  final int index;
  final String text;
  final LogSeverity severity;
  final bool selected;
  final bool current;
  final bool match;
  final LogSearchResult? highlight;
  final double gutterWidth;
  final double tagWidth;
  final bool checkbox;
  final bool wrap;
  final double? height;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  List<TextSpan> _spans(String shown) {
    final h = highlight;
    const base = J3Type.code;
    if (h == null || !match) return [TextSpan(text: shown)];
    final ranges = <(int, int)>[];
    if (!h.query.regex) {
      final needle = h.query.caseSensitive ? h.query.text : h.query.text.toLowerCase();
      final hay = h.query.caseSensitive ? shown : shown.toLowerCase();
      if (needle.isNotEmpty && hay.length == shown.length) {
        var from = 0;
        while (true) {
          final i = hay.indexOf(needle, from);
          if (i < 0) break;
          ranges.add((i, i + needle.length));
          from = i + needle.length;
        }
      }
    } else {
      final r = h.firstRange[index];
      if (r != null && r.$2 <= shown.length && r.$2 > r.$1) ranges.add(r);
    }
    if (ranges.isEmpty) return [TextSpan(text: shown)];
    final out = <TextSpan>[];
    var pos = 0;
    for (final (s, e) in ranges) {
      if (s > pos) out.add(TextSpan(text: shown.substring(pos, s)));
      out.add(
        TextSpan(
          text: shown.substring(s, e),
          style: base.copyWith(backgroundColor: J3Colors.warning.withValues(alpha: 0.35), color: J3Colors.text),
        ),
      );
      pos = e;
    }
    if (pos < shown.length) out.add(TextSpan(text: shown.substring(pos)));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final shown = text.length > kMaxRenderedLineChars
        ? '${text.substring(0, kMaxRenderedLineChars)} … (+${text.length - kMaxRenderedLineChars} chars)'
        : text;
    final color = severityColor(severity);
    final bg = selected ? J3Colors.selection : (current ? fx.accentColor.withValues(alpha: 0.14) : Colors.transparent);
    return Semantics(
      selected: selected,
      label: 'Line ${index + 1}, ${severity.label}${match ? ', match' : ''}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          height: height,
          color: bg,
          padding: const EdgeInsets.only(right: J3Space.sm),
          child: Row(
            crossAxisAlignment: wrap ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              Container(width: 3, color: current ? fx.accentColor : (match ? J3Colors.warning : Colors.transparent)),
              if (checkbox)
                SizedBox(
                  width: 41,
                  child: Checkbox(value: selected, onChanged: (_) => onTap()),
                ),
              SizedBox(
                width: gutterWidth,
                child: Text(
                  '${index + 1}',
                  textAlign: TextAlign.right,
                  style: J3Type.code.copyWith(color: J3Colors.textMuted),
                  maxLines: 1,
                  softWrap: false,
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: tagWidth,
                child: Text(
                  _tag(severity),
                  textAlign: TextAlign.center,
                  style: J3Type.code.copyWith(color: color, fontWeight: FontWeight.w700),
                  maxLines: 1,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text.rich(
                  TextSpan(style: J3Type.code, children: _spans(shown)),
                  maxLines: wrap ? null : 1,
                  softWrap: wrap,
                  overflow: wrap ? TextOverflow.visible : TextOverflow.clip,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
