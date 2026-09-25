import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/drafts/drafts.dart';
import '../../../../core/storage/user_data.dart';
import '../../../../core/text/diff.dart';
import '../../domain/json_parser.dart';
import '../../domain/json_tools.dart';
import '../../domain/merge_patch.dart';
import '../../domain/presets.dart';
import '../../domain/semantic_diff.dart';
import '../../domain/source_location.dart';

const String kPresetsToolId = 'config.presets';
const String kPresetsDocKey = 'config.presets/doc';
const String kPresetsTargetKey = 'config.presets/target';

/// User presets as stored in feature data (versioned payload).
final userPresetsProvider = Provider<PresetLoad>((ref) {
  final stored = ref.watch(featureDataProvider.select((m) => m[kPresetsKey]));
  return readPresetsPayload(stored);
});

/// Built-in examples followed by the user's presets.
final allPresetsProvider = Provider<List<ConfigPreset>>(
  (ref) => [...builtInPresets, ...ref.watch(userPresetsProvider).presets],
);

/// Outcome of applying a preset to the target document.
class PresetPreview {
  const PresetPreview({
    required this.presetId,
    required this.presetName,
    required this.sourceText,
    required this.afterText,
    required this.semantic,
    required this.text,
  });

  final String presetId;
  final String presetName;
  final String sourceText;
  final String afterText;
  final SemanticDiffResult semantic;
  final DiffResult text;
}

class PresetsState {
  const PresetsState({this.selectedId, this.preview, this.error});
  final String? selectedId;
  final PresetPreview? preview;

  /// Target document does not parse.
  final LocatedError? error;
}

class PresetsController extends Notifier<PresetsState> {
  static const _uuid = Uuid();

  @override
  PresetsState build() => PresetsState(selectedId: builtInPresets.first.id);

  String newId() => 'user.${_uuid.v4()}';

  List<ConfigPreset> get _user => ref.read(userPresetsProvider).presets;

  Future<void> _store(List<ConfigPreset> user) =>
      ref.read(featureDataProvider.notifier).write(kPresetsKey, presetsPayload(user));

  void select(String id) => state = PresetsState(selectedId: id, preview: null, error: null);

  ConfigPreset? byId(String? id) {
    for (final p in ref.read(allPresetsProvider)) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<ConfigPreset> create({
    required String name,
    required Object? patch,
    String description = '',
    String? target,
  }) async {
    final now = DateTime.now();
    final p = ConfigPreset(
      id: newId(),
      name: name,
      description: description,
      patch: patch,
      target: target,
      createdAt: now,
      updatedAt: now,
    );
    await _store([..._user, p]);
    state = PresetsState(selectedId: p.id);
    return p;
  }

  Future<void> update(ConfigPreset p) async {
    if (p.builtIn) throw StateError('Built-in presets cannot be changed');
    await _store([for (final u in _user) u.id == p.id ? p : u]);
    if (state.selectedId == p.id) state = PresetsState(selectedId: p.id);
  }

  Future<void> rename(String id, String name) async {
    final p = _user.firstWhere((u) => u.id == id);
    await update(p.copyWith(name: name));
  }

  Future<void> delete(String id) async {
    await _store([
      for (final u in _user)
        if (u.id != id) u,
    ]);
    if (state.selectedId == id) state = PresetsState(selectedId: builtInPresets.first.id);
  }

  /// Copies any preset (built-ins included) into an editable user preset.
  Future<ConfigPreset> duplicate(String id) {
    final p = byId(id)!;
    return create(name: '${p.name} (copy)', patch: p.patch, description: p.description, target: p.target);
  }

  /// Adds imported presets; returns the problems found.
  Future<PresetLoad> import(String text) async {
    final load = parsePresetImport(text, newId: newId);
    if (load.presets.isNotEmpty) await _store([..._user, ...load.presets]);
    return load;
  }

  /// Applies the selected preset to the target text and computes the diff
  /// (in a background isolate for documents over 256 KiB).
  Future<PresetPreview?> preview() async {
    final preset = byId(state.selectedId);
    final text = ref.read(draftTextProvider(kPresetsTargetKey)).text;
    if (preset == null) return null;
    final selected = state.selectedId;
    final (preview, error) = text.length > kSyncParseLimit
        ? await Isolate.run(() => computePresetPreview(text, preset))
        : computePresetPreview(text, preset);
    if (!ref.mounted) return preview;
    state = PresetsState(selectedId: selected, preview: preview, error: error);
    return preview;
  }

  void clearPreview() => state = PresetsState(selectedId: state.selectedId);
}

/// Applies [preset] to [text]. Top-level so it can run in `Isolate.run`.
(PresetPreview?, LocatedError?) computePresetPreview(String text, ConfigPreset preset) {
  final Object? before;
  try {
    before = decodeJsonStrict(text);
  } on JsonSyntaxError catch (e) {
    return (null, LocatedError.at(text, e.message, SourceLocation.fromOffset(text, e.offset)));
  }
  final after = applyMergePatch(before, preset.patch);
  final afterText = encodeLike(after, text);
  return (
    PresetPreview(
      presetId: preset.id,
      presetName: preset.name,
      sourceText: text,
      afterText: afterText,
      semantic: semanticDiff(before, after),
      text: LineDiff.diffText(text, afterText),
    ),
    null,
  );
}

final presetsProvider = NotifierProvider<PresetsController, PresetsState>(PresetsController.new);
