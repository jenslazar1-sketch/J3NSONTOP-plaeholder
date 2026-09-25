/// Walks the persisted command history (oldest first, newest last) with
/// Up/Down like a shell. The line being edited is stashed on the first Up
/// and restored when walking back past the newest entry.
class HistoryCursor {
  int? _index;
  String _stash = '';

  /// Whether the input currently shows a history entry.
  bool get browsing => _index != null;

  /// Older entry, or null when there is nothing older.
  String? previous(List<String> history, String current) {
    if (history.isEmpty) return null;
    final i = _index;
    if (i == null) {
      _stash = current;
      _index = history.length - 1;
    } else if (i > 0) {
      _index = (i - 1).clamp(0, history.length - 1);
    } else {
      return null;
    }
    return history[_index!];
  }

  /// Newer entry, the stashed draft after the newest one, or null when not
  /// browsing.
  String? next(List<String> history) {
    final i = _index;
    if (i == null) return null;
    if (i < history.length - 1) {
      _index = i + 1;
      return history[_index!];
    }
    _index = null;
    return _stash;
  }

  /// Stops browsing (after typing or running a command).
  void reset() {
    _index = null;
    _stash = '';
  }
}
