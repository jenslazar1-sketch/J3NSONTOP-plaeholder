import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/utils/safe_path.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../data/hex_pager.dart';
import '../../domain/hex_math.dart';

enum HexSearchMode {
  hex('Hex bytes'),
  text('Text (UTF-8)');

  const HexSearchMode(this.label);
  final String label;
}

class HexState {
  const HexState({
    this.path,
    this.displayName,
    this.size = 0,
    this.loading = false,
    this.error,
    this.anchorOffset,
    this.focusOffset,
    this.matchOffset,
    this.matchLength = 0,
    this.mode = HexSearchMode.hex,
    this.caseSensitive = true,
    this.searchOpId,
    this.searchMessage,
    this.scrollToOffset,
    this.scrollSeq = 0,
    this.pagesVersion = 0,
  });

  final String? path;
  final String? displayName;
  final int size;
  final bool loading;
  final Object? error;

  /// Selected byte range (inclusive offsets; rows are derived from them so
  /// the selection survives a change of bytes per row).
  final int? anchorOffset;
  final int? focusOffset;
  final int? matchOffset;
  final int matchLength;
  final HexSearchMode mode;
  final bool caseSensitive;
  final String? searchOpId;
  final String? searchMessage;

  /// Offset the view should scroll to; [scrollSeq] changes per request.
  final int? scrollToOffset;
  final int scrollSeq;

  /// Bumped when pages finish loading so rows rebuild.
  final int pagesVersion;

  (int, int)? get selection {
    if (anchorOffset == null || focusOffset == null) return null;
    return anchorOffset! <= focusOffset! ? (anchorOffset!, focusOffset!) : (focusOffset!, anchorOffset!);
  }

  HexState copyWith({
    String? path,
    String? displayName,
    int? size,
    bool? loading,
    Object? error,
    bool clearError = false,
    int? anchorOffset,
    int? focusOffset,
    bool clearSelection = false,
    int? matchOffset,
    int? matchLength,
    bool clearMatch = false,
    HexSearchMode? mode,
    bool? caseSensitive,
    String? searchOpId,
    bool clearSearchOp = false,
    String? searchMessage,
    bool clearSearchMessage = false,
    int? scrollToOffset,
    int? scrollSeq,
    int? pagesVersion,
  }) => HexState(
    path: path ?? this.path,
    displayName: displayName ?? this.displayName,
    size: size ?? this.size,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    anchorOffset: clearSelection ? null : (anchorOffset ?? this.anchorOffset),
    focusOffset: clearSelection ? null : (focusOffset ?? this.focusOffset),
    matchOffset: clearMatch ? null : (matchOffset ?? this.matchOffset),
    matchLength: clearMatch ? 0 : (matchLength ?? this.matchLength),
    mode: mode ?? this.mode,
    caseSensitive: caseSensitive ?? this.caseSensitive,
    searchOpId: clearSearchOp ? null : (searchOpId ?? this.searchOpId),
    searchMessage: clearSearchMessage ? null : (searchMessage ?? this.searchMessage),
    scrollToOffset: scrollToOffset ?? this.scrollToOffset,
    scrollSeq: scrollSeq ?? this.scrollSeq,
    pagesVersion: pagesVersion ?? this.pagesVersion,
  );
}

/// Owns the open file handle (paged, LRU cached) and the viewer state.
class HexController extends Notifier<HexState> {
  HexPager? _pager;
  final Set<int> _loading = {};

  @override
  HexState build() {
    ref.onDispose(() {
      _pager?.close();
      _pager = null;
    });
    return const HexState();
  }

  HexPager? get pager => _pager;

  Future<void> open(String path) async {
    final old = _pager;
    _pager = null;
    _loading.clear();
    await old?.close();
    state = HexState(loading: true, mode: state.mode, caseSensitive: state.caseSensitive);
    try {
      final pager = await HexPager.open(path);
      _pager = pager;
      String display = p.basename(path);
      for (final w in ref.read(workspacesProvider).workspaces) {
        if (SafePath.isWithin(w.rootPath, path)) {
          display = '${w.name}/${p.relative(path, from: w.rootPath).replaceAll(r'\', '/')}';
          break;
        }
      }
      state = HexState(
        path: path,
        displayName: display,
        size: pager.length,
        mode: state.mode,
        caseSensitive: state.caseSensitive,
        scrollToOffset: 0,
        scrollSeq: state.scrollSeq + 1,
      );
      await ensureRange(0, 4096);
    } on FileSystemException catch (e) {
      state = HexState(error: e, mode: state.mode, caseSensitive: state.caseSensitive);
    }
  }

  Future<void> close() async {
    final old = _pager;
    _pager = null;
    await old?.close();
    state = HexState(mode: state.mode, caseSensitive: state.caseSensitive);
  }

  /// Loads the pages covering [start, start+length) if needed.
  Future<void> ensureRange(int start, int length) async {
    final pager = _pager;
    if (pager == null) return;
    final layout = pager.layout();
    final missing = [
      for (final page in layout.pagesFor(start, length))
        if (pager.cachedPage(page) == null && !_loading.contains(page)) page,
    ];
    if (missing.isEmpty) return;
    _loading.addAll(missing);
    try {
      await Future.wait(missing.map(pager.page));
    } on FileSystemException catch (e) {
      if (identical(pager, _pager)) state = state.copyWith(error: e);
    } finally {
      _loading.removeAll(missing);
    }
    if (identical(pager, _pager)) state = state.copyWith(pagesVersion: state.pagesVersion + 1);
  }

  void selectOffset(int offset, {bool extend = false}) {
    if (extend && state.anchorOffset != null) {
      state = state.copyWith(focusOffset: offset);
    } else {
      state = state.copyWith(anchorOffset: offset, focusOffset: offset);
    }
  }

  void clearSelection() => state = state.copyWith(clearSelection: true);

  void scrollTo(int offset) => state = state.copyWith(scrollToOffset: offset, scrollSeq: state.scrollSeq + 1);

  void setMode(HexSearchMode m) => state = state.copyWith(mode: m, clearSearchMessage: true);

  void setCaseSensitive(bool v) => state = state.copyWith(caseSensitive: v);

  void searchStarted(String opId) => state = state.copyWith(searchOpId: opId, clearSearchMessage: true);

  void searchFinished({int? offset, int length = 0, String? message}) {
    if (offset == null) {
      state = state.copyWith(clearSearchOp: true, searchMessage: message);
      return;
    }
    state = state.copyWith(
      clearSearchOp: true,
      matchOffset: offset,
      matchLength: length,
      searchMessage: message,
      anchorOffset: offset,
      focusOffset: offset,
      scrollToOffset: offset,
      scrollSeq: state.scrollSeq + 1,
    );
  }

  void clearError() => state = state.copyWith(clearError: true);

  /// Text of the selected rows (`OFFSET | hex | ascii`), at most [maxRows].
  Future<String> selectedRowsText(int bytesPerRow, {int maxRows = 4096}) async {
    final pager = _pager;
    final sel = state.selection;
    if (pager == null || sel == null) return '';
    final layout = pager.layout(bytesPerRow);
    final a = layout.rowOf(sel.$1);
    final b = layout.rowOf(sel.$2);
    final last = b - a + 1 > maxRows ? a + maxRows - 1 : b;
    final start = layout.rowOffset(a);
    final bytes = await pager.read(start, (last - a + 1) * bytesPerRow);
    final out = StringBuffer();
    for (var r = 0; r * bytesPerRow < bytes.length; r++) {
      final from = r * bytesPerRow;
      final to = from + bytesPerRow > bytes.length ? bytes.length : from + bytesPerRow;
      out.writeln(HexFormat.row(start + from, bytes.sublist(from, to), bytesPerRow, layout.offsetDigits));
    }
    return out.toString();
  }
}

final hexProvider = NotifierProvider<HexController, HexState>(HexController.new);
