import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/app/app_info.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';

/// The capability matrix table exactly as it must appear in README.md.
/// Generated from [CapabilityMatrix.table] so docs cannot drift from code.
String capabilityTableMarkdown() {
  const platforms = [AppPlatform.android, AppPlatform.ios, AppPlatform.windows, AppPlatform.linux];
  final b = StringBuffer()
    ..writeln('| Capability | Android | iOS | Windows | Linux (dev) | Alternative when unavailable |')
    ..writeln('| --- | :-: | :-: | :-: | :-: | --- |');
  for (final c in Capability.values) {
    final cells = [for (final p in platforms) (CapabilityMatrix.table[c]?.contains(p) ?? false) ? 'yes' : 'no'];
    final alt = CapabilityMatrix.alternatives[c] ?? '-';
    b.writeln('| ${c.label} | ${cells.join(' | ')} | $alt |');
  }
  return b.toString().trimRight();
}

void main() {
  test('README contains the generated capability matrix', () {
    final readme = File('README.md').readAsStringSync();
    final table = capabilityTableMarkdown();
    if (!readme.contains(table)) {
      // ignore: avoid_print
      print('Expected README.md to contain:\n$table');
    }
    expect(readme.contains(table), isTrue, reason: 'Update the capability table in README.md (printed above).');
  });

  test('README uses the exact product name and application id', () {
    final readme = File('README.md').readAsStringSync();
    expect(readme, contains(AppInfo.fullName));
    expect(readme, contains(AppInfo.applicationId));
    expect(readme, contains(AppInfo.version));
  });
}
