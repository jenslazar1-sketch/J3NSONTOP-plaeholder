import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/archive/safe_zip.dart';
import '../../../core/platform/capabilities.dart';
import '../../../core/tasks/cancellation.dart';
import '../../../core/tasks/isolate_runner.dart';
import '../../../core/utils/safe_path.dart';
import '../domain/image_codec.dart';

/// A unit of Asset Lab work. Must only capture sendable values (bytes,
/// numbers, strings, plain data objects) because it may run in another
/// isolate. Build tasks with the top-level helpers below so closures never
/// capture providers or widgets by accident.
typedef AssetTask<R> = FutureOr<R> Function();

/// Runs decoding, pixel work, encoding and file IO off the UI isolate.
abstract class AssetWorker {
  const AssetWorker();

  Future<R> run<R>(AssetTask<R> task, {CancellationToken? token, Duration timeout = const Duration(minutes: 3)});
}

/// Production worker: a fresh isolate per task, killed on timeout or
/// cancellation (so superseded previews stop burning CPU).
class IsolateAssetWorker extends AssetWorker {
  const IsolateAssetWorker();

  @override
  Future<R> run<R>(AssetTask<R> task, {CancellationToken? token, Duration timeout = const Duration(minutes: 3)}) =>
      runBounded<R>(task, timeout: timeout, token: token, debugName: 'asset-lab');
}

/// Runs tasks on the calling isolate. Used where background isolates are
/// unavailable and by widget tests (deterministic, no real async IO).
class InlineAssetWorker extends AssetWorker {
  const InlineAssetWorker();

  @override
  Future<R> run<R>(AssetTask<R> task, {CancellationToken? token, Duration timeout = const Duration(minutes: 3)}) {
    token?.throwIfCancelled();
    return Future<R>.sync(task).then((r) {
      token?.throwIfCancelled();
      return r;
    });
  }
}

final assetWorkerProvider = Provider<AssetWorker>((ref) {
  final caps = ref.watch(capabilitiesProvider);
  return caps.supports(Capability.backgroundIsolates) ? const IsolateAssetWorker() : const InlineAssetWorker();
});

// ---------------------------------------------------------------- tasks

/// Reads a whole file synchronously (call inside a worker), bounded by
/// [maxBytes].
Uint8List readFileBounded(String path, {int maxBytes = maxImageFileBytes}) {
  final f = File(path);
  final len = f.lengthSync();
  if (len > maxBytes) {
    throw FileSystemException('File is larger than ${maxBytes ~/ (1024 * 1024)} MB', path);
  }
  return f.readAsBytesSync();
}

/// Reads a whole file (bounded by [maxBytes]).
AssetTask<Uint8List> readFileTask(String path, {int maxBytes = maxImageFileBytes}) =>
    () => readFileBounded(path, maxBytes: maxBytes);

/// Reads and decodes an image for display and editing.
AssetTask<DecodedImage> decodeFileTask(String path, String name, {int previewMax = 1600}) =>
    () => decodeImageFile(readFileBounded(path), name, previewMax: previewMax);

/// Lists image files directly inside [dir] (sorted, not recursive).
AssetTask<List<String>> listImagesTask(String dir, {bool recursive = false}) => () {
  final exts = decodableImageExtensions.toSet();
  final out = <String>[];
  for (final e in Directory(dir).listSync(recursive: recursive, followLinks: false)) {
    if (e is! File) continue;
    final ext = p.extension(e.path).toLowerCase().replaceFirst('.', '');
    if (exts.contains(ext)) out.add(e.path);
  }
  out.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return out;
};

/// Writes [files] (name -> bytes) into [folder] inside [root] without ever
/// overwriting: an existing name gets ` (2)`, ` (3)`... Each file is
/// written to a temporary sibling and renamed into place. Returns the
/// absolute paths written, in order.
AssetTask<List<String>> writeNewFilesTask(String root, String folder, List<(String, Uint8List)> files) => () {
  if (!SafePath.isWithin(root, folder)) {
    throw FileSystemException('Refusing to write outside the workspace', folder);
  }
  final written = <String>[];
  for (final (name, bytes) in files) {
    final rel = SafePath.normalizeRelative(name);
    final desired = SafePath.resolveInside(folder, rel);
    Directory(p.dirname(desired)).createSync(recursive: true);
    final dest = SafePath.uniquePath(desired);
    final tmp = File('$dest.j3part');
    tmp.writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(dest);
    written.add(dest);
  }
  return written;
};

/// Builds a ZIP with [SafeZip.create] in [stagingDir] and returns its bytes
/// (the staging file is removed afterwards).
AssetTask<Uint8List> buildZipTask(String stagingDir, List<(String, Uint8List)> entries) => () async {
  final dir = Directory(p.join(stagingDir, 'zip-${DateTime.now().microsecondsSinceEpoch}'));
  dir.createSync(recursive: true);
  final zipPath = p.join(dir.path, 'bundle.zip');
  try {
    await SafeZip.create(zipPath, [for (final (name, bytes) in entries) ZipSource.bytes(name, bytes)]);
    return File(zipPath).readAsBytesSync();
  } finally {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // Staging cleanup is best effort; the cache folder is app-owned.
    }
  }
};

/// Wraps already prepared files as a task. Built here (top level) so the
/// closure captures only the list, never widget state.
AssetTask<List<(String, Uint8List)>> filesTask(List<(String, Uint8List)> files) =>
    () => files;
