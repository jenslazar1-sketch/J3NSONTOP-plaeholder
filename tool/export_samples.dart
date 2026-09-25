// Exports the NEON DUNGEON sample content to a folder (default: samples/).
//
//   dart run tool/export_samples.dart [outDir=samples]
//
// Writes samples/neon-dungeon/** (the sample workspace), samples/packages/,
// samples/profiles/, samples/README.md and samples/SHA256SUMS.txt. The output
// is deterministic, so re-running it on any machine produces identical bytes.
import 'dart:io';

import 'package:j3nsontop_multitool/features/sample/sample_export.dart';

Future<void> main(List<String> args) async {
  final outDir = args.isNotEmpty ? args.first : 'samples';
  final sw = Stopwatch()..start();
  final result = await exportSamples(outDir);
  final keys = result.files.keys.toList()..sort();
  for (final k in keys) {
    stdout.writeln('${result.files[k]!.length.toString().padLeft(8)}  $k');
  }
  stdout.writeln(
    'Exported ${result.files.length} files (${result.totalBytes} bytes) to ${result.outDir} '
    'in ${sw.elapsedMilliseconds} ms',
  );
}
