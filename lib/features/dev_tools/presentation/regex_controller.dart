import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/tasks/cancellation.dart';
import '../../../core/tasks/isolate_runner.dart';
import '../domain/common.dart';
import '../domain/regex_tools.dart';

class RegexToolState {
  const RegexToolState({
    this.running = false,
    this.job,
    this.result,
    this.patternError,
    this.stopped,
    this.elapsed,
    this.selected = 0,
  });

  final bool running;

  /// The job the current [result] (or [stopped]) belongs to.
  final RegexJob? job;
  final RegexRunResult? result;
  final InputError? patternError;

  /// Why the last run stopped early (time limit or cancel).
  final String? stopped;
  final Duration? elapsed;
  final int selected;

  RegexToolState copyWith({bool? running, int? selected}) => RegexToolState(
    running: running ?? this.running,
    job: job,
    result: result,
    patternError: patternError,
    stopped: stopped,
    elapsed: elapsed,
    selected: selected ?? this.selected,
  );
}

/// Runs regex jobs in a killable worker (1.5 s limit, 10 000 matches).
/// A new run cancels the previous one.
class RegexToolController extends Notifier<RegexToolState> {
  static const Duration timeLimit = Duration(milliseconds: 1500);
  static const String timeLimitMessage = 'Stopped: time limit reached (pattern may backtrack catastrophically)';

  CancellationToken? _token;
  int _generation = 0;

  @override
  RegexToolState build() {
    ref.onDispose(() => _token?.cancel());
    return const RegexToolState();
  }

  Future<void> run(RegexJob job) async {
    _token?.cancel();
    final gen = ++_generation;
    if (job.pattern.isEmpty) {
      state = const RegexToolState();
      return;
    }
    final compileError = regexCompileError(job.pattern, job.flags);
    if (compileError != null) {
      state = RegexToolState(job: job, patternError: compileError);
      return;
    }
    final token = CancellationToken();
    _token = token;
    state = RegexToolState(
      running: true,
      job: state.job,
      result: state.result,
      elapsed: state.elapsed,
      selected: state.selected,
    );
    final sw = Stopwatch()..start();
    try {
      final r = await runRegexBounded(job, token: token, timeout: timeLimit);
      if (gen != _generation || !ref.mounted) return;
      state = RegexToolState(job: job, result: r, elapsed: sw.elapsed);
    } on OperationTimedOut {
      if (gen != _generation || !ref.mounted) return;
      state = RegexToolState(job: job, stopped: timeLimitMessage, elapsed: sw.elapsed);
    } on OperationCancelled {
      if (gen != _generation || !ref.mounted) return;
      state = RegexToolState(job: job, stopped: 'Cancelled after ${sw.elapsedMilliseconds} ms', elapsed: sw.elapsed);
    } catch (e) {
      if (gen != _generation || !ref.mounted) return;
      state = RegexToolState(job: job, patternError: InputError('Regex failed: $e'));
    }
  }

  void cancel() => _token?.cancel();

  void select(int index) => state = state.copyWith(selected: index);
}

final regexToolProvider = NotifierProvider<RegexToolController, RegexToolState>(RegexToolController.new);
