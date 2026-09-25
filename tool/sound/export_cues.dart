// Writes the intro timing cues used by generate_intro_sound.py.
//
//   dart run tool/sound/export_cues.dart
//
// The Dart timeline (lib/features/intro/intro_timeline.dart) is the single
// source of truth; test/features/intro/intro_timeline_test.dart fails if
// tool/sound/intro_cues.json is stale.
import 'dart:convert';
import 'dart:io';

import 'package:j3nsontop_multitool/features/intro/intro_timeline.dart';

void main() {
  final json = const JsonEncoder.withIndent('  ').convert(IntroTimeline().cueSheet());
  File('tool/sound/intro_cues.json').writeAsStringSync('$json\n');
  stdout.writeln('wrote tool/sound/intro_cues.json');
}
