import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/utils/safe_path.dart';
import '../../data/asset_worker.dart';
import '../../domain/atlas_packer.dart';
import '../../domain/image_codec.dart';

/// One image added to the atlas.
class AtlasSprite {
  const AtlasSprite({
    required this.id,
    required this.name,
    required this.fileName,
    required this.raster,
    required this.thumb,
  });
  final String id;
  final String name;
  final String fileName;
  final Raster raster;
  final Uint8List thumb;

  AtlasSprite rename(String n) => AtlasSprite(id: id, name: n, fileName: fileName, raster: raster, thumb: thumb);
}

/// A finished pack.
class AtlasResult {
  const AtlasResult({
    required this.layout,
    required this.validation,
    required this.png,
    required this.previewPng,
    required this.json,
    required this.imageName,
    required this.signature,
  });
  final AtlasLayout layout;
  final AtlasValidation validation;
  final Uint8List png;
  final Uint8List previewPng;
  final String json;
  final String imageName;

  /// Inputs the result was built from (to flag stale results).
  final String signature;
}

class AtlasState {
  const AtlasState({
    this.sprites = const [],
    this.options = const AtlasOptions(),
    this.atlasName = 'atlas',
    this.result,
    this.packing = false,
    this.packError,
    this.importing = false,
    this.importNotes = const [],
  });

  static const int maxSprites = 2000;

  final List<AtlasSprite> sprites;
  final AtlasOptions options;
  final String atlasName;
  final AtlasResult? result;
  final bool packing;
  final Object? packError;
  final bool importing;

  /// Skipped files (duplicates, unreadable) from the last import.
  final List<String> importNotes;

  String get safeName {
    final s = SafePath.sanitizeFileName(atlasName.trim(), fallback: 'atlas');
    return s.toLowerCase().endsWith('.png') ? s.substring(0, s.length - 4) : s;
  }

  String get signature => [
    for (final s in sprites) '${s.id}:${s.name}',
    options.padding,
    options.extrude,
    options.maxSize,
    options.powerOfTwo,
    safeName,
  ].join('|');

  bool get isStale => result != null && result!.signature != signature;

  AtlasState copyWith({
    List<AtlasSprite>? sprites,
    AtlasOptions? options,
    String? atlasName,
    AtlasResult? Function()? result,
    bool? packing,
    Object? Function()? packError,
    bool? importing,
    List<String>? importNotes,
  }) => AtlasState(
    sprites: sprites ?? this.sprites,
    options: options ?? this.options,
    atlasName: atlasName ?? this.atlasName,
    result: result != null ? result() : this.result,
    packing: packing ?? this.packing,
    packError: packError != null ? packError() : this.packError,
    importing: importing ?? this.importing,
    importNotes: importNotes ?? this.importNotes,
  );
}

/// Validates a sprite name against the others.
String? validateSpriteName(String name, Iterable<String> others) {
  final n = name.trim();
  if (n.isEmpty) return 'Enter a name';
  if (n.length > 200) return 'Keep names under 200 characters';
  if (n.codeUnits.any((c) => c < 32)) return 'Control characters are not allowed';
  if (others.contains(n)) return 'Another sprite is already called "$n"';
  return null;
}

/// Decoded file (or the reason it was skipped).
typedef DecodedSprite = ({String file, Raster? raster, Uint8List? thumb, String? error});

AssetTask<List<DecodedSprite>> decodeSpritesTask(List<(String, String)> files) => () {
  final out = <DecodedSprite>[];
  for (final (path, name) in files) {
    try {
      final raster = decodeToRaster(readFileBounded(path), name);
      if (raster.width > atlasProbeLimit || raster.height > atlasProbeLimit) {
        out.add((file: name, raster: null, thumb: null, error: 'larger than $atlasProbeLimit px'));
        continue;
      }
      out.add((file: name, raster: raster, thumb: makePreview(raster, 64).$1, error: null));
    } catch (e) {
      out.add((file: name, raster: null, thumb: null, error: e.toString()));
    }
  }
  return out;
};

AssetTask<AtlasResult> packTask(
  List<(String, Raster)> sprites,
  AtlasOptions options,
  String imageName,
  String signature,
) => () {
  final layout = packAtlas([for (final (n, r) in sprites) AtlasInput(n, r.width, r.height)], options);
  final validation = validateLayout(layout);
  final raster = composeAtlas(layout, {for (final (n, r) in sprites) n: r});
  final png = encodePngRaster(raster);
  final preview = raster.width > 2048 || raster.height > 2048 ? makePreview(raster, 2048).$1 : png;
  return AtlasResult(
    layout: layout,
    validation: validation,
    png: png,
    previewPng: preview,
    json: atlasJson(layout, imageName),
    imageName: imageName,
    signature: signature,
  );
};

/// Writes `<name>.png` and a matching `<name>.json` into [folder] without
/// overwriting; the JSON's `meta.image` names the PNG actually written.
AssetTask<List<String>> saveAtlasTask(String root, String folder, String name, Uint8List png, AtlasLayout layout) =>
    () {
      if (!SafePath.isWithin(root, folder)) {
        throw FileSystemException('Refusing to write outside the workspace', folder);
      }
      final pngPath = SafePath.uniquePath(SafePath.resolveInside(folder, '$name.png'));
      final jsonPath = SafePath.uniquePath(p.join(folder, '${p.basenameWithoutExtension(pngPath)}.json'));
      void write(String path, List<int> bytes) {
        final tmp = File('$path.j3part')..writeAsBytesSync(bytes, flush: true);
        tmp.renameSync(path);
      }

      write(pngPath, png);
      write(jsonPath, utf8.encode(atlasJson(layout, p.basename(pngPath))));
      return [pngPath, jsonPath];
    };

class AtlasController extends Notifier<AtlasState> {
  static const _uuid = Uuid();

  @override
  AtlasState build() => const AtlasState();

  /// Decodes and adds files ([(path, displayName)]). Names default to the
  /// file name without extension; duplicates are rejected and reported.
  Future<void> addFiles(List<(String, String)> files) async {
    if (files.isEmpty) return;
    state = state.copyWith(importing: true, importNotes: const []);
    final notes = <String>[];
    try {
      final decoded = await ref.read(assetWorkerProvider).run(decodeSpritesTask(files));
      final names = {for (final s in state.sprites) s.name};
      final added = <AtlasSprite>[];
      for (final d in decoded) {
        if (d.raster == null) {
          notes.add('Skipped ${d.file}: ${d.error}');
          continue;
        }
        final name = fileStem(d.file);
        if (names.contains(name)) {
          notes.add('Skipped ${d.file}: the name "$name" is already used (rename one of them first).');
          continue;
        }
        if (state.sprites.length + added.length >= AtlasState.maxSprites) {
          notes.add('Skipped ${d.file}: at most ${AtlasState.maxSprites} sprites per atlas.');
          continue;
        }
        names.add(name);
        added.add(AtlasSprite(id: _uuid.v4(), name: name, fileName: d.file, raster: d.raster!, thumb: d.thumb!));
      }
      state = state.copyWith(sprites: [...state.sprites, ...added], importing: false, importNotes: notes);
    } catch (e) {
      state = state.copyWith(importing: false, importNotes: ['Import failed: $e']);
    }
  }

  /// Returns an error message, or null when renamed.
  String? rename(String id, String name) {
    final err = validateSpriteName(name, [
      for (final s in state.sprites)
        if (s.id != id) s.name,
    ]);
    if (err != null) return err;
    state = state.copyWith(sprites: [for (final s in state.sprites) s.id == id ? s.rename(name.trim()) : s]);
    return null;
  }

  void remove(String id) => state = state.copyWith(sprites: state.sprites.where((s) => s.id != id).toList());

  void clear() =>
      state = state.copyWith(sprites: const [], result: () => null, packError: () => null, importNotes: const []);

  void setOptions(AtlasOptions o) => state = state.copyWith(options: o);

  void setName(String n) => state = state.copyWith(atlasName: n);

  Future<void> pack() async {
    if (state.sprites.isEmpty) {
      state = state.copyWith(packError: () => 'Add at least one image to pack.');
      return;
    }
    final sig = state.signature;
    final sprites = [for (final s in state.sprites) (s.name, s.raster)];
    final options = state.options;
    final imageName = '${state.safeName}.png';
    state = state.copyWith(packing: true, packError: () => null);
    try {
      final r = await ref
          .read(activityProvider.notifier)
          .run<AtlasResult>(
            toolId: 'assets.atlas',
            title: 'Pack ${sprites.length} sprites',
            cancellable: true,
            notify: false,
            body: (op) async {
              op.progress(null, 'MaxRects packing, composing and validating');
              final r = await ref
                  .read(assetWorkerProvider)
                  .run(packTask(sprites, options, imageName, sig), token: op.token);
              final l = r.layout;
              final summary =
                  'Packed ${l.frames.length} sprites into ${l.width}x${l.height} '
                  '(${(l.efficiency * 100).toStringAsFixed(1)}% used)';
              if (r.validation.ok) {
                op.succeed(summary, counts: {'sprites': l.frames.length, 'bytes': r.png.length}, notify: false);
              } else {
                op.warn('$summary, validator found ${r.validation.issues.length} issues', details: r.validation.issues);
              }
              return r;
            },
          );
      state = state.copyWith(packing: false, result: () => r);
    } catch (e) {
      state = state.copyWith(packing: false, packError: () => e, result: () => null);
    }
  }
}

final atlasProvider = NotifierProvider<AtlasController, AtlasState>(AtlasController.new);
