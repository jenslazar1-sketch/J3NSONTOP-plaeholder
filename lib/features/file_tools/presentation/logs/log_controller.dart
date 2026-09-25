import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/tasks/cancellation.dart';
import '../../../../core/tasks/isolate_runner.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../domain/log_model.dart';
import '../shared.dart';

const String kLogsToolId = 'files.logs';

class LogViewerState {
  const LogViewerState({
    this.doc,
    this.enabled = const {...LogSeverity.values},
    this.search,
    this.onlyMatches = false,
    this.visible = const [],
    this.visibleMatches = const [],
    this.selected = const {},
    this.anchor,
    this.currentMatch,
    this.jumpSeq = 0,
    this.jumpTarget,
    this.loadOpId,
    this.loadError,
    this.searchError,
    this.searching = false,
  });

  final LogDocument? doc;
  final Set<LogSeverity> enabled;
  final LogSearchResult? search;
  final bool onlyMatches;

  /// Document line indices currently listed (severity filter, then
  /// optionally only matches), ascending.
  final List<int> visible;

  /// Matches that are also visible, ascending.
  final List<int> visibleMatches;

  /// Selected document line indices.
  final Set<int> selected;

  /// Last clicked line (for shift-click ranges).
  final int? anchor;

  /// Document index of the current match (next/prev).
  final int? currentMatch;

  /// Incremented to ask the list to scroll to [jumpTarget].
  final int jumpSeq;
  final int? jumpTarget;
  final String? loadOpId;
  final String? loadError;
  final String? searchError;
  final bool searching;

  bool get loading => loadOpId != null;

  LogViewerState copyWith({
    LogDocument? doc,
    Set<LogSeverity>? enabled,
    LogSearchResult? search,
    bool clearSearch = false,
    bool? onlyMatches,
    List<int>? visible,
    List<int>? visibleMatches,
    Set<int>? selected,
    int? anchor,
    bool clearAnchor = false,
    int? currentMatch,
    bool clearCurrent = false,
    int? jumpSeq,
    int? jumpTarget,
    String? loadOpId,
    bool clearLoadOp = false,
    String? loadError,
    bool clearLoadError = false,
    String? searchError,
    bool clearSearchError = false,
    bool? searching,
  }) => LogViewerState(
    doc: doc ?? this.doc,
    enabled: enabled ?? this.enabled,
    search: clearSearch ? null : (search ?? this.search),
    onlyMatches: onlyMatches ?? this.onlyMatches,
    visible: visible ?? this.visible,
    visibleMatches: visibleMatches ?? this.visibleMatches,
    selected: selected ?? this.selected,
    anchor: clearAnchor ? null : (anchor ?? this.anchor),
    currentMatch: clearCurrent ? null : (currentMatch ?? this.currentMatch),
    jumpSeq: jumpSeq ?? this.jumpSeq,
    jumpTarget: jumpTarget ?? this.jumpTarget,
    loadOpId: clearLoadOp ? null : (loadOpId ?? this.loadOpId),
    loadError: clearLoadError ? null : (loadError ?? this.loadError),
    searchError: clearSearchError ? null : (searchError ?? this.searchError),
    searching: searching ?? this.searching,
  );
}

class LogViewerController extends Notifier<LogViewerState> {
  CancellationToken? _searchToken;

  @override
  LogViewerState build() => const LogViewerState();

  /// Streams a log from disk (capped, cancellable, tracked in Activity).
  Future<void> load(FileItem file) async {
    if (state.loading) return;
    state = state.copyWith(clearLoadError: true);
    try {
      final doc = await ref
          .read(activityProvider.notifier)
          .run<LogDocument>(
            toolId: kLogsToolId,
            title: 'Open log ${file.label}',
            cancellable: true,
            workspaceId: file.inWorkspace ? ref.read(activeWorkspaceProvider)?.id : null,
            notify: false,
            body: (op) async {
              state = state.copyWith(loadOpId: op.id);
              final throttle = ProgressThrottle(op);
              return loadLogFile(
                file.path,
                displayName: file.label,
                token: op.token,
                onProgress: (f, lines) => throttle.report(f, '$lines lines'),
              );
            },
            summary: (d) => '${d.lines.length} lines, ${Fmt.bytes(d.bytesRead)}${d.truncated ? ' (truncated)' : ''}',
            counts: (d) => {'lines': d.lines.length, 'bytes': d.bytesRead},
          );
      if (!ref.mounted) return;
      setDocument(doc);
      state = state.copyWith(clearLoadOp: true);
    } on OperationCancelled {
      if (ref.mounted) state = state.copyWith(clearLoadOp: true, loadError: 'Loading cancelled.');
    } catch (e) {
      if (ref.mounted) state = state.copyWith(clearLoadOp: true, loadError: describeError(e));
    }
  }

  /// Shows [doc] with all filters, search and selection reset.
  void setDocument(LogDocument doc) {
    _searchToken?.cancel();
    final base = LogViewerState(doc: doc, jumpSeq: state.jumpSeq + 1, jumpTarget: 0);
    state = base;
    _recompute();
  }

  void _recompute({bool keepCurrent = true}) {
    final doc = state.doc;
    if (doc == null) return;
    var visible = filterBySeverity(doc, state.enabled);
    final s = state.search;
    if (s != null && state.onlyMatches) {
      visible = [
        for (final i in visible)
          if (s.matchSet.contains(i)) i,
      ];
    }
    final visibleMatches = s == null
        ? const <int>[]
        : (state.onlyMatches
              ? visible
              : [
                  for (final i in visible)
                    if (s.matchSet.contains(i)) i,
                ]);
    final current = keepCurrent && state.currentMatch != null && visibleMatches.contains(state.currentMatch)
        ? state.currentMatch
        : null;
    state = state.copyWith(
      visible: visible,
      visibleMatches: visibleMatches,
      currentMatch: current,
      clearCurrent: current == null,
    );
  }

  void toggleSeverity(LogSeverity s) {
    final next = {...state.enabled};
    next.contains(s) ? next.remove(s) : next.add(s);
    state = state.copyWith(enabled: next);
    _recompute();
  }

  void setAllSeverities(bool on) {
    state = state.copyWith(enabled: on ? {...LogSeverity.values} : <LogSeverity>{});
    _recompute();
  }

  /// Only [s] (and more severe levels when [andAbove]).
  void onlySeverity(LogSeverity s, {bool andAbove = true}) {
    state = state.copyWith(
      enabled: {
        for (final x in LogSeverity.values)
          if (x == s || (andAbove && x.index < s.index)) x,
      },
    );
    _recompute();
  }

  void setOnlyMatches(bool v) {
    state = state.copyWith(onlyMatches: v);
    _recompute();
  }

  void cancelSearch() => _searchToken?.cancel();

  /// Runs [q] over all loaded lines. Plain text runs here; regular
  /// expressions run in bounded worker isolates (time limit, cancellable).
  Future<void> search(LogQuery q, {Duration budget = const Duration(seconds: 4)}) async {
    final doc = state.doc;
    if (doc == null) return;
    _searchToken?.cancel();
    if (q.isEmpty) {
      clearSearch();
      return;
    }
    try {
      q.compile();
    } on FormatException catch (e) {
      state = state.copyWith(clearSearch: true, searchError: 'Invalid regular expression: ${e.message}');
      _recompute(keepCurrent: false);
      return;
    }
    if (!q.regex) {
      state = state.copyWith(search: searchPlain(doc.lines, q), clearSearchError: true, searching: false);
      _afterSearch();
      return;
    }
    final token = _searchToken = CancellationToken();
    state = state.copyWith(searching: true, clearSearchError: true);
    try {
      final r = await searchRegex(doc.lines, q, budget: budget, token: token);
      if (!ref.mounted || token.isCancelled || !identical(state.doc, doc)) return;
      state = state.copyWith(search: r, searching: false);
      _afterSearch();
    } on OperationTimedOut catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(
        clearSearch: true,
        searching: false,
        searchError: 'Regex search stopped: $e. The pattern backtracks too much; make it more specific.',
      );
      _recompute(keepCurrent: false);
    } on OperationCancelled {
      if (ref.mounted && identical(_searchToken, token)) state = state.copyWith(searching: false);
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(clearSearch: true, searching: false, searchError: describeError(e));
      _recompute(keepCurrent: false);
    }
  }

  void _afterSearch() {
    _recompute(keepCurrent: false);
    final first = state.visibleMatches.isEmpty ? null : state.visibleMatches.first;
    if (first != null) {
      state = state.copyWith(currentMatch: first, jumpSeq: state.jumpSeq + 1, jumpTarget: first);
    }
  }

  void clearSearch() {
    _searchToken?.cancel();
    state = state.copyWith(clearSearch: true, clearSearchError: true, searching: false, onlyMatches: false);
    _recompute(keepCurrent: false);
  }

  /// Moves to the next (or previous) visible match, wrapping around.
  void stepMatch(int direction) {
    final m = state.visibleMatches;
    if (m.isEmpty) return;
    final cur = state.currentMatch;
    int next;
    if (cur == null) {
      next = direction > 0 ? m.first : m.last;
    } else {
      // Binary search for the position of cur (or where it would be).
      var lo = 0, hi = m.length;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (m[mid] < cur) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      if (direction > 0) {
        final pos = lo < m.length && m[lo] == cur ? lo + 1 : lo;
        next = m[pos % m.length];
      } else {
        final pos = lo - 1;
        next = m[pos < 0 ? m.length - 1 : pos];
      }
    }
    state = state.copyWith(currentMatch: next, jumpSeq: state.jumpSeq + 1, jumpTarget: next);
  }

  /// 1-based position of the current match among visible matches.
  int? currentMatchPosition() {
    final c = state.currentMatch;
    if (c == null) return null;
    final i = state.visibleMatches.indexOf(c);
    return i < 0 ? null : i + 1;
  }

  void jumpToLine(int lineNumber) {
    final doc = state.doc;
    if (doc == null || state.visible.isEmpty) return;
    final idx = (lineNumber - 1).clamp(0, doc.lines.length - 1);
    // Closest visible line at or after the requested one.
    var target = state.visible.last;
    for (final v in state.visible) {
      if (v >= idx) {
        target = v;
        break;
      }
    }
    state = state.copyWith(jumpSeq: state.jumpSeq + 1, jumpTarget: target, anchor: target, selected: {target});
  }

  /// Click selection: plain click selects one line, [range] (shift) selects
  /// from the anchor through visible lines, [toggle] (ctrl/cmd or checkbox
  /// mode) adds or removes one line.
  void tapLine(int docIndex, {bool range = false, bool toggle = false}) {
    final anchor = state.anchor;
    if (range && anchor != null) {
      final a = state.visible.indexOf(anchor);
      final b = state.visible.indexOf(docIndex);
      if (a >= 0 && b >= 0) {
        final lo = a < b ? a : b;
        final hi = a < b ? b : a;
        state = state.copyWith(selected: {...state.selected, ...state.visible.sublist(lo, hi + 1)});
        return;
      }
    }
    if (toggle) {
      final next = {...state.selected};
      next.contains(docIndex) ? next.remove(docIndex) : next.add(docIndex);
      state = state.copyWith(selected: next, anchor: docIndex);
      return;
    }
    final only = state.selected.length == 1 && state.selected.contains(docIndex);
    state = state.copyWith(selected: only ? <int>{} : {docIndex}, anchor: docIndex);
  }

  void selectAllMatches() => state = state.copyWith(selected: {...state.selected, ...state.visibleMatches});

  void selectAllVisible() => state = state.copyWith(selected: {...state.visible});

  void clearSelection() => state = state.copyWith(selected: <int>{}, clearAnchor: true);

  /// Selected lines as text (document order).
  String selectedText() {
    final doc = state.doc;
    if (doc == null) return '';
    final idx = state.selected.toList()..sort();
    return idx.map((i) => doc.lines[i]).join('\n');
  }

  /// Export text for the selection ([selectedOnly]) or all visible lines.
  String exportText({required bool selectedOnly, DateTime? now}) {
    final doc = state.doc!;
    final indices = selectedOnly ? state.selected.toList() : state.visible;
    return buildLogExport(
      doc: doc,
      indices: indices,
      scope: selectedOnly ? 'selected lines' : 'all lines passing the filters',
      severities: state.enabled,
      query: state.search?.query,
      onlyMatches: state.onlyMatches,
      now: now,
    );
  }
}

final logViewerProvider = NotifierProvider<LogViewerController, LogViewerState>(LogViewerController.new);
