import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/commands/terminal_command.dart';
import 'package:j3nsontop_multitool/features/terminal/commands/builtin_commands.dart';

const _docPath = 'docs/TERMINAL.md';
const _begin = '<!-- BEGIN GENERATED COMMAND REFERENCE -->';
const _end = '<!-- END GENERATED COMMAND REFERENCE -->';

/// Markdown reference of the visible built-in commands, in registration
/// order. docs/TERMINAL.md embeds exactly this text between the markers.
String commandReference(List<TerminalCommand> commands) {
  final b = StringBuffer();
  for (final c in commands.where((c) => !c.hidden)) {
    b
      ..writeln('### `${c.name}`')
      ..writeln()
      ..writeln('${c.summary}.')
      ..writeln()
      ..writeln('- Usage: `${c.usage}`');
    if (c.aliases.isNotEmpty) b.writeln('- Aliases: ${c.aliases.map((a) => '`$a`').join(', ')}');
    if (c.args.isNotEmpty) {
      b.writeln('- Arguments:');
      for (final a in c.args) {
        final values = a.values.isEmpty ? '' : ' Values: ${a.values.map((v) => '`$v`').join(', ')}.';
        b.writeln('  - `${a.name}`${a.optional ? ' (optional)' : ''}: ${a.description}.$values');
      }
    }
    if (c.valueOptions.isNotEmpty) {
      b.writeln('- Options: ${c.valueOptions.map((o) => '`--$o <value>`').join(', ')}');
    }
    if (c.examples.isNotEmpty) b.writeln('- Examples: ${c.examples.map((e) => '`$e`').join(', ')}');
    b.writeln();
  }
  return b.toString().trimRight();
}

void main() {
  test('docs/TERMINAL.md command reference matches the implementation', () {
    final file = File(_docPath);
    final doc = file.readAsStringSync();
    final start = doc.indexOf(_begin);
    final end = doc.indexOf(_end);
    expect(start, isNonNegative, reason: 'missing $_begin');
    expect(end, greaterThan(start), reason: 'missing $_end');
    final generated = commandReference(kBuiltinCommands);
    final current = doc.substring(start + _begin.length, end).trim();
    if (Platform.environment['UPDATE_TERMINAL_DOCS'] == '1' && current != generated) {
      file.writeAsStringSync('${doc.substring(0, start + _begin.length)}\n\n$generated\n\n${doc.substring(end)}');
      return;
    }
    expect(
      current,
      generated,
      reason: 'Regenerate with: UPDATE_TERMINAL_DOCS=1 flutter test test/features/terminal/terminal_docs_test.dart',
    );
  });

  test('docs state that the terminal is not a system shell', () {
    final doc = File(_docPath).readAsStringSync();
    expect(doc, contains('not a system shell'));
    expect(doc, contains('never'));
  });
}
