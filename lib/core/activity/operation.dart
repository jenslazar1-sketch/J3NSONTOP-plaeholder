import '../storage/json_store.dart';

enum OperationStatus {
  running('RUNNING'),
  succeeded('DONE'),
  warning('DONE WITH WARNINGS'),
  failed('FAILED'),
  cancelled('CANCELLED');

  const OperationStatus(this.label);
  final String label;

  bool get isFinished => this != running;
}

/// A real operation performed by a tool (never decorative).
class OperationRecord {
  const OperationRecord({
    required this.id,
    required this.toolId,
    required this.title,
    required this.status,
    required this.startedAt,
    this.endedAt,
    this.summary,
    this.error,
    this.details = const [],
    this.counts = const {},
    this.progress,
    this.progressMessage,
    this.workspaceId,
    this.cancellable = false,
  });

  final String id;
  final String toolId;
  final String title;
  final OperationStatus status;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String? summary;
  final String? error;

  /// Short detail lines (paths affected, warnings). Kept small.
  final List<String> details;

  /// Real counts, e.g. {'files': 12, 'bytes': 40960}.
  final Map<String, num> counts;

  /// 0..1, or null when indeterminate. Only meaningful while running.
  final double? progress;
  final String? progressMessage;
  final String? workspaceId;
  final bool cancellable;

  Duration? get elapsed => endedAt?.difference(startedAt);

  OperationRecord copyWith({
    OperationStatus? status,
    DateTime? endedAt,
    String? summary,
    String? error,
    List<String>? details,
    Map<String, num>? counts,
    double? progress,
    bool clearProgress = false,
    String? progressMessage,
  }) {
    return OperationRecord(
      id: id,
      toolId: toolId,
      title: title,
      status: status ?? this.status,
      startedAt: startedAt,
      endedAt: endedAt ?? this.endedAt,
      summary: summary ?? this.summary,
      error: error ?? this.error,
      details: details ?? this.details,
      counts: counts ?? this.counts,
      progress: clearProgress ? null : (progress ?? this.progress),
      progressMessage: progressMessage ?? this.progressMessage,
      workspaceId: workspaceId,
      cancellable: cancellable,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'toolId': toolId,
    'title': title,
    'status': status.name,
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
    if (summary != null) 'summary': summary,
    if (error != null) 'error': error,
    if (details.isNotEmpty) 'details': details,
    if (counts.isNotEmpty) 'counts': counts,
    if (workspaceId != null) 'workspaceId': workspaceId,
  };

  static OperationRecord? fromJson(Map<String, dynamic> j) {
    final id = JsonRead.optString(j, 'id');
    final started = JsonRead.dateTime(j, 'startedAt');
    if (id == null || started == null) return null;
    var status = JsonRead.enumByName(
      j,
      'status',
      OperationStatus.values,
      OperationStatus.failed,
    );
    String? error = JsonRead.optString(j, 'error');
    // An operation persisted while running never finished (app closed).
    if (status == OperationStatus.running) {
      status = OperationStatus.failed;
      error ??= 'Interrupted: the app closed before the operation finished.';
    }
    final counts = <String, num>{};
    JsonRead.object(j, 'counts').forEach((k, v) {
      if (v is num) counts[k] = v;
    });
    return OperationRecord(
      id: id,
      toolId: JsonRead.string(j, 'toolId', 'unknown'),
      title: JsonRead.string(j, 'title', 'Operation'),
      status: status,
      startedAt: started,
      endedAt: JsonRead.dateTime(j, 'endedAt'),
      summary: JsonRead.optString(j, 'summary'),
      error: error,
      details: JsonRead.stringList(j, 'details'),
      counts: counts,
      workspaceId: JsonRead.optString(j, 'workspaceId'),
    );
  }
}
