import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/drafts/drafts.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../domain/image_codec.dart';
import '../../domain/sprite_sheet.dart';
import '../asset_actions.dart';
import '../widgets/checkerboard.dart';
import '../widgets/color_widgets.dart';
import '../widgets/image_viewport.dart';
import '../widgets/status_line.dart';
import 'sprite_controller.dart';

const String _tool = 'assets.sprites';

/// Sprite Sheet: define a frame grid on a sheet, preview the animation,
/// then slice frames to PNGs (ZIP or workspace folder) or an animated GIF.
class SpriteSheetPage extends ConsumerWidget {
  const SpriteSheetPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSource = ref.watch(spriteProvider.select((s) => s.source != null));
    return ToolScaffold(
      toolId: _tool,
      inputs: [const _SheetPanel(), if (hasSource) const _SheetPreview()],
      results: hasSource ? const [_AnimationPanel(), _ExportPanel()] : const [_Empty()],
    );
  }
}

Future<void> _open(BuildContext context, WidgetRef ref) async {
  final input = await pickImage(context, ref, decodableImageExtensions, title: 'Open sprite sheet');
  if (input == null) return;
  await ref.read(spriteProvider.notifier).open(input);
}

class _Empty extends ConsumerWidget {
  const _Empty();

  @override
  Widget build(BuildContext context, WidgetRef ref) => NeonPanel(
    kicker: 'Preview',
    title: 'No sheet loaded',
    child: EmptyState(
      title: 'Load a sprite sheet',
      message: 'Frames are cut on a grid you define: frame size or columns x rows, with margin and spacing.',
      glyph: '[#][#][#]',
      action: NeonButton(label: 'Open sheet', icon: Icons.grid_on, onPressed: () => _open(context, ref)),
    ),
  );
}

class _SheetPanel extends ConsumerStatefulWidget {
  const _SheetPanel();

  @override
  ConsumerState<_SheetPanel> createState() => _SheetPanelState();
}

class _SheetPanelState extends ConsumerState<_SheetPanel> {
  TextEditingController _t(String f) => ref.read(draftTextProvider('$_tool/$f'));

  @override
  void initState() {
    super.initState();
    if (_t('fw').text.isEmpty) _fill(ref.read(spriteProvider).spec);
  }

  void _fill(GridSpec s) {
    _t('fw').text = '${s.frameWidth}';
    _t('fh').text = '${s.frameHeight}';
    _t('cols').text = s.columns?.toString() ?? '';
    _t('rows').text = s.rows?.toString() ?? '';
    _t('margin').text = '${s.margin}';
    _t('spacing').text = '${s.spacing}';
    _t('count').text = s.frameCount?.toString() ?? '';
  }

  int? _opt(String f) {
    final t = _t(f).text.trim();
    return t.isEmpty ? null : int.tryParse(t);
  }

  void _apply() {
    final st = ref.read(spriteProvider);
    final spec = st.spec;
    final (grid, _) = st.grid;
    int keep(String f, int fallback) => _opt(f) ?? fallback;
    var next = spec.copyWith(
      frameWidth: keep('fw', spec.frameWidth),
      frameHeight: keep('fh', spec.frameHeight),
      margin: keep('margin', spec.margin),
      spacing: keep('spacing', spec.spacing),
      columns: () => _opt('cols'),
      rows: () => _opt('rows'),
      frameCount: () => _opt('count'),
    );
    if (spec.mode == GridMode.columnsRows) {
      next = next.copyWith(columns: () => _opt('cols') ?? grid?.columns, rows: () => _opt('rows') ?? grid?.rows);
    }
    ref.read(spriteProvider.notifier).setSpec(next);
  }

  void _setMode(GridMode mode) {
    final st = ref.read(spriteProvider);
    final (grid, _) = st.grid;
    var next = st.spec.copyWith(mode: mode);
    if (mode == GridMode.columnsRows && grid != null) {
      next = next.copyWith(columns: () => grid.columns, rows: () => grid.rows);
    }
    if (mode == GridMode.frameSize && grid != null) {
      next = next.copyWith(
        frameWidth: grid.frameWidth,
        frameHeight: grid.frameHeight,
        columns: () => null,
        rows: () => null,
      );
    }
    ref.read(spriteProvider.notifier).setSpec(next);
    _fill(next);
  }

  Future<void> _trim() async {
    final n = await ref.read(spriteProvider.notifier).trimTrailingEmpty();
    if (n != null) _t('count').text = '$n';
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(spriteProvider);
    ref.listen(spriteProvider.select((s) => s.source?.path), (prev, next) {
      if (prev != next) _fill(ref.read(spriteProvider).spec);
    });
    final src = st.source;
    final (grid, error) = st.grid;
    final spec = st.spec;
    final auto = spec.mode == GridMode.frameSize;

    Widget field(String f, String label, {int min = 0, String? hint}) => NumberField(
      controller: _t(f),
      label: hint == null ? label : '$label ($hint)',
      min: min,
      max: 100000,
      width: hint == null ? 116 : 140,
      onChanged: (_) => _apply(),
    );

    return NeonPanel(
      kicker: 'Input',
      title: src == null ? 'Sprite sheet' : src.name,
      icon: Icons.grid_on,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              NeonButton(
                label: src == null ? 'Open sheet' : 'Open another',
                icon: Icons.folder_open,
                busy: st.loading,
                onPressed: () => _open(context, ref),
              ),
            ],
          ),
          if (st.loadError != null) ...[
            const SizedBox(height: J3Space.md),
            ErrorPanel(title: 'Cannot open sheet', error: st.loadError!),
          ],
          if (src != null) ...[
            const SizedBox(height: J3Space.sm),
            Text(
              'Sheet: ${src.raster.width} x ${src.raster.height} px, ${src.raster.hasAlpha ? 'RGBA' : 'RGB (no alpha)'}',
              style: J3Type.codeSmall,
            ),
            const SizedBox(height: J3Space.md),
            ChoiceRow<GridMode>(
              label: 'Grid by',
              options: GridMode.values,
              selected: spec.mode,
              onSelected: _setMode,
              labelOf: (m) => m.label,
            ),
            const SizedBox(height: J3Space.sm),
            Wrap(
              spacing: J3Space.sm,
              runSpacing: J3Space.sm,
              children: [
                if (auto) ...[field('fw', 'Frame W', min: 1), field('fh', 'Frame H', min: 1)],
                field('cols', 'Columns', min: 1, hint: auto ? 'auto' : null),
                field('rows', 'Rows', min: 1, hint: auto ? 'auto' : null),
                field('margin', 'Margin'),
                field('spacing', 'Spacing'),
                field('count', 'Frames', min: 1, hint: 'all'),
              ],
            ),
            const SizedBox(height: J3Space.sm),
            Wrap(
              spacing: J3Space.sm,
              runSpacing: J3Space.sm,
              children: [
                NeonButton.ghost(
                  label: 'Trim empty trailing cells',
                  icon: Icons.content_cut,
                  tooltip: 'Sets the frame count so fully transparent cells at the end are excluded',
                  onPressed: grid == null ? null : _trim,
                ),
              ],
            ),
            const SizedBox(height: J3Space.md),
            if (error != null)
              StatusBanner(kind: StatusKind.error, title: 'Grid does not fit', message: error)
            else if (grid != null) ...[
              StatusLine(
                kind: StatusKind.success,
                text:
                    '${grid.columns} x ${grid.rows} grid of ${grid.frameWidth} x ${grid.frameHeight} px, '
                    '${grid.frameCount} of ${grid.cellCount} cells used.',
              ),
              for (final w in grid.warnings) ...[
                const SizedBox(height: J3Space.xs),
                StatusLine(kind: StatusKind.warning, text: w),
              ],
            ],
          ],
        ],
      ),
    );
  }
}

class _ExportPanel extends ConsumerStatefulWidget {
  const _ExportPanel();

  @override
  ConsumerState<_ExportPanel> createState() => _ExportPanelState();
}

class _ExportPanelState extends ConsumerState<_ExportPanel> {
  late final TextEditingController nameCtrl = ref.read(draftTextProvider('$_tool/base'));

  @override
  void initState() {
    super.initState();
    final base = ref.read(spriteProvider).baseName;
    if (nameCtrl.text != base) nameCtrl.text = base;
  }

  @override
  Widget build(BuildContext context) {
    // A newly opened sheet suggests its own base name.
    ref.listen(spriteProvider.select((s) => s.source?.path), (prev, next) {
      if (prev != next) nameCtrl.text = ref.read(spriteProvider).baseName;
    });
    final st = ref.watch(spriteProvider);
    final ctrl = ref.read(spriteProvider.notifier);
    final src = st.source!;
    final (grid, _) = st.grid;
    final base = sanitizeBaseName(st.baseName);
    final names = grid == null ? const <String>[] : frameFileNames(base, grid.frameCount);
    final hasWs = ref.watch(activeWorkspaceProvider) != null;
    final delay = gifDelayForFps(st.fps);

    return NeonPanel(
      kicker: 'Output',
      title: 'Export frames',
      icon: Icons.save_alt,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: nameCtrl,
            style: J3Type.code,
            decoration: const InputDecoration(
              labelText: 'Base name',
              helperText: 'Frames are <base>_000.png, <base>_001.png...',
            ),
            onChanged: ctrl.setBaseName,
          ),
          const SizedBox(height: J3Space.sm),
          if (names.isNotEmpty)
            Text(
              names.length <= 3 ? names.join(', ') : '${names.first}, ${names[1]} ... ${names.last}',
              style: J3Type.codeSmall.copyWith(color: context.effects.accentText),
            ),
          const SizedBox(height: J3Space.md),
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              NeonButton(
                label: 'Export frames (ZIP)',
                icon: Icons.archive_outlined,
                onPressed: grid == null
                    ? null
                    : () => exportZip(
                        context,
                        ref,
                        toolId: _tool,
                        title: 'Slice ${grid.frameCount} frames to ZIP',
                        zipName: '${base}_frames.zip',
                        prepare: sliceTask(src.raster, grid, base),
                      ),
              ),
              NeonButton.secondary(
                label: 'Save to workspace folder',
                icon: Icons.create_new_folder_outlined,
                tooltip: hasWs ? 'Write the PNG frames into a folder of the active workspace' : 'No active workspace',
                onPressed: grid == null || !hasWs
                    ? null
                    : () => saveFilesToWorkspace(
                        context,
                        ref,
                        toolId: _tool,
                        title: 'Save ${grid.frameCount} frames',
                        prepare: sliceTask(src.raster, grid, base),
                      ),
              ),
            ],
          ),
          const SizedBox(height: J3Space.lg),
          Text('Animated GIF', style: J3Type.label.copyWith(color: context.effects.accentText)),
          const SizedBox(height: J3Space.xs),
          Text(
            'Delay $delay/100 s per frame (${(100 / delay).toStringAsFixed(1)} fps), loops forever. '
            'GIF has no partial transparency: frames are flattened onto the background.',
            style: J3Type.caption,
          ),
          const SizedBox(height: J3Space.sm),
          ColorChoiceField(
            label: 'GIF background',
            value: st.gifBackground,
            presets: backgroundPresets,
            onChanged: ctrl.setGifBackground,
          ),
          const SizedBox(height: J3Space.sm),
          Wrap(
            children: [
              NeonButton.secondary(
                label: 'Export animated GIF',
                icon: Icons.gif_box_outlined,
                onPressed: grid == null
                    ? null
                    : () => exportFile(
                        context,
                        ref,
                        toolId: _tool,
                        title: 'Encode ${grid.frameCount}-frame GIF',
                        fileName: '$base.gif',
                        mimeType: 'image/gif',
                        build: gifTask(src.raster, grid, st.fps, st.gifBackground),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SheetPreview extends ConsumerWidget {
  const _SheetPreview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(spriteProvider);
    final src = st.source!;
    final (grid, _) = st.grid;
    final fx = context.effects;
    return NeonPanel(
      kicker: 'Sheet',
      title: grid == null ? 'Grid invalid' : 'Grid overlay (${grid.frameCount} frames)',
      icon: Icons.grid_4x4,
      child: ImageViewport(
        png: src.previewPng,
        sourceWidth: src.raster.width,
        sourceHeight: src.raster.height,
        pixelArt: true,
        semanticLabel: 'Sprite sheet with frame grid',
        overlay: grid == null
            ? null
            : (context, scale) => IgnorePointer(
                child: CustomPaint(
                  painter: _GridPainter(grid: grid, scale: scale, current: st.frame, accent: fx.accentColor),
                ),
              ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.grid, required this.scale, required this.current, required this.accent});
  final SpriteGrid grid;
  final double scale;
  final int current;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final dim = Paint()..color = J3Colors.background.withValues(alpha: 0.6);
    final hatch = Paint()
      ..color = J3Colors.textMuted
      ..strokeWidth = 1;
    final labels = grid.cellCount <= 400 && grid.frameWidth * scale >= 18 && grid.frameHeight * scale >= 14;
    for (var i = 0; i < grid.cellCount; i++) {
      final f = grid.frame(i);
      final r = Rect.fromLTWH(f.x * scale, f.y * scale, f.width * scale, f.height * scale);
      if (i >= grid.frameCount) {
        canvas.drawRect(r, dim);
        canvas.drawLine(r.topLeft, r.bottomRight, hatch);
        canvas.drawLine(r.topRight, r.bottomLeft, hatch);
        continue;
      }
      if (i == current) canvas.drawRect(r, Paint()..color = accent.withValues(alpha: 0.18));
      canvas.drawRect(r.deflate(0.5), line..strokeWidth = i == current ? 2 : 1);
      if (labels) {
        final tp = TextPainter(
          text: TextSpan(
            text: '$i',
            style: J3Type.codeSmall.copyWith(fontSize: 10, color: J3Colors.text, height: 1),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final bg = Rect.fromLTWH(r.left + 1, r.top + 1, tp.width + 4, tp.height + 2);
        canvas.drawRect(bg, Paint()..color = J3Colors.background.withValues(alpha: 0.75));
        tp.paint(canvas, Offset(bg.left + 2, bg.top + 1));
        tp.dispose();
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.grid != grid || old.scale != scale || old.current != current || old.accent != accent;
}

class _AnimationPanel extends ConsumerStatefulWidget {
  const _AnimationPanel();

  @override
  ConsumerState<_AnimationPanel> createState() => _AnimationPanelState();
}

class _AnimationPanelState extends ConsumerState<_AnimationPanel> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  bool _playing = false;
  bool _autoplayChecked = false;
  int _startFrame = 0;
  int _frame = 0;
  double? _fpsDrag;

  @override
  void initState() {
    super.initState();
    _frame = ref.read(spriteProvider).frame;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_autoplayChecked) {
      _autoplayChecked = true;
      // Autoplay only when motion is allowed; reduced motion means manual
      // play/step only.
      if (!context.effects.reduceMotion && ref.read(spriteProvider).grid.$1 != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _play();
        });
      }
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  int get _count => ref.read(spriteProvider).grid.$1?.frameCount ?? 0;

  void _tick(Duration elapsed) {
    final st = ref.read(spriteProvider);
    final count = _count;
    if (count == 0) {
      _pause();
      return;
    }
    final steps = (elapsed.inMicroseconds * st.fps / 1000000).floor();
    var f = _startFrame + steps;
    if (st.loop) {
      f %= count;
    } else if (f >= count) {
      f = count - 1;
      setState(() => _frame = f);
      _pause();
      return;
    }
    if (f != _frame) setState(() => _frame = f);
  }

  void _play() {
    if (_count == 0) return;
    if (!ref.read(spriteProvider).loop && _frame >= _count - 1) _frame = 0;
    _startFrame = _frame;
    if (_ticker.isActive) _ticker.stop();
    _ticker.start();
    setState(() => _playing = true);
  }

  void _pause() {
    if (_ticker.isActive) _ticker.stop();
    if (mounted) setState(() => _playing = false);
    ref.read(spriteProvider.notifier).setFrame(_frame);
  }

  void _step(int d) {
    final count = _count;
    if (count == 0) return;
    if (_playing) _pause();
    setState(() => _frame = (_frame + d) % count < 0 ? count - 1 : (_frame + d) % count);
    ref.read(spriteProvider.notifier).setFrame(_frame);
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(spriteProvider);
    final ctrl = ref.read(spriteProvider.notifier);
    final (grid, error) = st.grid;
    final src = st.source!;
    final zoom = ref.draft<int>('$_tool/zoom', 4);
    final fx = context.effects;
    if (grid == null) {
      return NeonPanel(
        kicker: 'Animation',
        title: 'Preview unavailable',
        child: Text(error ?? 'Define a valid grid first.', style: J3Type.bodySecondary),
      );
    }
    if (_frame >= grid.frameCount) _frame = grid.frameCount - 1;
    final f = grid.frame(_frame);
    final fps = _fpsDrag?.round() ?? st.fps;

    final frameView = SizedBox(
      width: f.width * zoom.toDouble(),
      height: f.height * zoom.toDouble(),
      child: ClipRect(
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            const Positioned.fill(child: CustomPaint(painter: CheckerboardPainter())),
            Positioned(
              left: -f.x * zoom.toDouble(),
              top: -f.y * zoom.toDouble(),
              width: src.raster.width * zoom.toDouble(),
              height: src.raster.height * zoom.toDouble(),
              child: Image.memory(
                src.previewPng,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.none,
                gaplessPlayback: true,
                excludeFromSemantics: true,
              ),
            ),
            if (zoom >= 8)
              Positioned.fill(
                child: CustomPaint(
                  painter: PixelGridPainter(scale: zoom.toDouble(), color: J3Colors.background.withValues(alpha: 0.35)),
                ),
              ),
          ],
        ),
      ),
    );

    return NeonPanel(
      kicker: 'Animation',
      title: 'Frame ${_frame + 1} / ${grid.frameCount}',
      icon: Icons.movie_filter_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            image: true,
            label: 'Animation preview, frame ${_frame + 1} of ${grid.frameCount}',
            child: Container(
              height: 220,
              decoration: BoxDecoration(
                color: J3Colors.inputFill,
                borderRadius: J3Radius.small,
                border: Border.all(color: J3Colors.border),
              ),
              padding: const EdgeInsets.all(J3Space.sm),
              child: Center(
                child: FittedBox(fit: BoxFit.scaleDown, child: frameView),
              ),
            ),
          ),
          const SizedBox(height: J3Space.sm),
          Wrap(
            spacing: J3Space.xs,
            runSpacing: J3Space.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              NeonIconButton(icon: Icons.skip_previous, tooltip: 'Previous frame', onPressed: () => _step(-1)),
              NeonIconButton(
                icon: _playing ? Icons.pause : Icons.play_arrow,
                tooltip: _playing ? 'Pause' : 'Play',
                selected: _playing,
                onPressed: _playing ? _pause : _play,
              ),
              NeonIconButton(icon: Icons.skip_next, tooltip: 'Next frame', onPressed: () => _step(1)),
              NeonIconButton(
                icon: Icons.repeat,
                tooltip: st.loop ? 'Looping (tap to play once)' : 'Plays once (tap to loop)',
                selected: st.loop,
                onPressed: () => ctrl.setLoop(!st.loop),
              ),
              Text('${st.loop ? 'loop' : 'once'}  |  $fps fps', style: J3Type.codeSmall.copyWith(color: fx.accentText)),
            ],
          ),
          if (fx.reduceMotion)
            Padding(
              padding: const EdgeInsets.only(top: J3Space.xs),
              child: StatusLine(
                kind: StatusKind.info,
                text: 'Reduced motion: the animation does not autoplay. Use play or the step buttons.',
              ),
            ),
          const SizedBox(height: J3Space.sm),
          Text('Speed: $fps FPS', style: J3Type.caption),
          Slider(
            value: (_fpsDrag ?? st.fps.toDouble()).clamp(1, 60),
            min: 1,
            max: 60,
            divisions: 59,
            label: '$fps fps',
            semanticFormatterCallback: (v) => '${v.round()} frames per second',
            onChanged: (v) => setState(() => _fpsDrag = v),
            onChangeEnd: (v) {
              setState(() => _fpsDrag = null);
              ctrl.setFps(v.round());
              if (_playing) _play();
            },
          ),
          ChoiceRow<int>(
            label: 'Zoom (nearest neighbour)',
            options: const [1, 2, 4, 8, 16],
            selected: zoom,
            onSelected: (z) => ref.setDraft('$_tool/zoom', z),
            labelOf: (z) => '${z}x',
          ),
        ],
      ),
    );
  }
}
