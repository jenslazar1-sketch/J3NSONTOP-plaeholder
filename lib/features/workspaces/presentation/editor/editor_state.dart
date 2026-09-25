import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/theme/j3_colors.dart';
import '../../../../core/utils/safe_path.dart';
import '../../../../core/utils/text_codec.dart';
import '../../../../core/workspace/workspace.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../domain/line_endings.dart';

/// Editable up to this size; larger files open in a read-only line view.
const int kEditableLimit = 2 * 1024 * 1024;

/// Hard limit for the read-only line view (the hex viewer handles more).
const int kViewLimit = 32 * 1024 * 1024;

/// An open document.
class EditorDoc {
  const EditorDoc({
    required this.path,
    required this.displayName,
    required this.encoding,
    required this.encodingLabel,
    required this.endings,
    required this.malformed,
    required this.sizeOnDisk,
    required this.modifiedOnDisk,
    required this.originalText,
    this.readOnlyReason,
    this.lines,
    this.binary = false,
  });

  final String path;
  final String displayName;
  final TextEncodingKind encoding;
  final String encodingLabel;
  final LineEndingStats endings;

  /// Bytes were invalid for the detected encoding (decoded as Latin-1 or
  /// odd-length UTF-16); saving re-encodes and may change bytes.
  final bool malformed;
  final int sizeOnDisk;
  final DateTime modifiedOnDisk;

  /// Content with line endings normalised to LF (what the editor shows).
  final String originalText;

  /// Non-null when the document cannot be edited (too large, binary).
  final String? readOnlyReason;

  /// Lines for the read-only view of large files.
  final List<String>? lines;
  final bool binary;

  bool get readOnly => readOnlyReason != null;

  EditorDoc savedAs({required String text, required int size, required DateTime modified}) => EditorDoc(
    path: path,
    displayName: displayName,
    encoding: encoding,
    encodingLabel: encodingLabel,
    endings: endings,
    malformed: malformed,
    sizeOnDisk: size,
    modifiedOnDisk: modified,
    originalText: text,
    readOnlyReason: readOnlyReason,
    lines: lines,
    binary: binary,
  );
}

class EditorState {
  const EditorState({
    this.doc,
    this.loading = false,
    this.error,
    this.saveEnding = LineEnding.lf,
    this.findOpen = false,
    this.caseSensitive = false,
    this.matches = const [],
    this.current = -1,
    this.pendingLine,
    this.binaryPath,
  });

  final EditorDoc? doc;
  final bool loading;
  final Object? error;

  /// Line ending used when saving (defaults to the detected one).
  final LineEnding saveEnding;
  final bool findOpen;
  final bool caseSensitive;

  /// Match start offsets (editable text) or line indices (read-only view).
  final List<int> matches;
  final int current;

  /// 1-based line to reveal once the document is shown.
  final int? pendingLine;

  /// Set when the chosen file looks binary and the user must decide.
  final String? binaryPath;

  EditorState copyWith({
    EditorDoc? doc,
    bool clearDoc = false,
    bool? loading,
    Object? error,
    bool clearError = false,
    LineEnding? saveEnding,
    bool? findOpen,
    bool? caseSensitive,
    List<int>? matches,
    int? current,
    int? pendingLine,
    bool clearPendingLine = false,
    String? binaryPath,
    bool clearBinaryPath = false,
  }) => EditorState(
    doc: clearDoc ? null : (doc ?? this.doc),
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    saveEnding: saveEnding ?? this.saveEnding,
    findOpen: findOpen ?? this.findOpen,
    caseSensitive: caseSensitive ?? this.caseSensitive,
    matches: matches ?? this.matches,
    current: current ?? this.current,
    pendingLine: clearPendingLine ? null : (pendingLine ?? this.pendingLine),
    binaryPath: clearBinaryPath ? null : (binaryPath ?? this.binaryPath),
  );
}

/// Text controller that paints the current find match.
class HighlightController extends TextEditingController {
  TextRange? _highlight;

  TextRange? get highlight => _highlight;

  set highlight(TextRange? r) {
    _highlight = r;
    notifyListeners();
  }

  @override
  set value(TextEditingValue newValue) {
    if (newValue.text != value.text) _highlight = null;
    super.value = newValue;
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final h = _highlight;
    final composing = withComposing && value.isComposingRangeValid && !value.composing.isCollapsed;
    if (h == null || composing || h.start < 0 || h.end > text.length || h.start >= h.end) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    return TextSpan(
      style: style,
      children: [
        TextSpan(text: text.substring(0, h.start)),
        TextSpan(
          text: text.substring(h.start, h.end),
          style: const TextStyle(
            backgroundColor: J3Colors.selection,
            color: J3Colors.text,
            fontWeight: FontWeight.w700,
            decoration: TextDecoration.underline,
            decorationColor: J3Colors.neonText,
          ),
        ),
        TextSpan(text: text.substring(h.end)),
      ],
    );
  }
}

/// The editor's text (session lifetime, survives navigation).
final editorTextProvider = Provider<HighlightController>((ref) {
  final c = HighlightController();
  ref.onDispose(c.dispose);
  return c;
});

/// Finds all occurrences of [query] (plain text) in [text].
List<int> findAllOffsets(String text, String query, {bool caseSensitive = false, int limit = 10000}) {
  if (query.isEmpty) return const [];
  final hay = caseSensitive ? text : text.toLowerCase();
  final needle = caseSensitive ? query : query.toLowerCase();
  // toLowerCase can change lengths for a few scripts; fall back to exact
  // matching then so offsets stay valid.
  final h = hay.length == text.length ? hay : text;
  final n = hay.length == text.length ? needle : query;
  final out = <int>[];
  var i = h.indexOf(n);
  while (i >= 0 && out.length < limit) {
    out.add(i);
    i = h.indexOf(n, i + (n.isEmpty ? 1 : n.length));
  }
  return out;
}

/// Line indices containing [query] (read-only large view).
List<int> findLines(List<String> lines, String query, {bool caseSensitive = false, int limit = 10000}) {
  if (query.isEmpty) return const [];
  final needle = caseSensitive ? query : query.toLowerCase();
  final out = <int>[];
  for (var i = 0; i < lines.length && out.length < limit; i++) {
    final l = caseSensitive ? lines[i] : lines[i].toLowerCase();
    if (l.contains(needle)) out.add(i);
  }
  return out;
}

class _Decoded {
  _Decoded(this.text, this.encoding, this.label, this.malformed, this.endings);
  final String text;
  final TextEncodingKind encoding;
  final String label;
  final bool malformed;
  final LineEndingStats endings;
}

_Decoded _decode(Uint8List bytes) {
  final d = TextCodec.decode(bytes);
  final stats = LineEndingStats.of(d.text);
  return _Decoded(LineEndings.normalize(d.text), d.encoding, d.encodingLabel, d.hadMalformedBytes, stats);
}

/// Builds the worker closure outside any instance context so only [bytes]
/// is sent to the isolate.
_Decoded Function() _decodeTask(Uint8List bytes) =>
    () => _decode(bytes);

class EditorController extends Notifier<EditorState> {
  @override
  EditorState build() => const EditorState();

  HighlightController get _text => ref.read(editorTextProvider);

  /// The workspace that contains [path] (any record), or null for files
  /// imported from the device (copies in app cache).
  Workspace? workspaceOf(String path) {
    for (final w in ref.read(workspacesProvider).workspaces) {
      if (SafePath.isWithin(w.rootPath, path)) return w;
    }
    return null;
  }

  String displayNameOf(String path) {
    final w = workspaceOf(path);
    return w == null ? p.basename(path) : '${w.name}/${p.relative(path, from: w.rootPath).replaceAll(r'\', '/')}';
  }

  bool get isDirty {
    final d = state.doc;
    if (d == null || d.readOnly) return false;
    return _text.text != d.originalText;
  }

  /// Loads [path]. Binary-looking files need [forceText] to open (read-only).
  Future<void> open(String path, {int? line, bool forceText = false}) async {
    state = state.copyWith(loading: true, clearError: true, clearBinaryPath: true, findOpen: state.findOpen);
    try {
      final f = File(path);
      final stat = await f.stat();
      if (stat.type != FileSystemEntityType.file) throw FileSystemException('Not a file (or no longer exists)', path);
      if (stat.size > kViewLimit) {
        throw FileSystemException(
          'The file is ${stat.size ~/ (1024 * 1024)} MiB; the text view handles up to ${kViewLimit ~/ (1024 * 1024)} MiB. '
          'Open it in the Hex Viewer instead',
          path,
        );
      }
      final bytes = await f.readAsBytes();
      final head = bytes.length > 8192 ? Uint8List.sublistView(bytes, 0, 8192) : bytes;
      if (!forceText && TextCodec.looksBinary(head)) {
        state = state.copyWith(loading: false, binaryPath: path);
        return;
      }
      final decoded = bytes.length > 256 * 1024 ? await Isolate.run(_decodeTask(bytes)) : _decode(bytes);
      final large = bytes.length > kEditableLimit;
      final binary = forceText && TextCodec.looksBinary(head);
      final doc = EditorDoc(
        path: path,
        displayName: displayNameOf(path),
        encoding: decoded.encoding,
        encodingLabel: decoded.label,
        endings: decoded.endings,
        malformed: decoded.malformed,
        sizeOnDisk: stat.size,
        modifiedOnDisk: stat.modified,
        originalText: large ? '' : decoded.text,
        readOnlyReason: binary
            ? 'Binary file shown as text (read-only).'
            : large
            ? 'Larger than ${kEditableLimit ~/ (1024 * 1024)} MiB: shown read-only so the app stays responsive.'
            : null,
        lines: large || binary ? decoded.text.split('\n') : null,
        binary: binary,
      );
      _text.text = large || binary ? '' : decoded.text;
      state = EditorState(
        doc: doc,
        saveEnding: decoded.endings.dominant,
        findOpen: state.findOpen,
        caseSensitive: state.caseSensitive,
        pendingLine: line,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e);
    }
  }

  void dismissBinary() => state = state.copyWith(clearBinaryPath: true);

  void close() {
    _text.text = '';
    state = EditorState(findOpen: false, caseSensitive: state.caseSensitive);
  }

  void clearError() => state = state.copyWith(clearError: true);

  void setSaveEnding(LineEnding e) => state = state.copyWith(saveEnding: e);

  void consumePendingLine() => state = state.copyWith(clearPendingLine: true);

  void markSaved(String text, int size, DateTime modified) {
    final d = state.doc;
    if (d == null) return;
    state = state.copyWith(
      doc: d.savedAs(text: text, size: size, modified: modified),
    );
  }

  void setFindOpen(bool open) {
    state = state.copyWith(
      findOpen: open,
      matches: open ? state.matches : const [],
      current: open ? state.current : -1,
    );
    if (!open) _text.highlight = null;
  }

  void setCaseSensitive(bool v) => state = state.copyWith(caseSensitive: v);

  /// Recomputes matches for [query]; keeps the current index when possible.
  void updateMatches(String query) {
    final d = state.doc;
    if (d == null) return;
    final list = d.lines != null
        ? findLines(d.lines!, query, caseSensitive: state.caseSensitive)
        : findAllOffsets(_text.text, query, caseSensitive: state.caseSensitive);
    final cur = list.isEmpty ? -1 : (state.current >= 0 && state.current < list.length ? state.current : 0);
    state = state.copyWith(matches: list, current: cur);
    _applyHighlight(query);
  }

  void step(int delta, String query) {
    if (state.matches.isEmpty) return;
    final n = state.matches.length;
    final next = ((state.current < 0 ? 0 : state.current + delta) % n + n) % n;
    state = state.copyWith(current: next);
    _applyHighlight(query);
  }

  void _applyHighlight(String query) {
    final d = state.doc;
    if (d == null || d.lines != null || state.current < 0 || state.matches.isEmpty) {
      _text.highlight = null;
      return;
    }
    final start = state.matches[state.current];
    _text.highlight = TextRange(start: start, end: start + query.length);
    _text.selection = TextSelection(baseOffset: start, extentOffset: start + query.length);
  }
}

final editorProvider = NotifierProvider<EditorController, EditorState>(EditorController.new);
