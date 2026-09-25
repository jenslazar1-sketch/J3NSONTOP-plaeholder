import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/io_flows.dart';
import '../../data/asset_worker.dart';
import '../../domain/color_model.dart';
import '../../domain/image_codec.dart';
import '../../domain/sprite_sheet.dart';

class SpriteSource {
  const SpriteSource({
    required this.name,
    required this.path,
    required this.fromWorkspace,
    required this.raster,
    required this.previewPng,
    required this.previewScale,
  });
  final String name;
  final String path;
  final bool fromWorkspace;
  final Raster raster;
  final Uint8List previewPng;
  final double previewScale;
}

class SpriteState {
  const SpriteState({
    this.source,
    this.spec = const GridSpec(),
    this.loading = false,
    this.loadError,
    this.baseName = 'frame',
    this.fps = 12,
    this.loop = true,
    this.frame = 0,
    this.gifBackground = const Rgba(5, 5, 7),
  });

  final SpriteSource? source;
  final GridSpec spec;
  final bool loading;
  final Object? loadError;
  final String baseName;
  final int fps;
  final bool loop;

  /// Frame shown when paused (the preview keeps its own playback clock).
  final int frame;
  final Rgba gifBackground;

  /// The resolved grid, or the reason it is invalid.
  (SpriteGrid?, String?) get grid {
    final s = source;
    if (s == null) return (null, null);
    try {
      return (resolveGrid(spec, s.raster.width, s.raster.height), null);
    } on GridException catch (e) {
      return (null, e.message);
    }
  }

  SpriteState copyWith({
    SpriteSource? source,
    GridSpec? spec,
    bool? loading,
    Object? Function()? loadError,
    String? baseName,
    int? fps,
    bool? loop,
    int? frame,
    Rgba? gifBackground,
  }) => SpriteState(
    source: source ?? this.source,
    spec: spec ?? this.spec,
    loading: loading ?? this.loading,
    loadError: loadError != null ? loadError() : this.loadError,
    baseName: baseName ?? this.baseName,
    fps: fps ?? this.fps,
    loop: loop ?? this.loop,
    frame: frame ?? this.frame,
    gifBackground: gifBackground ?? this.gifBackground,
  );
}

/// Picks a sensible starting frame size: 32 px when it tiles the sheet,
/// otherwise the short side for strips, otherwise 32 clamped to the sheet.
GridSpec guessGrid(int w, int h) {
  for (final s in const [32, 16, 64, 48, 24]) {
    if (w % s == 0 && h % s == 0 && (w ~/ s) * (h ~/ s) >= 2) return GridSpec(frameWidth: s, frameHeight: s);
  }
  final short = math.min(w, h);
  final long = math.max(w, h);
  if (short > 0 && long % short == 0 && long ~/ short >= 2) return GridSpec(frameWidth: short, frameHeight: short);
  return GridSpec(frameWidth: math.min(32, w), frameHeight: math.min(32, h));
}

AssetTask<(Raster, Uint8List, double)> _loadTask(String path, String name) => () {
  final raster = decodeToRaster(readFileBounded(path), name);
  final preview = makePreview(raster, 4096);
  return (raster, preview.$1, preview.$2);
};

AssetTask<int> _trimTask(Raster raster, SpriteGrid grid) =>
    () => countWithoutTrailingEmpty(raster, grid);

/// Slices frames to PNG files named `<base>_000.png`...
AssetTask<List<(String, Uint8List)>> sliceTask(Raster raster, SpriteGrid grid, String base) =>
    () => sliceFramesToPng(raster, grid, base);

AssetTask<Uint8List> gifTask(Raster raster, SpriteGrid grid, int fps, Rgba background) =>
    () => encodeFramesGif(raster, grid, fps: fps, background: background);

class SpriteController extends Notifier<SpriteState> {
  @override
  SpriteState build() => const SpriteState();

  Future<void> open(SelectedInput input) async {
    state = state.copyWith(loading: true, loadError: () => null);
    try {
      final (raster, png, scale) = await ref.read(assetWorkerProvider).run(_loadTask(input.path, input.displayName));
      state = SpriteState(
        source: SpriteSource(
          name: fileBaseName(input.displayName),
          path: input.path,
          fromWorkspace: input.fromWorkspace,
          raster: raster,
          previewPng: png,
          previewScale: scale,
        ),
        spec: guessGrid(raster.width, raster.height),
        baseName: sanitizeBaseName(fileStem(input.displayName)),
        fps: state.fps,
        loop: state.loop,
        gifBackground: state.gifBackground,
      );
    } catch (e) {
      state = state.copyWith(loading: false, loadError: () => e);
    }
  }

  void setSpec(GridSpec spec) => state = state.copyWith(spec: spec, frame: 0);
  void setBaseName(String name) => state = state.copyWith(baseName: name);
  void setFps(int fps) => state = state.copyWith(fps: fps.clamp(1, 60));
  void setLoop(bool loop) => state = state.copyWith(loop: loop);
  void setFrame(int frame) => state = state.copyWith(frame: frame);
  void setGifBackground(Rgba c) => state = state.copyWith(gifBackground: c);

  /// Drops fully transparent cells at the end of the grid.
  Future<int?> trimTrailingEmpty() async {
    final src = state.source;
    final (grid, _) = state.copyWith(spec: state.spec.copyWith(frameCount: () => null)).grid;
    if (src == null || grid == null) return null;
    final n = await ref.read(assetWorkerProvider).run(_trimTask(src.raster, grid));
    state = state.copyWith(spec: state.spec.copyWith(frameCount: () => n), frame: 0);
    return n;
  }
}

final spriteProvider = NotifierProvider<SpriteController, SpriteState>(SpriteController.new);
