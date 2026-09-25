import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Records uncaught errors to `<data>/logs/errors.log` (and keeps the most
/// recent ones in memory) without swallowing them: errors are still
/// reported through Flutter's normal presentation.
class ErrorLog {
  ErrorLog._();
  static final ErrorLog instance = ErrorLog._();

  String? _path;
  final List<String> recent = [];

  /// Number of uncaught errors seen in this process (used by smoke tests).
  int get count => recent.length;

  void attach(String dataRoot) {
    _path = p.join(dataRoot, 'logs', 'errors.log');
  }

  void record(Object error, StackTrace? stack, {String source = 'uncaught'}) {
    final entry = '[${DateTime.now().toUtc().toIso8601String()}] $source: $error\n${stack ?? ''}';
    recent.add(entry);
    if (recent.length > 50) recent.removeAt(0);
    debugPrint(entry);
    final path = _path;
    if (path == null) return;
    try {
      final f = File(path);
      f.parent.createSync(recursive: true);
      // Keep the log bounded (~1 MB).
      if (f.existsSync() && f.lengthSync() > 1 << 20) {
        f.renameSync('$path.1');
      }
      f.writeAsStringSync('$entry\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Logging must never crash the app; the error was already printed.
    }
  }

  void install() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      record(details.exception, details.stack, source: 'flutter');
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack, source: 'platform');
      // Returning false lets the engine apply its default handling too.
      return false;
    };
  }
}
