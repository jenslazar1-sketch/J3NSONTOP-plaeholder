import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/status.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../data/workspace_transfer.dart';

/// A finished action's outcome shown on the manager page.
class ManagerReport {
  const ManagerReport({required this.kind, required this.title, this.message, this.details = const []});
  final StatusKind kind;
  final String title;
  final String? message;
  final List<String> details;
}

class ManagerState {
  const ManagerState({this.runningOpId, this.runningLabel, this.report, this.error, this.errorAction, this.orphans});

  final String? runningOpId;
  final String? runningLabel;
  final ManagerReport? report;
  final Object? error;
  final String? errorAction;

  /// Null until the storage scan ran.
  final List<OrphanStorage>? orphans;

  bool get busy => runningOpId != null;
}

/// Page state of the workspace manager (survives navigation).
class ManagerController extends Notifier<ManagerState> {
  @override
  ManagerState build() => const ManagerState();

  void running(String opId, String label) =>
      state = ManagerState(runningOpId: opId, runningLabel: label, report: state.report, orphans: state.orphans);

  void idle() => state = ManagerState(report: state.report, error: state.error, orphans: state.orphans);

  void report(ManagerReport r) => state = ManagerState(report: r, orphans: state.orphans);

  void error(Object e, String action) => state = ManagerState(error: e, errorAction: action, orphans: state.orphans);

  void clearMessages() =>
      state = ManagerState(orphans: state.orphans, runningOpId: state.runningOpId, runningLabel: state.runningLabel);

  void orphans(List<OrphanStorage>? list) => state = ManagerState(
    runningOpId: state.runningOpId,
    runningLabel: state.runningLabel,
    report: state.report,
    error: state.error,
    errorAction: state.errorAction,
    orphans: list,
  );
}

final managerStateProvider = NotifierProvider<ManagerController, ManagerState>(ManagerController.new);

/// Health of a workspace root (re-checked when records change or on
/// explicit refresh via `ref.invalidate`).
final workspaceHealthProvider = FutureProvider.family<WorkspaceHealth, String>((ref, id) async {
  final w = ref.watch(workspacesProvider.select((s) => s.byId(id)));
  if (w == null) return WorkspaceHealth.missing;
  return WorkspaceController.checkHealth(w);
});
