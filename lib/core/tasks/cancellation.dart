import 'dart:async';

/// Thrown by [CancellationToken.throwIfCancelled] when work was cancelled.
class OperationCancelled implements Exception {
  const OperationCancelled([this.message = 'Operation cancelled']);
  final String message;
  @override
  String toString() => message;
}

/// Cooperative cancellation for long operations. Long loops call
/// [throwIfCancelled] between steps; I/O helpers accept a token.
class CancellationToken {
  bool _cancelled = false;
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _cancelled;

  /// Completes when cancellation is requested.
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _completer.complete();
  }

  void throwIfCancelled() {
    if (_cancelled) throw const OperationCancelled();
  }

  /// A token that is never cancelled.
  static final CancellationToken none = _NeverCancelled();
}

class _NeverCancelled extends CancellationToken {
  @override
  void cancel() {}
}

/// Progress callback: [fraction] in 0..1 or null when indeterminate.
typedef ProgressCallback = void Function(double? fraction, String? message);
