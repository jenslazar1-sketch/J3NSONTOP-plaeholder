import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/workspace/workspace.dart';
import '../features/dev_tools/dev_smoke.dart';
import '../features/sample/sample_smoke.dart';

/// A feature-level self-test step run by `--smoke-test`. Each step performs
/// a real operation inside the throwaway smoke workspace and returns a short
/// detail string (or throws).
class FeatureSmokeStep {
  const FeatureSmokeStep(this.name, this.run);
  final String name;
  final Future<String?> Function(WidgetRef ref, Workspace smokeWorkspace) run;
}

/// Feature operations exercised by the packaged-app smoke test.
final List<FeatureSmokeStep> featureSmokeSteps = [sampleSmokeStep, devToolsSmokeStep];
