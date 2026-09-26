import 'dart:convert';
import 'dart:io';

import '../../app/app_info.dart';
import '../platform/capabilities.dart';
import '../settings/app_settings.dart';

/// Display facts captured from `MediaQuery` by the caller.
class DisplayFacts {
  const DisplayFacts({
    required this.width,
    required this.height,
    required this.pixelRatio,
    required this.textScale,
    required this.reduceMotion,
    required this.highContrast,
  });

  final double width;
  final double height;
  final double pixelRatio;
  final double textScale;
  final bool reduceMotion;
  final bool highContrast;
}

/// Plain-text facts a tester pastes into a bug report. Built only when the
/// user asks for it; the app never sends it anywhere. The user's home folder
/// is shortened to `~` so reports do not reveal account names.
abstract final class DiagnosticsReport {
  /// Stack lines kept per error in the summary.
  static const int stackLines = 6;

  static String build({
    required AppPlatform platform,
    required String dataRoot,
    required AppSettings settings,
    required DateTime now,
    DisplayFacts? display,
    List<String> errors = const [],
    int maxErrors = 5,
    String? errorLogPath,
    int? errorLogBytes,
    String? errorLogContents,
    String? home,
  }) {
    final homeDir = home ?? homeDirectory();
    String r(String text) => redactHome(text, homeDir);
    final b = StringBuffer()
      ..writeln('${AppInfo.shortName} diagnostics')
      ..writeln('Generated: ${now.toUtc().toIso8601String()}')
      ..writeln('App: ${AppInfo.version} (build ${AppInfo.buildNumber}), label ${AppInfo.buildLabel}')
      ..writeln('App id: ${AppInfo.applicationId}')
      ..writeln('Platform: ${platform.label} (${Platform.operatingSystem} ${Platform.operatingSystemVersion})')
      ..writeln('Dart: ${Platform.version.split(' ').first}')
      ..writeln('Locale: ${Platform.localeName}');
    if (display != null) {
      b.writeln(
        'Display: ${display.width.round()}x${display.height.round()} logical @${display.pixelRatio.toStringAsFixed(2)}x, '
        'text scale ${display.textScale.toStringAsFixed(2)}, '
        'system reduce motion: ${_yesNo(display.reduceMotion)}, high contrast: ${_yesNo(display.highContrast)}',
      );
    }
    b
      ..writeln('Settings: ${jsonEncode(settings.toJson())}')
      ..writeln('Data folder: ${r(dataRoot)}')
      ..writeln('Errors this session: ${errors.length}')
      ..writeln(
        'Error log: ${errorLogPath == null ? 'not attached' : r(errorLogPath)}'
        '${errorLogBytes == null ? ' (not created yet)' : ' ($errorLogBytes bytes)'}',
      );
    if (errors.isNotEmpty) {
      final shown = errors.length > maxErrors ? errors.sublist(errors.length - maxErrors) : errors;
      b
        ..writeln()
        ..writeln('Recent errors (newest last, ${shown.length} of ${errors.length}):');
      for (final e in shown) {
        final lines = r(e).trimRight().split('\n');
        b.writeln(lines.take(1 + stackLines).join('\n'));
        if (lines.length > 1 + stackLines) b.writeln('  ... ${lines.length - 1 - stackLines} more stack lines');
      }
    }
    if (errorLogContents != null) {
      b
        ..writeln()
        ..writeln('--- errors.log ---')
        ..writeln(r(errorLogContents).trimRight());
    }
    return b.toString();
  }

  /// The current user's home folder, if the platform exposes it.
  static String? homeDirectory() {
    final env = Platform.environment;
    final home = Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
    return (home == null || home.isEmpty) ? null : home;
  }

  /// Replaces [home] (and, on Windows, its other slash style) with `~`.
  static String redactHome(String text, String? home) {
    if (home == null || home.length < 2) return text;
    var out = text.replaceAll(home, '~');
    final alt = home.contains(r'\') ? home.replaceAll(r'\', '/') : home.replaceAll('/', r'\');
    if (alt != home) out = out.replaceAll(alt, '~');
    return out;
  }

  static String _yesNo(bool v) => v ? 'yes' : 'no';
}
