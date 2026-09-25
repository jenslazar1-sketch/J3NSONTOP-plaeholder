import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/drafts/drafts.dart';
import '../../../../core/tasks/isolate_runner.dart';
import '../../data/config_file_io.dart';
import '../../domain/json_parser.dart';
import '../../domain/json_schema.dart';
import '../../domain/json_tools.dart';
import '../../domain/json_tree_ops.dart';
import '../../domain/json_value.dart';
import '../../domain/source_location.dart';

const String kSaveToolId = 'config.save_editor';
const String kSaveDocKey = 'config.save_editor/doc';
const String kSaveRawKey = 'config.save_editor/raw';

/// Time limit for one validation run (user patterns could backtrack).
const Duration kSchemaValidationTimeout = Duration(seconds: 2);

/// Sibling schema candidates for a save file, in lookup order.
List<String> schemaCandidates(String savePath) {
  final dir = p.dirname(savePath);
  final stem = p.basenameWithoutExtension(savePath);
  return [p.join(dir, '$stem.schema.json'), p.join(dir, 'save.schema.json')];
}

class SaveEditorState {
  const SaveEditorState({
    this.data,
    this.hasData = false,
    this.dataError,
    this.positions = const {},
    this.schemaJson,
    this.schema,
    this.schemaName,
    this.violations = const [],
    this.validating = false,
    this.validationError,
    this.collapsed = const {},
    this.version = 0,
  });

  /// Last valid save data.
  final Object? data;
  final bool hasData;

  /// The raw JSON currently does not parse (the form is read-only).
  final LocatedError? dataError;

  /// JSON Pointer -> offset in the raw text (for jumping to issues).
  final Map<String, int> positions;
  final Object? schemaJson;
  final SchemaParseResult? schema;
  final String? schemaName;
  final List<SchemaViolation> violations;
  final bool validating;
  final String? validationError;
  final Set<String> collapsed;

  /// Increments on every data change (form fields resync on it).
  final int version;

  bool get schemaOk => schema?.ok ?? false;

  SaveEditorState copyWith({
    Object? data,
    bool? hasData,
    LocatedError? dataError,
    bool clearDataError = false,
    Map<String, int>? positions,
    Object? schemaJson,
    SchemaParseResult? schema,
    String? schemaName,
    bool clearSchema = false,
    List<SchemaViolation>? violations,
    bool? validating,
    String? validationError,
    bool clearValidationError = false,
    Set<String>? collapsed,
    int? version,
  }) => SaveEditorState(
    data: data ?? this.data,
    hasData: hasData ?? this.hasData,
    dataError: clearDataError ? null : (dataError ?? this.dataError),
    positions: positions ?? this.positions,
    schemaJson: clearSchema ? null : (schemaJson ?? this.schemaJson),
    schema: clearSchema ? null : (schema ?? this.schema),
    schemaName: clearSchema ? null : (schemaName ?? this.schemaName),
    violations: violations ?? this.violations,
    validating: validating ?? this.validating,
    validationError: clearValidationError ? null : (validationError ?? this.validationError),
    collapsed: collapsed ?? this.collapsed,
    version: version ?? this.version,
  );
}

/// Parse result of the raw save text (top-level for `Isolate.run`).
(Object?, Map<String, int>, LocatedError?) parseSaveText(String text) {
  try {
    final out = parseJsonStrict(text, recordPositions: true);
    return (out.value, out.positions!, null);
  } on JsonSyntaxError catch (e) {
    return (null, const <String, int>{}, LocatedError.at(text, e.message, SourceLocation.fromOffset(text, e.offset)));
  }
}

class SaveEditorController extends Notifier<SaveEditorState> {
  String? _lastText;
  bool _running = false;
  bool _dirty = false;

  @override
  SaveEditorState build() => const SaveEditorState();

  TextEditingController get raw => ref.read(draftTextProvider(kSaveRawKey));

  /// Raw JSON edited (or loaded): re-parse and re-validate.
  Future<void> rawChanged() async {
    final text = raw.text;
    if (text == _lastText) return;
    _lastText = text;
    if (text.trim().isEmpty) {
      state = state.copyWith(hasData: false, clearDataError: true, violations: const [], version: state.version + 1);
      return;
    }
    final (value, positions, error) = text.length > kSyncParseLimit
        ? await Isolate.run(() => parseSaveText(text))
        : parseSaveText(text);
    if (!ref.mounted || raw.text != text) return;
    if (error != null) {
      state = state.copyWith(dataError: error);
      return;
    }
    state = state.copyWith(
      data: value,
      hasData: true,
      clearDataError: true,
      positions: positions,
      version: state.version + 1,
    );
    validate();
  }

  /// Applies a form edit and rewrites the raw JSON in its original style.
  void setData(Object? next) {
    final text = encodeLike(next, raw.text.trim().isEmpty ? '{\n  \n}\n' : raw.text);
    _lastText = text;
    raw.value = TextEditingValue(text: text, selection: const TextSelection.collapsed(offset: 0));
    state = state.copyWith(data: next, hasData: true, clearDataError: true, version: state.version + 1);
    unawaited(_refreshPositions(text));
    validate();
  }

  Future<void> _refreshPositions(String text) async {
    final (_, positions, _) = text.length > kSyncParseLimit
        ? await Isolate.run(() => parseSaveText(text))
        : parseSaveText(text);
    if (ref.mounted && raw.text == text) state = state.copyWith(positions: positions);
  }

  /// Throws [JsonEditError] for impossible edits.
  void setAt(List<Object> path, Object? value) => setData(setValueAt(state.data, path, value));
  void addProperty(List<Object> path, String key, Object? value) =>
      setData(addPropertyAt(state.data, path, key, value));
  void addItem(List<Object> path, Object? value) => setData(insertItemAt(state.data, path, value));
  void remove(List<Object> path) => setData(removeAt(state.data, path));
  void move(List<Object> arrayPath, int from, int to) => setData(moveItemAt(state.data, arrayPath, from, to));

  void toggleCollapsed(String pointer) {
    final next = {...state.collapsed};
    if (!next.remove(pointer)) next.add(pointer);
    state = state.copyWith(collapsed: next);
  }

  /// Sets the schema from decoded JSON.
  void setSchema(Object? json, String name) {
    state = state.copyWith(schemaJson: json, schema: parseSchema(json), schemaName: name, violations: const []);
    validate();
  }

  void clearSchema() {
    state = state.copyWith(clearSchema: true, violations: const [], clearValidationError: true);
  }

  /// Looks for a sibling schema of [savePath]; returns its path when loaded.
  Future<String?> autoDetectSchema(String savePath) async {
    for (final candidate in schemaCandidates(savePath)) {
      if (await File(candidate).exists()) {
        final loaded = await loadTextFile(candidate);
        final Object? json;
        try {
          json = decodeJsonStrict(loaded.text);
        } on JsonSyntaxError catch (e) {
          throw ConfigFileException('${p.basename(candidate)} is not valid JSON: ${e.message}');
        }
        if (!ref.mounted) return null;
        setSchema(json, p.basename(candidate));
        return candidate;
      }
    }
    return null;
  }

  /// Validates in a bounded isolate; edits made meanwhile are coalesced.
  void validate() {
    if (!state.schemaOk || !state.hasData || state.dataError != null) {
      state = state.copyWith(violations: const [], validating: false, clearValidationError: true);
      return;
    }
    _dirty = true;
    if (!_running) unawaited(_loop());
  }

  Future<void> _loop() async {
    _running = true;
    try {
      while (_dirty) {
        _dirty = false;
        final data = state.data;
        final schema = state.schemaJson;
        state = state.copyWith(validating: true);
        try {
          final v = await runBounded(() => validateWithSchemaJson(data, schema), timeout: kSchemaValidationTimeout);
          if (!ref.mounted) return;
          if (!_dirty) state = state.copyWith(violations: v, validating: false, clearValidationError: true);
        } on OperationTimedOut {
          if (!ref.mounted) return;
          state = state.copyWith(
            validating: false,
            validationError:
                'Validation stopped after ${kSchemaValidationTimeout.inSeconds} s: a "pattern" in the schema is too slow for this data.',
          );
        } catch (e) {
          if (!ref.mounted) return;
          state = state.copyWith(validating: false, validationError: 'Validation failed: $e');
        }
      }
    } finally {
      _running = false;
    }
  }

  /// Source location of [pointer] (or its closest existing parent).
  SourceLocation? locate(String pointer) {
    var ptr = pointer;
    while (true) {
      final off = state.positions[ptr];
      if (off != null) return SourceLocation.fromOffset(raw.text, off);
      if (ptr.isEmpty) return null;
      ptr = ptr.substring(0, ptr.lastIndexOf('/'));
    }
  }

  /// Violations whose pointer is exactly [path].
  List<SchemaViolation> violationsAt(List<Object> path) {
    final ptr = formatJsonPointer(path);
    return [
      for (final v in state.violations)
        if (v.pointer == ptr) v,
    ];
  }

  /// Number of violations at or below [path].
  int violationsBelow(List<Object> path) {
    final ptr = formatJsonPointer(path);
    return state.violations.where((v) => v.pointer == ptr || v.pointer.startsWith('$ptr/')).length;
  }
}

final saveEditorProvider = NotifierProvider<SaveEditorController, SaveEditorState>(SaveEditorController.new);
