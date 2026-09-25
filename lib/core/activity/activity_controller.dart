import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../storage/app_stores.dart';
import '../tasks/cancellation.dart';
import 'operation.dart';

/// Severity of a user-facing notification toast.
enum NoticeKind { success, info, warning, error }

class Notice {
  const Notice(this.kind, this.message, {this.id = 0});
  final NoticeKind kind;
  final String message;
  final int id;
}

class ActivityState {
  const ActivityState({this.operations = const [], this.notices = const []});

  /// Newest first. Running operations plus persisted history.
  final List<OperationRecord> operations;

  /// Pending toasts (consumed by the shell's toast overlay).
  final List<Notice> notices;

  List<OperationRecord> get running =>
      operations.where((o) => o.status == OperationStatus.running).toList();

  int countToday(DateTime now) => operations
      .where(
        (o) =>
            o.startedAt.year == now.year &&
            o.startedAt.month == now.month &&
            o.startedAt.day == now.day,
      )
      .length;
}

/// Handle given to a tool while its operation runs.
class OperationHandle {
  OperationHandle._(this._controller, this.id, this.token);

  final ActivityController _controller;
  final String id;
  final CancellationToken token;
  bool _finished = false;

  bool get isFinished => _finished;

  void progress(double? fraction, [String? message]) {
    if (_finished) return;
    _controller._patch(
      id,
      (r) => r.copyWith(
        progress: fraction?.clamp(0.0, 1.0),
        clearProgress: fraction == null,
        progressMessage: message,
      ),
    );
  }

  void succeed(
    String summary, {
    Map<String, num> counts = const {},
    List<String> details = const [],
    bool notify = true,
  }) => _finish(
    OperationStatus.succeeded,
    summary: summary,
    counts: counts,
    details: details,
    notify: notify,
  );

  void warn(
    String summary, {
    Map<String, num> counts = const {},
    List<String> details = const [],
  }) => _finish(
    OperationStatus.warning,
    summary: summary,
    counts: counts,
    details: details,
  );

  void fail(Object error, {List<String> details = const []}) => _finish(
    OperationStatus.failed,
    error: error.toString(),
    details: details,
  );

  void cancelled() => _finish(OperationStatus.cancelled, summary: 'Cancelled');

  void _finish(
    OperationStatus status, {
    String? summary,
    String? error,
    Map<String, num> counts = const {},
    List<String> details = const [],
    bool notify = true,
  }) {
    if (_finished) return;
    _finished = true;
    _controller._complete(
      id,
      status: status,
      summary: summary,
      error: error,
      counts: counts,
      details: details,
      notify: notify,
    );
  }
}

/// Tracks real operations, persists history (newest 300) and raises toasts.
class ActivityController extends Notifier<ActivityState> {
  static const int historyLimit = 300;
  static const _uuid = Uuid();
  final Map<String, CancellationToken> _tokens = {};
  int _noticeSeq = 0;

  @override
  ActivityState build() {
    final boot = ref.watch(bootDataProvider);
    final ops = <OperationRecord>[];
    final raw = boot.history.data['operations'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          final r = OperationRecord.fromJson(item);
          if (r != null) ops.add(r);
        }
      }
    }
    ops.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final notices = <Notice>[
      for (final n in boot.notices)
        Notice(NoticeKind.warning, n, id: ++_noticeSeq),
    ];
    return ActivityState(operations: ops, notices: notices);
  }

  /// Starts a tracked operation. Always finish the returned handle.
  OperationHandle start({
    required String toolId,
    required String title,
    String? workspaceId,
    bool cancellable = false,
  }) {
    final id = _uuid.v4();
    final token = CancellationToken();
    _tokens[id] = token;
    final record = OperationRecord(
      id: id,
      toolId: toolId,
      title: title,
      status: OperationStatus.running,
      startedAt: DateTime.now(),
      workspaceId: workspaceId,
      cancellable: cancellable,
    );
    state = ActivityState(
      operations: [record, ...state.operations],
      notices: state.notices,
    );
    return OperationHandle._(this, id, token);
  }

  /// Runs [body] as a tracked operation. Cancellation and errors are
  /// recorded; errors are rethrown so callers can show them inline.
  Future<T> run<T>({
    required String toolId,
    required String title,
    required Future<T> Function(OperationHandle op) body,
    String Function(T result)? summary,
    Map<String, num> Function(T result)? counts,
    String? workspaceId,
    bool cancellable = false,
    bool notify = true,
  }) async {
    final op = start(
      toolId: toolId,
      title: title,
      workspaceId: workspaceId,
      cancellable: cancellable,
    );
    try {
      final result = await body(op);
      if (!op.isFinished) {
        op.succeed(
          summary?.call(result) ?? 'Completed',
          counts: counts?.call(result) ?? const {},
          notify: notify,
        );
      }
      return result;
    } on OperationCancelled {
      op.cancelled();
      rethrow;
    } catch (e) {
      op.fail(e);
      rethrow;
    }
  }

  void cancel(String operationId) => _tokens[operationId]?.cancel();

  void notify(NoticeKind kind, String message) {
    state = ActivityState(
      operations: state.operations,
      notices: [...state.notices, Notice(kind, message, id: ++_noticeSeq)],
    );
  }

  void dismissNotice(int id) {
    state = ActivityState(
      operations: state.operations,
      notices: state.notices.where((n) => n.id != id).toList(),
    );
  }

  Future<void> clearHistory() async {
    state = ActivityState(
      operations: state.running,
      notices: state.notices,
    );
    await _persist();
  }

  void _patch(String id, OperationRecord Function(OperationRecord) f) {
    state = ActivityState(
      operations: [
        for (final o in state.operations) o.id == id ? f(o) : o,
      ],
      notices: state.notices,
    );
  }

  void _complete(
    String id, {
    required OperationStatus status,
    String? summary,
    String? error,
    Map<String, num> counts = const {},
    List<String> details = const [],
    bool notify = true,
  }) {
    _tokens.remove(id);
    OperationRecord? done;
    _patch(id, (r) {
      done = r.copyWith(
        status: status,
        endedAt: DateTime.now(),
        summary: summary,
        error: error,
        counts: counts,
        details: details.take(50).toList(),
        clearProgress: true,
      );
      return done!;
    });
    if (notify && done != null) {
      final d = done!;
      final kind = switch (status) {
        OperationStatus.succeeded => NoticeKind.success,
        OperationStatus.warning => NoticeKind.warning,
        OperationStatus.failed => NoticeKind.error,
        OperationStatus.cancelled => NoticeKind.info,
        OperationStatus.running => NoticeKind.info,
      };
      final text = switch (status) {
        OperationStatus.failed => '${d.title}: ${d.error}',
        _ => '${d.title}: ${d.summary ?? status.label}',
      };
      this.notify(kind, text);
    }
    unawaited(_persist());
  }

  Future<void> _persist() {
    final finished = state.operations
        .where((o) => o.status.isFinished)
        .take(historyLimit)
        .map((o) => o.toJson())
        .toList();
    return ref.read(appStoresProvider).history.save({'operations': finished});
  }
}

final activityProvider = NotifierProvider<ActivityController, ActivityState>(
  ActivityController.new,
);
