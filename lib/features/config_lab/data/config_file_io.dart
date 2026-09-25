/// File IO for the Config Lab editors: reading text files (encoding
/// detection, binary refusal, size limit) and writing them back.
library;

import 'dart:io';
import 'dart:isolate';

import '../../../core/utils/format.dart';
import '../../../core/utils/text_codec.dart';
import '../domain/json_tools.dart' show kSyncParseLimit;

/// Largest file the text editors open (bigger files make the editor itself
/// unusable; use the File Tools for those).
const int kMaxEditorBytes = 16 * 1024 * 1024;

class LoadedText {
  const LoadedText({required this.text, required this.encoding, required this.malformed, required this.bytes});
  final String text;
  final TextEncodingKind encoding;

  /// Invalid UTF-8 decoded as Latin-1; saving writes different bytes.
  final bool malformed;
  final int bytes;
}

class ConfigFileException implements Exception {
  const ConfigFileException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reads [path] as text. Decoding of large files runs in an isolate.
Future<LoadedText> loadTextFile(String path) async {
  final file = File(path);
  final length = await file.length();
  if (length > kMaxEditorBytes) {
    throw ConfigFileException(
      'The file is ${Fmt.bytes(length)}; the editor opens files up to ${Fmt.bytes(kMaxEditorBytes)}.',
    );
  }
  final bytes = await file.readAsBytes();
  if (TextCodec.looksBinary(bytes)) {
    throw const ConfigFileException('This looks like a binary file, not text. Binary formats are not supported.');
  }
  final decoded = bytes.length > kSyncParseLimit
      ? await Isolate.run(() => TextCodec.decode(bytes))
      : TextCodec.decode(bytes);
  return LoadedText(
    text: decoded.text,
    encoding: decoded.encoding,
    malformed: decoded.hadMalformedBytes,
    bytes: bytes.length,
  );
}
