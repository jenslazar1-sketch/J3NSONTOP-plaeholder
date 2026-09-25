import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/storage/atomic_file.dart';
import '../../../../core/tasks/cancellation.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/utils/hashing.dart';
import '../../../../core/utils/safe_path.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../domain/checksums.dart';
import '../../domain/file_walker.dart';
import '../shared.dart';

const String kHashToolId = 'files.hash';

enum HashMode {
  text('Text'),
  files('Files'),
  verify('Verify list');

  const HashMode(this.label);
  final String label;
}

// ---------------------------------------------------------------------------
// Hash files

class HashFilesState {
  const HashFilesState({
    this.files = const [],
    this.results,
    this.resultAlgorithm,
    this.opId,
    this.currentIndex = 0,
    this.currentFraction = 0,
    this.error,
    this.notice,
  });

  final List<FileItem> files;
  final List<HashOutcome>? results;
  final HashAlgorithm? resultAlgorithm;
  final String? opId;
  final int currentIndex;
  final double currentFraction;
  final String? error;
  final String? notice;

  bool get running => opId != null;

  HashFilesState copyWith({
    List<FileItem>? files,
    List<HashOutcome>? results,
    bool clearResults = false,
    HashAlgorithm? resultAlgorithm,
    String? opId,
    bool clearOp = false,
    int? currentIndex,
    double? currentFraction,
    String? error,
    bool clearError = false,
    String? notice,
    bool clearNotice = false,
  }) => HashFilesState(
    files: files ?? this.files,
    results: clearResults ? null : (results ?? this.results),
    resultAlgorithm: clearResults ? null : (resultAlgorithm ?? this.resultAlgorithm),
    opId: clearOp ? null : (opId ?? this.opId),
    currentIndex: currentIndex ?? this.currentIndex,
    currentFraction: currentFraction ?? this.currentFraction,
    error: clearError ? null : (error ?? this.error),
    notice: clearNotice ? null : (notice ?? this.notice),
  );

  /// Successful digests, for checksum-file generation.
  List<HashOutcome> get digests => [
    for (final r in results ?? const <HashOutcome>[])
      if (r.ok) r,
  ];
}

class HashFilesController extends Notifier<HashFilesState> {
  @override
  HashFilesState build() => const HashFilesState();

  void add(Iterable<FileItem> items) =>
      state = state.copyWith(files: mergeFileItems(state.files, items), clearResults: true, clearNotice: true);

  void remove(FileItem item) =>
      state = state.copyWith(files: state.files.where((f) => f != item).toList(), clearResults: true);

  void clear() => state = const HashFilesState();

  void setNotice(String? notice) =>
      state = notice == null ? state.copyWith(clearNotice: true) : state.copyWith(notice: notice);

  Future<void> hash(HashAlgorithm algorithm) async {
    if (state.running || state.files.isEmpty) return;
    final files = state.files;
    final activity = ref.read(activityProvider.notifier);
    state = state.copyWith(
      clearResults: true,
      clearError: true,
      clearNotice: true,
      currentIndex: 0,
      currentFraction: 0,
    );
    try {
      final results = await activity.run<List<HashOutcome>>(
        toolId: kHashToolId,
        title: 'Hash ${Fmt.count(files.length, 'file')} (${algorithm.label})',
        cancellable: true,
        workspaceId: ref.read(activeWorkspaceProvider)?.id,
        body: (op) async {
          state = state.copyWith(opId: op.id);
          final throttle = ProgressThrottle(op);
          var lastIndex = -1;
          var lastFraction = 0.0;
          return hashFiles(
            [for (final f in files) HashTarget(path: f.path, label: f.label, size: f.size)],
            algorithm,
            token: op.token,
            onProgress: (i, ff, overall) {
              throttle.report(overall, 'File ${i + 1}/${files.length}: ${files[i].label}');
              if (i != lastIndex || (ff - lastFraction).abs() >= 0.02 || ff == 1) {
                lastIndex = i;
                lastFraction = ff;
                if (ref.mounted) state = state.copyWith(currentIndex: i, currentFraction: ff);
              }
            },
          );
        },
        summary: (r) {
          final failed = r.where((x) => !x.ok).length;
          return failed == 0 ? '${r.length} digests' : '${r.length - failed} digests, $failed unreadable';
        },
        counts: (r) => {'files': r.length, 'bytes': files.fold<int>(0, (s, f) => s + f.size)},
      );
      if (!ref.mounted) return;
      state = state.copyWith(results: results, resultAlgorithm: algorithm, clearOp: true);
    } on OperationCancelled {
      if (ref.mounted) state = state.copyWith(clearOp: true, notice: 'Hashing cancelled. No digests were kept.');
    } catch (e) {
      if (ref.mounted) state = state.copyWith(clearOp: true, error: describeError(e));
    }
  }

  /// Folder the relative paths of a generated checksum file start from.
  String? get checksumBase {
    final d = state.digests;
    if (d.isEmpty) return null;
    return commonBaseFolder([for (final r in d) r.target.path]);
  }

  /// Checksum file text for the current results.
  String buildChecksums({bool bsdStyle = false}) {
    final base = checksumBase;
    final algo = state.resultAlgorithm ?? HashAlgorithm.sha256;
    if (base == null) return '';
    return buildChecksumFile(
      [for (final r in state.digests) (relativeSlash(r.target.path, base), r.digest!)],
      algorithm: algo,
      bsdStyle: bsdStyle,
    );
  }

  /// Writes the checksum file into the folder its paths are relative to
  /// (never overwriting: an existing name gets a ` (2)` suffix). Only
  /// allowed when that folder is inside the active workspace.
  Future<String> saveChecksumsNextToFiles() async {
    final ws = ref.read(activeWorkspaceProvider);
    final base = checksumBase;
    if (ws == null || base == null) throw StateError('Nothing to save');
    if (!SafePath.isWithin(ws.rootPath, base) ||
        state.digests.any((r) => !SafePath.isWithin(ws.rootPath, r.target.path))) {
      throw const FileSystemException('The files are not all inside the active workspace; use Save / export instead');
    }
    final algo = state.resultAlgorithm ?? HashAlgorithm.sha256;
    final dest = SafePath.uniquePath(p.join(base, defaultChecksumFileName(algo)));
    await atomicWriteBytes(dest, Uint8List.fromList(utf8.encode(buildChecksums())));
    final rel = workspaceLabel(ws, dest);
    ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Saved $rel');
    return rel;
  }
}

final hashFilesProvider = NotifierProvider<HashFilesController, HashFilesState>(HashFilesController.new);

// ---------------------------------------------------------------------------
// Verify a checksum list

enum VerifySource {
  file('Checksum file'),
  paste('Pasted lines');

  const VerifySource(this.label);
  final String label;
}

class VerifyState {
  const VerifyState({this.checksumFile, this.baseDir, this.report, this.opId, this.error, this.notice});

  final FileItem? checksumFile;

  /// Folder the listed paths are resolved against (absolute).
  final String? baseDir;
  final VerifyReport? report;
  final String? opId;
  final String? error;
  final String? notice;

  bool get running => opId != null;

  VerifyState copyWith({
    FileItem? checksumFile,
    String? baseDir,
    VerifyReport? report,
    bool clearReport = false,
    String? opId,
    bool clearOp = false,
    String? error,
    bool clearError = false,
    String? notice,
    bool clearNotice = false,
  }) => VerifyState(
    checksumFile: checksumFile ?? this.checksumFile,
    baseDir: baseDir ?? this.baseDir,
    report: clearReport ? null : (report ?? this.report),
    opId: clearOp ? null : (opId ?? this.opId),
    error: clearError ? null : (error ?? this.error),
    notice: clearNotice ? null : (notice ?? this.notice),
  );
}

class VerifyController extends Notifier<VerifyState> {
  @override
  VerifyState build() => const VerifyState();

  /// Picks the checksum file; its folder becomes the base folder.
  void setChecksumFile(FileItem f) => state = VerifyState(checksumFile: f, baseDir: p.dirname(f.path));

  void setBaseDir(String dir) => state = state.copyWith(baseDir: dir, clearReport: true, clearError: true);

  Future<void> verify({
    required VerifySource source,
    required String pastedText,
    required HashAlgorithm? forcedAlgorithm,
  }) async {
    if (state.running) return;
    final base = state.baseDir ?? ref.read(activeWorkspaceProvider)?.rootPath;
    final file = state.checksumFile;
    if (source == VerifySource.file && file == null) {
      state = state.copyWith(error: 'Choose a checksum file first.');
      return;
    }
    if (base == null) {
      state = state.copyWith(error: 'Choose the folder the listed paths are relative to.');
      return;
    }
    state = state.copyWith(clearReport: true, clearError: true, clearNotice: true);
    final activity = ref.read(activityProvider.notifier);
    try {
      final report = await activity.run<VerifyReport>(
        toolId: kHashToolId,
        title: 'Verify ${source == VerifySource.file ? file!.label : 'pasted checksums'}',
        cancellable: true,
        workspaceId: ref.read(activeWorkspaceProvider)?.id,
        body: (op) async {
          state = state.copyWith(opId: op.id);
          final text = source == VerifySource.file ? await readChecksumText(file!.path) : pastedText;
          final parsed = parseChecksums(text);
          if (parsed.entries.isEmpty) {
            throw FormatException(
              parsed.issues.isEmpty ? 'No checksum lines found' : 'No readable checksum lines (${parsed.issues.first})',
            );
          }
          final throttle = ProgressThrottle(op);
          final r = await verifyChecksums(
            parsed,
            base,
            forceAlgorithm: forcedAlgorithm,
            fileNameAlgorithm: source == VerifySource.file ? algorithmFromFileName(file!.label) : null,
            token: op.token,
            onProgress: (i, _, overall) => throttle.report(overall, 'Entry ${i + 1}/${parsed.entries.length}'),
          );
          final bad = r.count(VerifyStatus.failed) + r.count(VerifyStatus.missing) + r.count(VerifyStatus.invalid);
          final summary =
              '${r.count(VerifyStatus.ok)} OK, ${r.count(VerifyStatus.failed)} FAILED, '
              '${r.count(VerifyStatus.missing)} MISSING, ${r.count(VerifyStatus.invalid)} INVALID';
          final counts = {
            'ok': r.count(VerifyStatus.ok),
            'failed': r.count(VerifyStatus.failed),
            'missing': r.count(VerifyStatus.missing),
          };
          if (bad > 0 || r.parseIssues.isNotEmpty) {
            op.warn(summary, counts: counts);
          } else {
            op.succeed(summary, counts: counts);
          }
          return r;
        },
      );
      if (ref.mounted) state = state.copyWith(report: report, clearOp: true);
    } on OperationCancelled {
      if (ref.mounted) state = state.copyWith(clearOp: true, notice: 'Verification cancelled.');
    } catch (e) {
      if (ref.mounted) state = state.copyWith(clearOp: true, error: describeError(e));
    }
  }
}

final verifyProvider = NotifierProvider<VerifyController, VerifyState>(VerifyController.new);

/// Text-mode verdict for the expected digest field.
enum DigestVerdict { none, match, mismatch }

DigestVerdict compareDigest(String actual, String expected) {
  if (expected.trim().isEmpty || actual.isEmpty) return DigestVerdict.none;
  return Hashing.digestsEqual(actual, expected) ? DigestVerdict.match : DigestVerdict.mismatch;
}

/// When the pasted digest's length fits another algorithm, returns it.
HashAlgorithm? suggestedAlgorithmFor(String expected, HashAlgorithm current) {
  var t = expected.trim().toLowerCase();
  final colon = t.indexOf(':');
  if (colon >= 0 && colon < 8) t = t.substring(colon + 1);
  t = t.replaceAll(RegExp(r'\s'), '');
  if (!RegExp(r'^[0-9a-f]+$').hasMatch(t)) return null;
  final a = algorithmForHexLength(t.length);
  return a == null || a == current ? null : a;
}
