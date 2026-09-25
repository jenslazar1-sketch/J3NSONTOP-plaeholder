import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/fs_listing.dart';
import '../../data/trash_store.dart';

class BrowserState {
  const BrowserState({
    this.workspaceId,
    this.dir = '',
    this.sort = SortField.name,
    this.ascending = true,
    this.showHidden = false,
    this.selected,
    this.trashView = false,
    this.lastTrashed,
    this.reloadTick = 0,
  });

  final String? workspaceId;

  /// Current folder relative to the workspace root ('' = root, '/' separated).
  final String dir;
  final SortField sort;
  final bool ascending;
  final bool showHidden;

  /// Absolute path of the selected entry.
  final String? selected;
  final bool trashView;

  /// Most recent delete, offered for undo.
  final TrashItem? lastTrashed;
  final int reloadTick;

  BrowserState copyWith({
    String? workspaceId,
    String? dir,
    SortField? sort,
    bool? ascending,
    bool? showHidden,
    String? selected,
    bool clearSelected = false,
    bool? trashView,
    TrashItem? lastTrashed,
    bool clearLastTrashed = false,
    int? reloadTick,
  }) => BrowserState(
    workspaceId: workspaceId ?? this.workspaceId,
    dir: dir ?? this.dir,
    sort: sort ?? this.sort,
    ascending: ascending ?? this.ascending,
    showHidden: showHidden ?? this.showHidden,
    selected: clearSelected ? null : (selected ?? this.selected),
    trashView: trashView ?? this.trashView,
    lastTrashed: clearLastTrashed ? null : (lastTrashed ?? this.lastTrashed),
    reloadTick: reloadTick ?? this.reloadTick,
  );
}

/// File browser position and options (survive navigation).
class BrowserController extends Notifier<BrowserState> {
  @override
  BrowserState build() => const BrowserState();

  void bind(String workspaceId) => state = BrowserState(
    workspaceId: workspaceId,
    sort: state.sort,
    ascending: state.ascending,
    showHidden: state.showHidden,
  );

  void cd(String relativeDir) => state = state.copyWith(dir: relativeDir, clearSelected: true, trashView: false);

  void select(String? path) =>
      state = path == null ? state.copyWith(clearSelected: true) : state.copyWith(selected: path);

  void sortBy(SortField f) =>
      state = state.sort == f ? state.copyWith(ascending: !state.ascending) : state.copyWith(sort: f, ascending: true);

  void toggleAscending() => state = state.copyWith(ascending: !state.ascending);

  void setShowHidden(bool v) => state = state.copyWith(showHidden: v);

  void setTrashView(bool v) => state = state.copyWith(trashView: v, clearSelected: true);

  void trashed(TrashItem item) =>
      state = state.copyWith(lastTrashed: item, clearSelected: true, reloadTick: state.reloadTick + 1);

  void clearUndo() => state = state.copyWith(clearLastTrashed: true);

  void reload() => state = state.copyWith(reloadTick: state.reloadTick + 1);
}

final browserStateProvider = NotifierProvider<BrowserController, BrowserState>(BrowserController.new);
