import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Writes [bytes] to [path] atomically: the data is written and flushed to a
/// sibling temporary file which then replaces the target via rename. A crash
/// mid-write leaves either the old file or the new file, never a torn file.
///
/// On Windows, `rename` onto an existing file can fail when another process
/// holds it open; in that case the previous file is moved aside first and
/// restored if the final rename fails.
Future<void> atomicWriteBytes(String path, List<int> bytes) async {
  final target = File(path);
  await target.parent.create(recursive: true);
  final tmp = File('$path.tmp');
  final raf = await tmp.open(mode: FileMode.write);
  try {
    await raf.writeFrom(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    await raf.flush();
  } finally {
    await raf.close();
  }
  try {
    await tmp.rename(path);
  } on FileSystemException {
    // Fallback for platforms/filesystems that refuse to replace on rename.
    final aside = File('$path.replaced');
    var movedAside = false;
    if (await target.exists()) {
      if (await aside.exists()) await aside.delete();
      await target.rename(aside.path);
      movedAside = true;
    }
    try {
      await tmp.rename(path);
      if (movedAside) await aside.delete();
    } catch (_) {
      if (movedAside && !await target.exists()) {
        await aside.rename(path);
      }
      rethrow;
    }
  }
}

Future<void> atomicWriteString(String path, String contents) =>
    atomicWriteBytes(path, utf8.encode(contents));

/// Pretty JSON used for every document the app persists.
const JsonEncoder prettyJson = JsonEncoder.withIndent('  ');
