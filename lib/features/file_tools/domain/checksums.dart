import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/tasks/cancellation.dart';
import '../../../core/utils/hashing.dart';
import '../../../core/utils/safe_path.dart';
import '../../../core/utils/text_codec.dart';

/// How a checksum line was written.
enum ChecksumLineFormat {
  /// GNU coreutils text mode: `<hex>  <path>`.
  gnuText,

  /// GNU coreutils binary mode: `<hex> *<path>`.
  gnuBinary,

  /// BSD / `--tag` style: `SHA256 (<path>) = <hex>`.
  bsd,
}

/// Hex digest lengths of the supported algorithms.
int hexLengthOf(HashAlgorithm a) => switch (a) {
  HashAlgorithm.md5 => 32,
  HashAlgorithm.sha1 => 40,
  HashAlgorithm.sha256 => 64,
  HashAlgorithm.sha512 => 128,
};

/// Guesses the algorithm from a hex digest length (32/40/64/128).
HashAlgorithm? algorithmForHexLength(int length) {
  for (final a in HashAlgorithm.values) {
    if (hexLengthOf(a) == length) return a;
  }
  return null;
}

/// Guesses the algorithm from a checksum file name such as `SHA256SUMS`,
/// `MD5SUMS`, `release.sha512` or `sha1sum.txt`.
HashAlgorithm? algorithmFromFileName(String name) {
  final n = p.basename(name).toLowerCase().replaceAll('-', '');
  if (n.contains('sha512')) return HashAlgorithm.sha512;
  if (n.contains('sha256')) return HashAlgorithm.sha256;
  if (n.contains('sha1')) return HashAlgorithm.sha1;
  if (n.contains('md5')) return HashAlgorithm.md5;
  return null;
}

/// Conventional checksum file name for [a] (`SHA256SUMS`...).
String defaultChecksumFileName(HashAlgorithm a) => switch (a) {
  HashAlgorithm.sha256 => 'SHA256SUMS',
  HashAlgorithm.sha512 => 'SHA512SUMS',
  HashAlgorithm.sha1 => 'SHA1SUMS',
  HashAlgorithm.md5 => 'MD5SUMS',
};

/// BSD tag written for [a] (`SHA256`, `MD5`...).
String bsdTagOf(HashAlgorithm a) => switch (a) {
  HashAlgorithm.sha256 => 'SHA256',
  HashAlgorithm.sha512 => 'SHA512',
  HashAlgorithm.sha1 => 'SHA1',
  HashAlgorithm.md5 => 'MD5',
};

HashAlgorithm? _algorithmFromTag(String tag) {
  final t = tag.toUpperCase().replaceAll('-', '');
  return switch (t) {
    'MD5' => HashAlgorithm.md5,
    'SHA1' => HashAlgorithm.sha1,
    'SHA256' || 'SHA2256' => HashAlgorithm.sha256,
    'SHA512' || 'SHA2512' => HashAlgorithm.sha512,
    _ => null,
  };
}

const _knownOtherTags = {'SHA224', 'SHA384', 'SHA2224', 'SHA2384', 'BLAKE2B', 'BLAKE2S', 'SM3', 'CRC', 'BLAKE3'};

/// One parsed line of a checksum file.
class ChecksumEntry {
  const ChecksumEntry({
    required this.lineNumber,
    required this.digest,
    required this.path,
    required this.format,
    this.algorithm,
  });

  /// 1-based line number in the checksum file.
  final int lineNumber;

  /// Lower-case hex digest.
  final String digest;

  /// File path exactly as listed (after GNU unescaping).
  final String path;
  final ChecksumLineFormat format;

  /// Algorithm stated by the line (BSD tag) or implied by the digest length.
  final HashAlgorithm? algorithm;
}

/// A line that could not be understood.
class ChecksumParseIssue {
  const ChecksumParseIssue(this.lineNumber, this.line, this.message);
  final int lineNumber;
  final String line;
  final String message;

  @override
  String toString() => 'line $lineNumber: $message';
}

class ChecksumFile {
  const ChecksumFile(this.entries, this.issues);
  final List<ChecksumEntry> entries;
  final List<ChecksumParseIssue> issues;
}

final RegExp _hex = RegExp(r'^[0-9a-fA-F]+$');
final RegExp _bsd = RegExp(r'^([A-Za-z][A-Za-z0-9-]*) ?\((.*)\) ?= ?([0-9a-fA-F]+)$');

/// Undoes GNU coreutils filename escaping (`\\`, `\n`, `\r`).
String _unescapeGnu(String s) {
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == r'\' && i + 1 < s.length) {
      final n = s[i + 1];
      if (n == r'\') {
        out.write(r'\');
        i++;
        continue;
      }
      if (n == 'n') {
        out.write('\n');
        i++;
        continue;
      }
      if (n == 'r') {
        out.write('\r');
        i++;
        continue;
      }
    }
    out.write(c);
  }
  return out.toString();
}

/// Escapes a filename the way GNU coreutils does. Returns the escaped name
/// and whether the line needs the leading `\` marker.
(String, bool) _escapeGnu(String name) {
  if (!name.contains(r'\') && !name.contains('\n') && !name.contains('\r')) return (name, false);
  return (name.replaceAll(r'\', r'\\').replaceAll('\n', r'\n').replaceAll('\r', r'\r'), true);
}

/// Parses checksum text in GNU coreutils format (`<hex>  <path>` and
/// `<hex> *<path>`, including escaped names) and BSD format
/// (`SHA256 (<path>) = <hex>`). Blank lines and `#` comments are ignored;
/// CRLF line endings and a BOM are accepted.
ChecksumFile parseChecksums(String text) {
  final entries = <ChecksumEntry>[];
  final issues = <ChecksumParseIssue>[];
  var body = text;
  if (body.startsWith('\uFEFF')) body = body.substring(1);
  final lines = body.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final lineNo = i + 1;
    var line = lines[i];
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    var escaped = false;
    if (line.startsWith(r'\')) {
      escaped = true;
      line = line.substring(1);
    }

    final bsd = _bsd.firstMatch(line);
    if (bsd != null) {
      final tag = bsd.group(1)!;
      final algo = _algorithmFromTag(tag);
      final isKnownOther = _knownOtherTags.contains(tag.toUpperCase().replaceAll('-', ''));
      if (algo != null || isKnownOther) {
        final hex = bsd.group(3)!;
        final path = escaped ? _unescapeGnu(bsd.group(2)!) : bsd.group(2)!;
        if (algo == null) {
          issues.add(ChecksumParseIssue(lineNo, line, 'unsupported algorithm $tag'));
        } else if (hex.length != hexLengthOf(algo)) {
          issues.add(ChecksumParseIssue(lineNo, line, '$tag digest must have ${hexLengthOf(algo)} hex characters'));
        } else if (path.isEmpty) {
          issues.add(ChecksumParseIssue(lineNo, line, 'missing file name'));
        } else {
          entries.add(
            ChecksumEntry(
              lineNumber: lineNo,
              digest: hex.toLowerCase(),
              path: path,
              format: ChecksumLineFormat.bsd,
              algorithm: algo,
            ),
          );
        }
        continue;
      }
    }

    final space = line.indexOf(' ');
    if (space <= 0) {
      issues.add(ChecksumParseIssue(lineNo, line, 'expected "<hex digest>  <file name>"'));
      continue;
    }
    final hex = line.substring(0, space);
    if (!_hex.hasMatch(hex)) {
      issues.add(ChecksumParseIssue(lineNo, line, 'digest is not hexadecimal'));
      continue;
    }
    final algo = algorithmForHexLength(hex.length);
    if (algo == null) {
      issues.add(ChecksumParseIssue(lineNo, line, 'digest length ${hex.length} matches no supported algorithm'));
      continue;
    }
    final rest = line.substring(space + 1);
    ChecksumLineFormat format;
    String rawPath;
    if (rest.startsWith(' ')) {
      format = ChecksumLineFormat.gnuText;
      rawPath = rest.substring(1);
    } else if (rest.startsWith('*')) {
      format = ChecksumLineFormat.gnuBinary;
      rawPath = rest.substring(1);
    } else {
      // Lenient: a single space separator (some tools write this).
      format = ChecksumLineFormat.gnuText;
      rawPath = rest;
    }
    final path = escaped ? _unescapeGnu(rawPath) : rawPath;
    if (path.isEmpty) {
      issues.add(ChecksumParseIssue(lineNo, line, 'missing file name'));
      continue;
    }
    entries.add(
      ChecksumEntry(lineNumber: lineNo, digest: hex.toLowerCase(), path: path, format: format, algorithm: algo),
    );
  }
  return ChecksumFile(entries, issues);
}

/// Builds a checksum file. Lines are sorted by relative path (code unit
/// order, like `LC_ALL=C sort`) so the output is stable across runs and
/// platforms. Paths use forward slashes.
String buildChecksumFile(
  Iterable<(String relativePath, String digest)> entries, {
  HashAlgorithm algorithm = HashAlgorithm.sha256,
  bool bsdStyle = false,
}) {
  final sorted = [for (final e in entries) (e.$1.replaceAll('\\', '/'), e.$2.toLowerCase())]
    ..sort((a, b) => a.$1.compareTo(b.$1));
  final out = StringBuffer();
  for (final (path, digest) in sorted) {
    final (name, needsMarker) = _escapeGnu(path);
    final marker = needsMarker ? r'\' : '';
    if (bsdStyle) {
      out.write('$marker${bsdTagOf(algorithm)} ($name) = $digest\n');
    } else {
      out.write('$marker$digest  $name\n');
    }
  }
  return out.toString();
}

/// Longest common folder of [paths] (absolute). Returns the folder of the
/// single path when only one is given.
String commonBaseFolder(List<String> paths) {
  if (paths.isEmpty) throw ArgumentError('no paths');
  var base = p.split(p.dirname(p.normalize(p.absolute(paths.first))));
  for (final path in paths.skip(1)) {
    final parts = p.split(p.dirname(p.normalize(p.absolute(path))));
    var n = 0;
    while (n < base.length && n < parts.length && base[n] == parts[n]) {
      n++;
    }
    base = base.sublist(0, n);
  }
  return base.isEmpty ? p.rootPrefix(p.absolute(paths.first)) : p.joinAll(base);
}

// ---------------------------------------------------------------------------
// Hashing several files

/// A file queued for hashing.
class HashTarget {
  const HashTarget({required this.path, required this.label, required this.size});
  final String path;
  final String label;
  final int size;
}

class HashOutcome {
  const HashOutcome(this.target, {this.digest, this.error});
  final HashTarget target;
  final String? digest;
  final String? error;
  bool get ok => digest != null;
}

/// Progress of a multi-file job: [fileIndex] is 0-based, [fileFraction] is
/// the progress inside that file, [overall] is by bytes across all files.
typedef MultiFileProgress = void Function(int fileIndex, double fileFraction, double overall);

/// Streams every target through [algorithm]. Unreadable files are recorded
/// as errors (the job continues); cancellation throws [OperationCancelled].
Future<List<HashOutcome>> hashFiles(
  List<HashTarget> targets,
  HashAlgorithm algorithm, {
  CancellationToken? token,
  MultiFileProgress? onProgress,
}) async {
  final total = targets.fold<int>(0, (s, t) => s + t.size);
  var done = 0;
  final out = <HashOutcome>[];
  for (var i = 0; i < targets.length; i++) {
    token?.throwIfCancelled();
    final t = targets[i];
    onProgress?.call(i, 0, total == 0 ? i / targets.length : done / total);
    try {
      final digest = await Hashing.file(
        t.path,
        algo: algorithm,
        token: token,
        onProgress: (f, _) {
          final ff = f ?? 0;
          onProgress?.call(i, ff, total == 0 ? (i + ff) / targets.length : (done + t.size * ff) / total);
        },
      );
      out.add(HashOutcome(t, digest: digest));
    } on OperationCancelled {
      rethrow;
    } on FileSystemException catch (e) {
      out.add(HashOutcome(t, error: e.osError?.message ?? e.message));
    }
    done += t.size;
    onProgress?.call(i, 1, total == 0 ? (i + 1) / targets.length : done / total);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Verification

enum VerifyStatus {
  ok('OK'),
  failed('FAILED'),
  missing('MISSING'),
  invalid('INVALID');

  const VerifyStatus(this.label);
  final String label;
}

class VerifyEntryResult {
  const VerifyEntryResult(this.entry, this.status, {this.algorithm, this.actual, this.detail});
  final ChecksumEntry entry;
  final VerifyStatus status;
  final HashAlgorithm? algorithm;
  final String? actual;
  final String? detail;
}

class VerifyReport {
  const VerifyReport({required this.baseDir, required this.results, required this.parseIssues});

  final String baseDir;
  final List<VerifyEntryResult> results;
  final List<ChecksumParseIssue> parseIssues;

  int count(VerifyStatus s) => results.where((r) => r.status == s).length;
  bool get allOk => results.isNotEmpty && results.every((r) => r.status == VerifyStatus.ok) && parseIssues.isEmpty;

  /// Plain-text report in `sha256sum -c` style plus totals.
  String toText() {
    final b = StringBuffer();
    for (final r in results) {
      b.write('${r.entry.path}: ${r.status.label}');
      if (r.detail != null) b.write(' (${r.detail})');
      b.write('\n');
    }
    for (final i in parseIssues) {
      b.write('line ${i.lineNumber}: IGNORED (${i.message})\n');
    }
    b.write(
      '# ${count(VerifyStatus.ok)} OK, ${count(VerifyStatus.failed)} FAILED, '
      '${count(VerifyStatus.missing)} MISSING, ${count(VerifyStatus.invalid)} INVALID, '
      '${parseIssues.length} unreadable lines\n',
    );
    return b.toString();
  }
}

/// Verifies [file] against files below [baseDir] (normally the checksum
/// file's own folder). Every listed path is untrusted: absolute paths,
/// `..` traversal and paths through symbolic links are reported as
/// INVALID and never read. [forceAlgorithm] overrides per-line detection.
Future<VerifyReport> verifyChecksums(
  ChecksumFile file,
  String baseDir, {
  HashAlgorithm? forceAlgorithm,
  HashAlgorithm? fileNameAlgorithm,
  CancellationToken? token,
  MultiFileProgress? onProgress,
}) async {
  final planned = <(ChecksumEntry, String?, HashAlgorithm?, VerifyEntryResult?)>[];
  var total = 0;
  for (final e in file.entries) {
    final algo = forceAlgorithm ?? (e.format == ChecksumLineFormat.bsd ? e.algorithm : null) ?? fileNameAlgorithm;
    final effective = algo ?? e.algorithm;
    if (effective == null || hexLengthOf(effective) != e.digest.length) {
      planned.add((
        e,
        null,
        effective,
        VerifyEntryResult(
          e,
          VerifyStatus.invalid,
          algorithm: effective,
          detail: effective == null
              ? 'unknown algorithm'
              : 'digest has ${e.digest.length} hex characters, ${effective.label} needs ${hexLengthOf(effective)}',
        ),
      ));
      continue;
    }
    String target;
    try {
      target = SafePath.resolveInside(baseDir, e.path);
    } on UnsafePathException catch (err) {
      planned.add((
        e,
        null,
        effective,
        VerifyEntryResult(e, VerifyStatus.invalid, detail: 'unsafe path: ${err.reason}'),
      ));
      continue;
    }
    final type = FileSystemEntity.typeSync(target, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      planned.add((e, null, effective, VerifyEntryResult(e, VerifyStatus.missing, algorithm: effective)));
      continue;
    }
    if (type != FileSystemEntityType.file) {
      planned.add((
        e,
        null,
        effective,
        VerifyEntryResult(e, VerifyStatus.invalid, algorithm: effective, detail: 'not a regular file'),
      ));
      continue;
    }
    try {
      total += File(target).lengthSync();
    } on FileSystemException {
      // Reported when hashing fails below.
    }
    planned.add((e, target, effective, null));
  }

  final results = <VerifyEntryResult>[];
  var done = 0;
  for (var i = 0; i < planned.length; i++) {
    token?.throwIfCancelled();
    final (entry, target, algo, preset) = planned[i];
    if (preset != null) {
      results.add(preset);
      continue;
    }
    int size;
    try {
      size = File(target!).lengthSync();
    } on FileSystemException catch (e) {
      results.add(
        VerifyEntryResult(entry, VerifyStatus.invalid, detail: 'cannot read: ${e.osError?.message ?? e.message}'),
      );
      continue;
    }
    try {
      final actual = await Hashing.file(
        target,
        algo: algo!,
        token: token,
        onProgress: (f, _) =>
            onProgress?.call(i, f ?? 0, total == 0 ? i / planned.length : (done + size * (f ?? 0)) / total),
      );
      results.add(
        VerifyEntryResult(
          entry,
          Hashing.digestsEqual(actual, entry.digest) ? VerifyStatus.ok : VerifyStatus.failed,
          algorithm: algo,
          actual: actual,
        ),
      );
    } on OperationCancelled {
      rethrow;
    } on FileSystemException catch (e) {
      results.add(
        VerifyEntryResult(entry, VerifyStatus.invalid, detail: 'cannot read: ${e.osError?.message ?? e.message}'),
      );
    }
    done += size;
    onProgress?.call(i, 1, total == 0 ? (i + 1) / planned.length : done / total);
  }
  return VerifyReport(baseDir: baseDir, results: results, parseIssues: file.issues);
}

/// Reads a checksum file (capped at [maxBytes]) and decodes it.
Future<String> readChecksumText(String path, {int maxBytes = 16 * 1024 * 1024}) async {
  final f = File(path);
  final len = await f.length();
  if (len > maxBytes) {
    throw FormatException(
      'Checksum file is ${len ~/ (1024 * 1024)} MiB; the limit is ${maxBytes ~/ (1024 * 1024)} MiB',
    );
  }
  final bytes = await f.readAsBytes();
  if (TextCodec.looksBinary(bytes)) throw const FormatException('This is a binary file, not a checksum list');
  return TextCodec.decode(bytes).text;
}
