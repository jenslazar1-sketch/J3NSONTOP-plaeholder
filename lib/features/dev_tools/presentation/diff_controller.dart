import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/common.dart';
import '../domain/text_diff.dart';

class DiffToolState {
  const DiffToolState({
    this.running = false,
    this.outcome,
    this.error,
    this.ignoreWhitespace = false,
    this.ignoreCase = false,
  });

  final bool running;
  final TextDiffOutcome? outcome;
  final InputError? error;

  /// Options the current [outcome] was computed with.
  final bool ignoreWhitespace;
  final bool ignoreCase;
}

/// Computes diffs (large inputs in a background isolate). Only the latest
/// request updates the state.
class DiffToolController extends Notifier<DiffToolState> {
  int _generation = 0;

  @override
  DiffToolState build() => const DiffToolState();

  Future<void> compare(String a, String b, {required bool ignoreWhitespace, required bool ignoreCase}) async {
    final gen = ++_generation;
    state = DiffToolState(
      running: true,
      outcome: state.outcome,
      ignoreWhitespace: state.ignoreWhitespace,
      ignoreCase: state.ignoreCase,
    );
    try {
      final o = await TextDiff.computeAsync(a, b, ignoreWhitespace: ignoreWhitespace, ignoreCase: ignoreCase);
      if (gen != _generation || !ref.mounted) return;
      state = DiffToolState(outcome: o, ignoreWhitespace: ignoreWhitespace, ignoreCase: ignoreCase);
    } on InputError catch (e) {
      if (gen != _generation || !ref.mounted) return;
      state = DiffToolState(error: e);
    } catch (e) {
      if (gen != _generation || !ref.mounted) return;
      state = DiffToolState(error: InputError('Diff failed: $e'));
    }
  }

  void clear() {
    _generation++;
    state = const DiffToolState();
  }
}

final diffToolProvider = NotifierProvider<DiffToolController, DiffToolState>(DiffToolController.new);
