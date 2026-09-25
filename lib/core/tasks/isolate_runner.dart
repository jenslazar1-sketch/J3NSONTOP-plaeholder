import 'dart:async';
import 'dart:isolate';

import 'cancellation.dart';

/// Thrown when [runBounded] exceeds its time budget.
class OperationTimedOut implements Exception {
  const OperationTimedOut(this.timeout);
  final Duration timeout;
  @override
  String toString() => 'Stopped after ${timeout.inMilliseconds} ms (time limit reached)';
}

/// Runs [computation] in a fresh isolate with a hard time limit.
///
/// Unlike `Isolate.run`, the worker is killed when [timeout] elapses or
/// [token] is cancelled, so pathological inputs (for example catastrophic
/// regex backtracking) can never freeze the UI or keep burning CPU.
///
/// [computation] must be a top-level or static function, or a closure that
/// only captures sendable values.
Future<R> runBounded<R>(
  FutureOr<R> Function() computation, {
  required Duration timeout,
  CancellationToken? token,
  String debugName = 'j3-worker',
}) async {
  final resultPort = RawReceivePort();
  final completer = Completer<R>();
  Isolate? isolate;
  Timer? timer;

  void finish() {
    timer?.cancel();
    resultPort.close();
    isolate?.kill(priority: Isolate.immediate);
  }

  resultPort.handler = (Object? message) {
    if (completer.isCompleted) return;
    if (message is List && message.length == 2) {
      final ok = message[0] as bool;
      if (ok) {
        completer.complete(message[1] as R);
      } else {
        final err = message[1] as List;
        completer.completeError(_RemoteError(err[0] as String), StackTrace.fromString(err[1] as String));
      }
    } else {
      completer.completeError(StateError('worker exited unexpectedly'));
    }
    finish();
  };

  try {
    isolate = await Isolate.spawn<_Job<R>>(
      _entry,
      _Job<R>(computation, resultPort.sendPort),
      onExit: resultPort.sendPort,
      errorsAreFatal: true,
      debugName: debugName,
    );
  } catch (e) {
    resultPort.close();
    rethrow;
  }

  timer = Timer(timeout, () {
    if (!completer.isCompleted) {
      completer.completeError(OperationTimedOut(timeout));
      finish();
    }
  });
  unawaited(
    token?.whenCancelled.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(const OperationCancelled());
        finish();
      }
    }),
  );
  return completer.future;
}

class _Job<R> {
  _Job(this.computation, this.port);
  final FutureOr<R> Function() computation;
  final SendPort port;
}

Future<void> _entry<R>(_Job<R> job) async {
  try {
    final result = await job.computation();
    Isolate.exit(job.port, <Object?>[true, result]);
  } catch (e, st) {
    Isolate.exit(job.port, <Object?>[
      false,
      <String>[e.toString(), st.toString()],
    ]);
  }
}

class _RemoteError implements Exception {
  _RemoteError(this.message);
  final String message;
  @override
  String toString() => message;
}
