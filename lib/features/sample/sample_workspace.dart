import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/workspace/workspace.dart';

// TODO(agent): implement the sample workspace service (see docs/SAMPLES.md).

/// Creates the disposable sample workspace on first run (real files), once.
Future<void> ensureSampleWorkspaceOnFirstRun(WidgetRef ref) async {}

/// Creates a fresh sample workspace (even if one exists) and returns it.
/// Any feature may call this (e.g. "Create sample workspace" buttons).
Future<Workspace> createSampleWorkspace(WidgetRef ref) =>
    throw UnimplementedError('createSampleWorkspace is implemented by the sample feature');
