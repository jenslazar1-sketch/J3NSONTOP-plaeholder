import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../tasks/cancellation.dart';
import '../utils/safe_path.dart';
import 'app_paths.dart';
import 'capabilities.dart';

/// A file obtained from the system picker, already copied to a readable
/// local path inside app storage (Android/iOS pickers may return
/// `content://` URIs that are not directly readable as files).
class PickedLocalFile {
  const PickedLocalFile({required this.name, required this.path, required this.size});
  final String name;
  final String path;
  final int size;
}

/// Outcome of an export/save.
class ExportResult {
  const ExportResult._(this.saved, this.location, this.cancelled, this.error);

  const ExportResult.saved(String? location) : this._(true, location, false, null);
  const ExportResult.cancelled() : this._(false, null, true, null);
  const ExportResult.failed(String error) : this._(false, null, false, error);

  final bool saved;

  /// Where the file went, if the platform tells us (path or URI string).
  final String? location;
  final bool cancelled;
  final String? error;
}

/// Platform adapter for all user-driven file access. Every method uses the
/// public, permission-scoped OS dialogs; nothing reads outside what the user
/// picked.
abstract class FileAccessService {
  /// Opens the system document picker and copies the chosen files into
  /// [destinationDir] (default: the app's picked-files cache). Returns an
  /// empty list when the user cancels.
  Future<List<PickedLocalFile>> pickFiles({
    bool multiple = true,
    List<String>? extensions,
    String? destinationDir,
    CancellationToken? token,
  });

  /// Desktop only: returns a folder path chosen by the user, or null.
  Future<String?> pickDirectory({String? title});

  /// Saves [bytes] through the system save dialog.
  Future<ExportResult> saveBytes({
    required String suggestedName,
    required Uint8List bytes,
    String mimeType = 'application/octet-stream',
  });

  /// Hands local files to the system share sheet (mobile).
  Future<ExportResult> shareFiles(List<String> paths, {String? text});

  /// Opens the system file manager at [path] (desktop).
  Future<bool> reveal(String path);

  /// Copies text to the clipboard.
  Future<void> copyText(String text) => Clipboard.setData(ClipboardData(text: text));
}

class PlatformFileAccessService extends FileAccessService {
  PlatformFileAccessService(this._paths, this._caps);

  final AppPaths _paths;
  final CapabilityMatrix _caps;

  @override
  Future<List<PickedLocalFile>> pickFiles({
    bool multiple = true,
    List<String>? extensions,
    String? destinationDir,
    CancellationToken? token,
  }) async {
    final List<PlatformFile> picked;
    if (multiple) {
      picked = await FilePicker.pickFiles(
        type: extensions == null ? FileType.any : FileType.custom,
        allowedExtensions: extensions,
      );
    } else {
      final one = await FilePicker.pickFile(
        type: extensions == null ? FileType.any : FileType.custom,
        allowedExtensions: extensions,
      );
      picked = one == null ? const [] : [one];
    }
    if (picked.isEmpty) return const [];
    final dest = destinationDir ??
        p.join(_paths.pickedDir, DateTime.now().microsecondsSinceEpoch.toString());
    await Directory(dest).create(recursive: true);
    final out = <PickedLocalFile>[];
    for (final f in picked) {
      token?.throwIfCancelled();
      final name = SafePath.sanitizeFileName(f.name);
      final target = SafePath.uniquePath(p.join(dest, name));
      final sink = File(target).openWrite();
      var size = 0;
      try {
        await for (final chunk in f.readAsByteStream()) {
          token?.throwIfCancelled();
          sink.add(chunk);
          size += chunk.length;
        }
      } finally {
        await sink.close();
      }
      out.add(PickedLocalFile(name: p.basename(target), path: target, size: size));
    }
    return out;
  }

  @override
  Future<String?> pickDirectory({String? title}) async {
    if (!_caps.supports(Capability.linkFolder)) return null;
    return FilePicker.getDirectoryPath(dialogTitle: title);
  }

  @override
  Future<ExportResult> saveBytes({
    required String suggestedName,
    required Uint8List bytes,
    String mimeType = 'application/octet-stream',
  }) async {
    try {
      final uri = await FilePicker.saveFile(
        fileName: SafePath.sanitizeFileName(suggestedName),
        bytes: bytes,
        mimeType: mimeType,
      );
      if (uri == null) return const ExportResult.cancelled();
      return ExportResult.saved(
        uri.scheme == 'file' ? uri.toFilePath() : uri.toString(),
      );
    } on PlatformException catch (e) {
      return ExportResult.failed(e.message ?? e.code);
    } catch (e) {
      return ExportResult.failed(e.toString());
    }
  }

  @override
  Future<ExportResult> shareFiles(List<String> paths, {String? text}) async {
    try {
      final result = await SharePlus.instance.share(
        ShareParams(files: [for (final path in paths) XFile(path)], text: text),
      );
      return switch (result.status) {
        ShareResultStatus.success => const ExportResult.saved(null),
        ShareResultStatus.dismissed => const ExportResult.cancelled(),
        ShareResultStatus.unavailable => const ExportResult.saved(null),
      };
    } catch (e) {
      return ExportResult.failed(e.toString());
    }
  }

  @override
  Future<bool> reveal(String path) async {
    if (!_caps.supports(Capability.revealInFileManager)) return false;
    try {
      if (Platform.isWindows) {
        final isFile = await FileSystemEntity.isFile(path);
        await Process.start('explorer.exe', [if (isFile) '/select,$path' else path]);
        return true;
      }
      if (Platform.isLinux) {
        final dir = await FileSystemEntity.isDirectory(path) ? path : p.dirname(path);
        await Process.start('xdg-open', [dir]);
        return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }
}

final fileAccessProvider = Provider<FileAccessService>(
  (ref) => PlatformFileAccessService(
    ref.watch(appPathsProvider),
    ref.watch(capabilitiesProvider),
  ),
);
