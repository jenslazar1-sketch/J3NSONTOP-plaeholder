import 'dart:io';

import '../../../core/archive/safe_zip.dart';
import '../../../core/tasks/cancellation.dart';
import '../../../core/tasks/isolate_runner.dart';
import '../../../core/utils/safe_path.dart';

/// A readable explanation of a failure: what happened, and what to do.
class FriendlyError {
  const FriendlyError(this.title, this.message, [this.hint]);

  final String title;
  final String message;
  final String? hint;

  @override
  String toString() => hint == null ? '$title: $message' : '$title: $message ($hint)';
}

/// A user pattern exceeded its time budget while evaluating [files].
class PatternTimeoutException implements Exception {
  const PatternTimeoutException(this.limit, this.files);
  final Duration limit;
  final List<String> files;

  @override
  String toString() =>
      'The pattern needed more than ${limit.inMilliseconds} ms on ${files.isEmpty ? 'the input' : files.first}'
      '${files.length > 1 ? ' (batch of ${files.length} files)' : ''}';
}

/// Classified file-system failure kinds (platform independent).
enum FsProblem { noSpace, accessDenied, notFound, nameTooLong, readOnly, exists, notEmpty, busy, crossDevice, other }

/// Maps OS error codes and messages (Linux/Android, Windows, iOS/macOS) to
/// a platform-independent [FsProblem].
FsProblem classifyFsError(FileSystemException e) {
  final code = e.osError?.errorCode;
  final text = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
  bool has(String s) => text.contains(s);
  if (has('no space left') || has('disk is full') || has('not enough space') || has('disk full')) {
    return FsProblem.noSpace;
  }
  if (has('permission denied') || has('access is denied') || has('operation not permitted')) {
    return FsProblem.accessDenied;
  }
  if (has('name too long') || has('filename or extension is too long') || has('path too long')) {
    return FsProblem.nameTooLong;
  }
  if (has('read-only file system') || has('write-protected')) return FsProblem.readOnly;
  if (has('cross-device') || has('different disk drive') || has('not same device')) return FsProblem.crossDevice;
  if (has('directory not empty') || has('directory is not empty')) return FsProblem.notEmpty;
  if (has('being used by another process') || has('resource busy') || has('device or resource busy')) {
    return FsProblem.busy;
  }
  if (has('file exists') || has('already exists')) return FsProblem.exists;
  if (has('no such file') || has('cannot find the file') || has('cannot find the path') || has('not found')) {
    return FsProblem.notFound;
  }
  if (has('input/output')) return FsProblem.other;
  // Fall back to well-known error codes when the message is localised:
  // POSIX errno (Linux/Android) and Windows system error codes. Only codes
  // that mean the same thing (or cannot occur for files) on both are used.
  switch (code) {
    case 28 || 112:
      return FsProblem.noSpace;
    case 13 || 1 || 5:
      return FsProblem.accessDenied;
    case 2 || 3:
      return FsProblem.notFound;
    case 36 || 206:
      return FsProblem.nameTooLong;
    case 30:
      return FsProblem.readOnly;
    case 80 || 183:
      return FsProblem.exists;
    case 18:
      return FsProblem.crossDevice;
    case 16 || 32 || 33:
      return FsProblem.busy;
  }
  return FsProblem.other;
}

/// Turns any error thrown by file, archive or worker code into text a user
/// can act on. Never throws.
FriendlyError describeError(Object error, {String action = 'The operation'}) {
  if (error is OperationCancelled) {
    return FriendlyError('Cancelled', '$action was cancelled.', 'Nothing more was changed after the cancel point.');
  }
  if (error is OperationTimedOut) {
    return FriendlyError(
      'Time limit reached',
      '$action was stopped after ${error.timeout.inSeconds > 0 ? '${error.timeout.inSeconds} s' : '${error.timeout.inMilliseconds} ms'}.',
      'The pattern is probably too expensive (for example nested repetition like (a+)+). Simplify it and try again.',
    );
  }
  if (error is PatternTimeoutException) {
    return FriendlyError(
      'Pattern too slow',
      '$error. $action was stopped so nothing freezes.',
      'This usually means catastrophic backtracking (nested repetition like (a+)+ or (.*)*). '
          'Simplify the regular expression, or use plain text mode.',
    );
  }
  if (error is UnsafePathException) {
    return FriendlyError('Unsafe name or path', '"${error.path}": ${error.reason}.');
  }
  if (error is UnsafeArchiveException) {
    final fatal = error.issues.where((i) => i.isFatal).toList();
    return FriendlyError(
      'Archive rejected',
      '${fatal.length} blocking issue(s): ${fatal.take(3).map((i) => '${i.entry}: ${i.message}').join('; ')}',
      'Nothing was extracted. Only use archives from sources you trust.',
    );
  }
  if (error is FormatException) {
    return FriendlyError('Invalid input', error.message);
  }
  if (error is FileSystemException) {
    final path = error.path == null || error.path!.isEmpty ? '' : ' (${error.path})';
    final detail = error.osError?.message.isNotEmpty == true ? error.osError!.message : error.message;
    return switch (classifyFsError(error)) {
      FsProblem.noSpace => FriendlyError(
        'Storage is full',
        'The device has no space left$path.',
        'Free up storage (or choose a smaller selection), then try again. Partially written files were removed.',
      ),
      FsProblem.accessDenied => FriendlyError(
        'Access denied',
        'The system refused access$path.',
        'The folder permission may have been revoked or the file is protected. Re-link or re-import the folder, '
            'or check its permissions.',
      ),
      FsProblem.notFound => FriendlyError(
        'Not found',
        'The file or folder no longer exists$path.',
        'It may have been moved, renamed or deleted outside the app. Refresh and try again.',
      ),
      FsProblem.nameTooLong => FriendlyError(
        'Path too long',
        'The name or full path is longer than the file system allows$path.',
        'Use a shorter name or move the workspace closer to the drive root.',
      ),
      FsProblem.readOnly => FriendlyError(
        'Read-only location',
        'This location cannot be written$path.',
        'Import a copy into app storage, or export results to another location.',
      ),
      FsProblem.exists => FriendlyError('Already exists', 'Something with this name already exists$path.'),
      FsProblem.notEmpty => FriendlyError('Folder not empty', 'The folder still contains files$path.'),
      FsProblem.busy => FriendlyError(
        'File in use',
        'Another program is using this file$path.',
        'Close the other program and try again.',
      ),
      FsProblem.crossDevice => FriendlyError('Different drive', 'The move crosses drives$path.'),
      FsProblem.other => FriendlyError('File system error', '$detail$path'),
    };
  }
  if (error is StateError) return FriendlyError('Error', error.message);
  if (error is ArgumentError) return FriendlyError('Invalid input', '${error.message}');
  return FriendlyError('Error', error.toString());
}
