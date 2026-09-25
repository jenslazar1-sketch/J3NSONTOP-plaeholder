import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/tasks/cancellation.dart';
import '../../../../core/widgets/io_flows.dart';
import '../../data/asset_worker.dart';
import '../../domain/image_codec.dart';
import '../../domain/image_ops.dart';

/// The image currently open in the studio.
class StudioSource {
  const StudioSource({
    required this.name,
    required this.label,
    required this.path,
    required this.fromWorkspace,
    required this.decoded,
  });
  final String name;

  /// Workspace-relative path or picked file name, for display.
  final String label;
  final String path;
  final bool fromWorkspace;
  final DecodedImage decoded;

  PixelSize get size => PixelSize(decoded.raster.width, decoded.raster.height);
}

/// Rendered pipeline output plus the encoded export file.
class StudioOutput {
  const StudioOutput({required this.render, required this.raster, this.encoded, this.encodeError});
  final StudioRender render;

  /// Full-resolution pipeline result (re-encoded when only export settings change).
  final Raster raster;
  final EncodedImage? encoded;
  final String? encodeError;
}

class CropEditor {
  const CropEditor({this.active = false, this.rect = const CropRect(0, 0, 1, 1), this.aspect = CropAspect.free});
  final bool active;
  final CropRect rect;
  final CropAspect aspect;

  CropEditor copyWith({bool? active, CropRect? rect, CropAspect? aspect}) =>
      CropEditor(active: active ?? this.active, rect: rect ?? this.rect, aspect: aspect ?? this.aspect);
}

class StudioState {
  const StudioState({
    this.source,
    this.history = const PipelineHistory(),
    this.export = const ExportSettings(),
    this.output,
    this.rendering = false,
    this.loading = false,
    this.loadError,
    this.renderError,
    this.showBefore = false,
    this.crop = const CropEditor(),
    this.customName,
  });

  final StudioSource? source;
  final PipelineHistory history;
  final ExportSettings export;
  final StudioOutput? output;
  final bool rendering;
  final bool loading;
  final Object? loadError;
  final Object? renderError;
  final bool showBefore;
  final CropEditor crop;

  /// Output file name typed by the user (null = default `<name>_edited.<ext>`).
  final String? customName;

  PipelinePlan? get plan => source == null ? null : planPipeline(source!.size, history.ops);

  /// Size after every runnable op.
  PixelSize? get currentSize => plan?.sizes.last;

  String get outputName {
    final ext = export.format.extension;
    if (customName != null && customName!.trim().isNotEmpty) return withExtension(customName!.trim(), ext);
    return editedFileName(source?.name ?? 'image.png', ext);
  }

  StudioState copyWith({
    StudioSource? source,
    PipelineHistory? history,
    ExportSettings? export,
    StudioOutput? Function()? output,
    bool? rendering,
    bool? loading,
    Object? Function()? loadError,
    Object? Function()? renderError,
    bool? showBefore,
    CropEditor? crop,
    String? Function()? customName,
  }) => StudioState(
    source: source ?? this.source,
    history: history ?? this.history,
    export: export ?? this.export,
    output: output != null ? output() : this.output,
    rendering: rendering ?? this.rendering,
    loading: loading ?? this.loading,
    loadError: loadError != null ? loadError() : this.loadError,
    renderError: renderError != null ? renderError() : this.renderError,
    showBefore: showBefore ?? this.showBefore,
    crop: crop ?? this.crop,
    customName: customName != null ? customName() : this.customName,
  );
}

/// Replaces (or adds) the extension of [name].
String withExtension(String name, String ext) {
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  return '$stem.$ext';
}

// Top-level task builders: the closures capture plain data only.
AssetTask<StudioRender> _renderTask(StudioRenderRequest req) =>
    () => renderStudio(req);

/// Encoding errors are returned as data because exceptions thrown in a
/// worker isolate arrive as plain messages.
AssetTask<(EncodedImage?, String?)> _encodeTask(Raster raster, ExportSettings settings) => () {
  try {
    return (encodeRaster(raster, settings), null);
  } on EncodeException catch (e) {
    return (null, e.message);
  }
};

class StudioController extends Notifier<StudioState> {
  int _generation = 0;
  CancellationToken? _token;

  @override
  StudioState build() => const StudioState();

  AssetWorker get _worker => ref.read(assetWorkerProvider);

  Future<void> open(SelectedInput input) async {
    _token?.cancel();
    state = state.copyWith(loading: true, loadError: () => null);
    try {
      final decoded = await _worker.run(decodeFileTask(input.path, input.displayName));
      state = StudioState(
        source: StudioSource(
          name: fileBaseName(input.displayName),
          label: input.displayName.replaceAll(r'\', '/'),
          path: input.path,
          fromWorkspace: input.fromWorkspace,
          decoded: decoded,
        ),
        export: state.export,
        crop: CropEditor(rect: CropRect(0, 0, decoded.raster.width, decoded.raster.height)),
      );
      await _render(pipelineChanged: true);
    } catch (e) {
      state = state.copyWith(loading: false, loadError: () => e);
    }
  }

  void _setHistory(PipelineHistory h) {
    final size = state.source == null ? null : planPipeline(state.source!.size, h.ops).sizes.last;
    state = state.copyWith(
      history: h,
      crop: state.crop.copyWith(active: false, rect: size == null ? null : CropRect(0, 0, size.width, size.height)),
    );
    _render(pipelineChanged: true);
  }

  void addOp(ImageOp op) => _setHistory(state.history.add(op));
  void removeOp(int index) => _setHistory(state.history.removeAt(index));
  void moveOp(int from, int to) => _setHistory(state.history.move(from, to));
  void undo() => _setHistory(state.history.undo());
  void redo() => _setHistory(state.history.redo());
  void reset() => _setHistory(state.history.reset());

  void setExport(ExportSettings s) {
    state = state.copyWith(export: s);
    _render(pipelineChanged: false);
  }

  void setCustomName(String? name) => state = state.copyWith(customName: () => name);

  void toggleBefore(bool before) => state = state.copyWith(showBefore: before);

  // ------------------------------------------------------------ crop editor

  void startCrop() {
    final size = state.currentSize;
    if (size == null) return;
    final rect = state.crop.rect.clampTo(size);
    state = state.copyWith(
      showBefore: false,
      crop: state.crop.copyWith(
        active: true,
        rect: state.crop.aspect.ratio == null ? rect : rect.fitAspect(state.crop.aspect.ratio!, size),
      ),
    );
  }

  void cancelCrop() => state = state.copyWith(crop: state.crop.copyWith(active: false));

  void setCropRect(CropRect r) => state = state.copyWith(crop: state.crop.copyWith(rect: r));

  void setCropAspect(CropAspect a) {
    final size = state.currentSize;
    var rect = state.crop.rect;
    if (size != null && a.ratio != null) rect = rect.fitAspect(a.ratio!, size);
    state = state.copyWith(
      crop: state.crop.copyWith(aspect: a, rect: rect),
    );
  }

  // ------------------------------------------------------------ rendering

  Future<void> _render({required bool pipelineChanged}) async {
    final src = state.source;
    if (src == null) return;
    _token?.cancel();
    final token = CancellationToken();
    _token = token;
    final gen = ++_generation;
    state = state.copyWith(rendering: true, renderError: () => null, loading: false);
    try {
      final prev = state.output;
      StudioOutput out;
      if (!pipelineChanged && prev != null && prev.render.pipelineError == null) {
        final (enc, err) = await _worker.run(_encodeTask(prev.raster, state.export), token: token);
        out = StudioOutput(render: prev.render, raster: prev.raster, encoded: enc, encodeError: err);
      } else {
        final render = await _worker.run(
          _renderTask(StudioRenderRequest(source: src.decoded.raster, ops: state.history.ops, settings: state.export)),
          token: token,
        );
        out = StudioOutput(
          render: render,
          raster: render.output,
          encoded: render.encoded,
          encodeError: render.encodeError,
        );
      }
      if (gen != _generation) return;
      state = state.copyWith(output: () => out, rendering: false);
    } on OperationCancelled {
      // Superseded by a newer render.
    } catch (e) {
      if (gen != _generation) return;
      state = state.copyWith(rendering: false, renderError: () => e);
    }
  }

  /// Bytes of the current export file, if ready.
  Uint8List? get exportBytes => state.output?.encoded?.bytes;
}

final studioProvider = NotifierProvider<StudioController, StudioState>(StudioController.new);
