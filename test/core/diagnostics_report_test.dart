import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/app/app_info.dart';
import 'package:j3nsontop_multitool/core/diagnostics/diagnostics_report.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/core/settings/app_settings.dart';

void main() {
  final now = DateTime.utc(2026, 9, 26, 12);

  String build({
    List<String> errors = const [],
    String? logContents,
    int? logBytes,
    String home = '/home/tester',
    String dataRoot = '/home/tester/.local/share/j3',
  }) => DiagnosticsReport.build(
    platform: AppPlatform.android,
    dataRoot: dataRoot,
    settings: const AppSettings(),
    now: now,
    display: const DisplayFacts(
      width: 360,
      height: 780,
      pixelRatio: 3,
      textScale: 1.3,
      reduceMotion: true,
      highContrast: false,
    ),
    errors: errors,
    errorLogPath: '$home/.local/share/j3/logs/errors.log',
    errorLogBytes: logBytes,
    errorLogContents: logContents,
    home: home,
  );

  test('identifies the build, platform, display and settings', () {
    final text = build();
    expect(text, contains('${AppInfo.shortName} diagnostics'));
    expect(text, contains('Generated: 2026-09-26T12:00:00.000Z'));
    expect(text, contains('App: ${AppInfo.version} (build ${AppInfo.buildNumber}), label ${AppInfo.buildLabel}'));
    expect(text, contains('App id: ${AppInfo.applicationId}'));
    expect(text, contains('Platform: ${AppPlatform.android.label}'));
    expect(text, contains('Display: 360x780 logical @3.00x, text scale 1.30, system reduce motion: yes'));
    expect(text, contains('Settings: ${jsonEncode(const AppSettings().toJson())}'));
    expect(text, contains('Errors this session: 0'));
    expect(text, contains('(not created yet)'));
    expect(text, isNot(contains('Recent errors')));
  });

  test('shortens the home folder everywhere, including errors and the log', () {
    final text = build(
      errors: ['[t] flutter: FileSystemException: /home/tester/secret.txt\n#0 main (file:///home/tester/app.dart)'],
      logContents: 'old error at /home/tester/x',
      logBytes: 27,
    );
    expect(text, isNot(contains('/home/tester')));
    expect(text, contains('Data folder: ~/.local/share/j3'));
    expect(text, contains('Error log: ~/.local/share/j3/logs/errors.log (27 bytes)'));
    expect(text, contains('FileSystemException: ~/secret.txt'));
    expect(text, contains('--- errors.log ---\nold error at ~/x'));
  });

  test('redacts both slash styles of a Windows profile folder', () {
    const home = r'C:\Users\Tester';
    expect(
      DiagnosticsReport.redactHome(r'C:\Users\Tester\AppData\x and C:/Users/Tester/y', home),
      r'~\AppData\x and ~/y',
    );
    expect(DiagnosticsReport.redactHome('/data/app', null), '/data/app');
  });

  test('keeps the newest errors and trims long stacks', () {
    final errors = [
      for (var i = 1; i <= 7; i++) ['[t] flutter: error $i', for (var s = 0; s < 10; s++) '#$s frame'].join('\n'),
    ];
    final text = build(errors: errors);
    expect(text, contains('Recent errors (newest last, 5 of 7):'));
    expect(text, isNot(contains('error 2\n')));
    expect(text, contains('error 3'));
    expect(text, contains('error 7'));
    expect(text, contains('#5 frame'));
    expect(text, isNot(contains('#6 frame')));
    expect(text, contains('... 4 more stack lines'));
  });
}
