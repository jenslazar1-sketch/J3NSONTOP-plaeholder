import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/io_flows.dart';
import '../../data/asset_worker.dart';
import '../../domain/icon_export.dart';
import '../../domain/image_codec.dart';

class IconSource {
  const IconSource({required this.name, required this.raster, required this.previewPng});
  final String name;
  final Raster raster;
  final Uint8List previewPng;

  bool get isSquare => raster.width == raster.height;
}

class IconRun {
  const IconRun({required this.result, required this.checks, required this.signature});
  final IconExportResult result;
  final List<IconCheck> checks;
  final String signature;

  int get passed => checks.where((c) => c.ok).length;
  bool get allPassed => passed == checks.length;
}

class IconState {
  const IconState({
    this.source,
    this.options = const IconExportOptions(),
    this.loading = false,
    this.loadError,
    this.generating = false,
    this.error,
    this.run,
  });

  final IconSource? source;
  final IconExportOptions options;
  final bool loading;
  final Object? loadError;
  final bool generating;
  final Object? error;
  final IconRun? run;

  String get signature {
    final o = options;
    return [
      source?.name,
      source?.raster.width,
      source?.raster.height,
      o.nonSquare.name,
      o.padColor.argb32,
      o.background.argb32,
      o.android,
      o.ios,
      o.windows,
    ].join('|');
  }

  bool get isStale => run != null && run!.signature != signature;

  IconState copyWith({
    IconSource? source,
    IconExportOptions? options,
    bool? loading,
    Object? Function()? loadError,
    bool? generating,
    Object? Function()? error,
    IconRun? Function()? run,
  }) => IconState(
    source: source ?? this.source,
    options: options ?? this.options,
    loading: loading ?? this.loading,
    loadError: loadError != null ? loadError() : this.loadError,
    generating: generating ?? this.generating,
    error: error != null ? error() : this.error,
    run: run != null ? run() : this.run,
  );
}

AssetTask<(Raster, Uint8List)> _loadTask(String path, String name) => () {
  final raster = decodeToRaster(readFileBounded(path), name);
  return (raster, makePreview(raster, 512).$1);
};

/// Generates every icon and verifies each output by decoding it again.
AssetTask<(IconExportResult, List<IconCheck>)> iconTask(Raster raster, IconExportOptions options) => () {
  final result = generateAppIconsFromRaster(raster, options);
  return (result, verifyAppIcons(result.files));
};

class IconController extends Notifier<IconState> {
  @override
  IconState build() => const IconState();

  Future<void> open(SelectedInput input) async {
    state = state.copyWith(loading: true, loadError: () => null);
    try {
      final (raster, png) = await ref.read(assetWorkerProvider).run(_loadTask(input.path, input.displayName));
      state = IconState(
        source: IconSource(name: fileBaseName(input.displayName), raster: raster, previewPng: png),
        options: state.options,
      );
    } catch (e) {
      state = state.copyWith(loading: false, loadError: () => e);
    }
  }

  void setOptions(IconExportOptions o) => state = state.copyWith(options: o);

  Future<void> generate() async {
    final src = state.source;
    if (src == null) return;
    final sig = state.signature;
    final options = state.options;
    state = state.copyWith(generating: true, error: () => null);
    try {
      final (result, checks) = await ref
          .read(activityProvider.notifier)
          .run<(IconExportResult, List<IconCheck>)>(
            toolId: 'assets.icons',
            title: 'Generate app icons',
            cancellable: true,
            notify: false,
            body: (op) async {
              op.progress(null, 'Scaling, encoding and verifying');
              final r = await ref.read(assetWorkerProvider).run(iconTask(src.raster, options), token: op.token);
              final failed = r.$2.where((c) => !c.ok).toList();
              final summary =
                  '${Fmt.count(r.$1.files.length, 'file')} (${Fmt.bytes(r.$1.totalBytes)}), '
                  '${r.$2.length - failed.length}/${r.$2.length} verified';
              if (failed.isEmpty) {
                op.succeed(summary, counts: {'files': r.$1.files.length, 'bytes': r.$1.totalBytes}, notify: false);
              } else {
                op.warn(summary, details: [for (final f in failed) '${f.path}: ${f.actual}']);
              }
              return r;
            },
          );
      state = state.copyWith(
        generating: false,
        run: () => IconRun(result: result, checks: checks, signature: sig),
      );
    } catch (e) {
      state = state.copyWith(generating: false, error: () => e, run: () => null);
    }
  }
}

final iconExportProvider = NotifierProvider<IconController, IconState>(IconController.new);
