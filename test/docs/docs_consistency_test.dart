import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/app/app_info.dart';
import 'package:j3nsontop_multitool/app/tool_catalog.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/core/tools/tool_definition.dart';

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

/// Tool list exactly as it must appear in README.md, from the real registry.
String toolTableMarkdown() {
  final registry = buildToolRegistry();
  final b = StringBuffer()
    ..writeln('| Section | Tool | ID | What it does |')
    ..writeln('| --- | --- | --- | --- |');
  for (final section in ToolSection.values) {
    for (final t in registry.inSection(section)) {
      b.writeln('| ${section.label} | ${t.name} | `${t.id}` | ${t.description.replaceAll('|', '/')} |');
    }
  }
  return b.toString().trimRight();
}

/// Terminal commands exactly as listed in README.md.
String commandListMarkdown() {
  final registry = buildToolRegistry();
  return [
    for (final c in registry.commands)
      if (!c.hidden) '- `${c.usage}` - ${c.summary}',
  ].join('\n');
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

  test('README lists every registered tool and terminal command', () {
    final readme = File('README.md').readAsStringSync();
    final tools = toolTableMarkdown();
    final commands = commandListMarkdown();
    if (!readme.contains(tools) || !readme.contains(commands)) {
      // ignore: avoid_print
      print('Expected README.md to contain:\n$tools\n\n$commands');
    }
    expect(readme.contains(tools), isTrue, reason: 'Update the tool table in README.md (printed above).');
    expect(readme.contains(commands), isTrue, reason: 'Update the command list in README.md (printed above).');
  });

  test('README uses the exact product name and application id', () {
    final readme = File('README.md').readAsStringSync();
    expect(readme, contains(AppInfo.fullName));
    expect(readme, contains(AppInfo.applicationId));
    expect(readme, contains(AppInfo.version));
  });
}
