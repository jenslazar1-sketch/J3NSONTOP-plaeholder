import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/widgets/widgets.dart';
import 'checkerboard.dart';

/// Builds an overlay for the displayed image. [scale] is display pixels per
/// source pixel; the overlay is laid out at the displayed image size.
typedef ViewportOverlayBuilder = Widget Function(BuildContext context, double scale);

const List<double> _zoomSteps = [0.125, 0.25, 0.5, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32];

/// Image preview over a transparency checkerboard with fit/zoom controls,
/// crisp nearest-neighbour scaling for pixel art and zoom, a pixel grid at
/// high zoom and an optional overlay (crop handles, grids, outlines).
///
/// [png] may be a downscaled preview; [sourceWidth]/[sourceHeight] are the
/// real dimensions used for zoom percentages and overlay coordinates.
class ImageViewport extends StatefulWidget {
  const ImageViewport({
    super.key,
    required this.png,
    required this.sourceWidth,
    required this.sourceHeight,
    this.height = 340,
    this.pixelArt = false,
    this.overlay,
    this.fitOnly = false,
    this.semanticLabel = 'Image preview',
    this.maxFitScale = 16,
    this.footer,
    this.overlayMargin = 0,
  });

  final Uint8List png;
  final int sourceWidth;
  final int sourceHeight;
  final double height;

  /// Always use nearest-neighbour sampling.
  final bool pixelArt;
  final ViewportOverlayBuilder? overlay;

  /// Disable zoom (used while dragging crop handles).
  final bool fitOnly;
  final String semanticLabel;

  /// Upper bound for the automatic fit scale (tiny sprites).
  final double maxFitScale;
  final Widget? footer;

  /// Free space kept around the image in fit mode so overlay handles drawn
  /// on the image edges stay fully visible.
  final double overlayMargin;

  @override
  State<ImageViewport> createState() => _ImageViewportState();
}

class _ImageViewportState extends State<ImageViewport> {
  double? _zoom; // null = fit
  final _h = ScrollController();
  final _v = ScrollController();

  @override
  void dispose() {
    _h.dispose();
    _v.dispose();
    super.dispose();
  }

  double _fitScale(double w, double h) {
    final s = math.min(w / widget.sourceWidth, h / widget.sourceHeight);
    return math.min(s, widget.maxFitScale);
  }

  void _step(double current, int dir) {
    double? next;
    if (dir > 0) {
      next = _zoomSteps.firstWhere((z) => z > current + 1e-6, orElse: () => _zoomSteps.last);
    } else {
      next = _zoomSteps.lastWhere((z) => z < current - 1e-6, orElse: () => _zoomSteps.first);
    }
    setState(() => _zoom = next);
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    return LayoutBuilder(
      builder: (context, c) {
        final viewW = c.maxWidth;
        final viewH = widget.height;
        final margin = widget.overlayMargin;
        final fit = _fitScale(viewW - 2 - 2 * margin, viewH - 2 - 2 * margin);
        final scale = widget.fitOnly ? fit : (_zoom ?? fit);
        final dw = widget.sourceWidth * scale;
        final dh = widget.sourceHeight * scale;
        final crisp = widget.pixelArt || scale >= 2;

        final Widget canvas = SizedBox(
          width: dw,
          height: dh,
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              const CustomPaint(painter: CheckerboardPainter()),
              Image.memory(
                widget.png,
                width: dw,
                height: dh,
                fit: BoxFit.fill,
                filterQuality: crisp ? FilterQuality.none : FilterQuality.medium,
                gaplessPlayback: true,
                excludeFromSemantics: true,
              ),
              if (scale >= 8 && crisp)
                IgnorePointer(
                  child: CustomPaint(
                    painter: PixelGridPainter(scale: scale, color: J3Colors.background.withValues(alpha: 0.35)),
                  ),
                ),
              if (widget.overlay != null) widget.overlay!(context, scale),
            ],
          ),
        );

        final fits = dw <= viewW - 2 - 2 * margin && dh <= viewH - 2 - 2 * margin;
        Widget area;
        if (fits) {
          area = Center(
            child: Padding(padding: EdgeInsets.all(margin), child: canvas),
          );
        } else {
          area = Scrollbar(
            controller: _v,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _v,
              child: Scrollbar(
                controller: _h,
                thumbVisibility: true,
                notificationPredicate: (n) => n.depth == 0,
                child: SingleChildScrollView(controller: _h, scrollDirection: Axis.horizontal, child: canvas),
              ),
            ),
          );
        }

        final pct = '${(scale * 100).round()}%';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              image: true,
              label: '${widget.semanticLabel}, ${widget.sourceWidth} by ${widget.sourceHeight} pixels, zoom $pct',
              child: Container(
                height: viewH,
                decoration: BoxDecoration(
                  color: J3Colors.inputFill,
                  borderRadius: J3Radius.small,
                  border: Border.all(color: J3Colors.border),
                ),
                clipBehavior: Clip.hardEdge,
                child: area,
              ),
            ),
            const SizedBox(height: J3Space.xs),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: J3Space.xs,
              runSpacing: J3Space.xs,
              children: [
                if (!widget.fitOnly) ...[
                  NeonIconButton(
                    icon: Icons.zoom_out,
                    tooltip: 'Zoom out',
                    onPressed: scale <= _zoomSteps.first ? null : () => _step(scale, -1),
                  ),
                  NeonIconButton(
                    icon: Icons.zoom_in,
                    tooltip: 'Zoom in',
                    onPressed: scale >= _zoomSteps.last ? null : () => _step(scale, 1),
                  ),
                  NeonIconButton(
                    icon: Icons.fit_screen_outlined,
                    tooltip: 'Fit to view',
                    selected: _zoom == null,
                    onPressed: () => setState(() => _zoom = null),
                  ),
                  NeonIconButton(
                    icon: Icons.crop_original,
                    tooltip: 'Actual size (100%)',
                    selected: _zoom == 1,
                    onPressed: () => setState(() => _zoom = 1),
                  ),
                ],
                Text(
                  '${widget.sourceWidth}x${widget.sourceHeight} px  |  ${_zoom == null || widget.fitOnly ? 'fit ' : ''}$pct'
                  '${crisp ? '  |  nearest' : ''}${scale >= 8 && crisp ? ' + pixel grid' : ''}',
                  style: J3Type.codeSmall.copyWith(color: fx.accentText),
                ),
                ?widget.footer,
              ],
            ),
          ],
        );
      },
    );
  }
}
