import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/io_flows.dart';
import '../../data/asset_worker.dart';
import '../../domain/color_model.dart';
import '../../domain/image_codec.dart';

/// Image loaded for the eyedropper.
class EyedropperImage {
  const EyedropperImage({required this.name, required this.decoded});
  final String name;
  final DecodedImage decoded;
}

class ColorLabState {
  const ColorLabState({
    this.hsv = const Hsv(0, 1, 1),
    this.background = const Rgba(5, 5, 7),
    this.order = HexAlphaOrder.rgba,
    this.eyedropper,
    this.loadingImage = false,
    this.imageError,
    this.lastPick,
  });

  /// Kept as HSV so hue survives greys and black.
  final Hsv hsv;

  /// Second colour for the contrast checker (opaque).
  final Rgba background;
  final HexAlphaOrder order;
  final EyedropperImage? eyedropper;
  final bool loadingImage;
  final Object? imageError;

  /// Last eyedropper pixel (x, y).
  final (int, int)? lastPick;

  Rgba get color => ColorMath.fromHsv(hsv);

  ColorLabState copyWith({
    Hsv? hsv,
    Rgba? background,
    HexAlphaOrder? order,
    EyedropperImage? eyedropper,
    bool? loadingImage,
    Object? Function()? imageError,
    (int, int)? Function()? lastPick,
  }) => ColorLabState(
    hsv: hsv ?? this.hsv,
    background: background ?? this.background,
    order: order ?? this.order,
    eyedropper: eyedropper ?? this.eyedropper,
    loadingImage: loadingImage ?? this.loadingImage,
    imageError: imageError != null ? imageError() : this.imageError,
    lastPick: lastPick != null ? lastPick() : this.lastPick,
  );
}

class ColorLabController extends Notifier<ColorLabState> {
  /// Starts on the brand neon red.
  @override
  ColorLabState build() => ColorLabState(hsv: ColorMath.toHsv(const Rgba(255, 22, 59)));

  void setHsv(Hsv v) => state = state.copyWith(hsv: v);

  /// Sets an RGBA colour, keeping the previous hue for greys.
  void setColor(Rgba c) {
    final next = ColorMath.toHsv(c);
    final keepHue = next.s == 0 || next.v == 0;
    state = state.copyWith(
      hsv: Hsv(keepHue ? state.hsv.h : next.h, keepHue && next.v == 0 ? state.hsv.s : next.s, next.v, next.a),
    );
  }

  void setBackground(Rgba c) => state = state.copyWith(background: c.opaque);

  void swap() {
    final fg = state.color;
    final bg = state.background;
    setColor(bg);
    state = state.copyWith(background: fg.opaque);
  }

  void setOrder(HexAlphaOrder o) => state = state.copyWith(order: o);

  Future<void> openImage(SelectedInput input) async {
    state = state.copyWith(loadingImage: true, imageError: () => null);
    try {
      final decoded = await ref.read(assetWorkerProvider).run(decodeFileTask(input.path, input.displayName));
      state = state.copyWith(
        eyedropper: EyedropperImage(name: fileBaseName(input.displayName), decoded: decoded),
        loadingImage: false,
        lastPick: () => null,
      );
    } catch (e) {
      state = state.copyWith(loadingImage: false, imageError: () => e);
    }
  }

  /// Picks the pixel at image coordinates (x, y).
  Rgba? pick(int x, int y) {
    final img = state.eyedropper;
    if (img == null) return null;
    final r = img.decoded.raster;
    if (x < 0 || y < 0 || x >= r.width || y >= r.height) return null;
    final c = r.pixel(x, y);
    setColor(c);
    state = state.copyWith(lastPick: () => (x, y));
    return c;
  }
}

final colorLabProvider = NotifierProvider<ColorLabController, ColorLabState>(ColorLabController.new);
