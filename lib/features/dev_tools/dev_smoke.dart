import 'dart:convert';

import '../../app/smoke_steps.dart';
import '../../core/tasks/isolate_runner.dart';
import 'domain/base64_tools.dart';
import 'domain/regex_tools.dart';
import 'domain/uuid_tools.dart';

/// Packaged-app self test for the developer tools: codec round trip, v7 UUID
/// ordering, and — most importantly on each real platform — that a
/// catastrophically backtracking regex is killed at its time limit instead
/// of hanging (the isolate kill path).
final FeatureSmokeStep devToolsSmokeStep = FeatureSmokeStep('dev tools (base64, uuid v7, bounded regex)', (
  ref,
  workspace,
) async {
  const text = 'J3NSONTOP SYSTEM ONLINE ✓ 名前';
  final encoded = Base64Tools.encodeText(text, urlSafe: true, padding: false);
  final decoded = utf8.decode(Base64Tools.decode(encoded).bytes);
  if (decoded != text) throw StateError('base64 round trip mismatch');

  final ids = UuidTools.generate(UuidKind.v7, 5);
  final sorted = [...ids]..sort();
  if (ids.join() != sorted.join() || ids.toSet().length != 5) throw StateError('v7 UUIDs not strictly increasing');

  final ok = await runRegexBounded(RegexJob(pattern: r'\d+', flags: const RegexFlags(), input: 'a1b22c333'));
  if (ok.matches.length != 3) throw StateError('regex expected 3 matches, got ${ok.matches.length}');

  final sw = Stopwatch()..start();
  try {
    await runRegexBounded(
      RegexJob(pattern: r'^(a+)+$', flags: const RegexFlags(), input: '${'a' * 40}!'),
      timeout: const Duration(milliseconds: 400),
    );
    throw StateError('catastrophic regex was not stopped');
  } on OperationTimedOut {
    // Expected: the worker isolate was killed.
  }
  return 'base64 ok, ${ids.length} ordered v7 ids, runaway regex stopped in ${sw.elapsedMilliseconds} ms';
});
