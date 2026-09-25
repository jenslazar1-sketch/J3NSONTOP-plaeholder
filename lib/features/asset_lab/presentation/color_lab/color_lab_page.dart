import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/platform/file_access.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/widgets/widgets.dart';
import '../../data/palette_store.dart';
import '../../domain/color_model.dart';
import '../../domain/image_codec.dart';
import '../../domain/palette.dart';
import '../asset_actions.dart';
import '../widgets/checkerboard.dart';
import '../widgets/color_widgets.dart';
import '../widgets/hsv_picker.dart';
import '../widgets/image_viewport.dart';
import '../widgets/status_line.dart';
import 'color_controller.dart';

const String _tool = 'assets.color';

/// Color Lab: HSV picker, synced HEX/RGB/HSL/HSV inputs, WCAG contrast
/// checker, image eyedropper and a saved palette with exports.
class ColorLabPage extends ConsumerWidget {
  const ColorLabPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const ToolScaffold(
      toolId: _tool,
      inputs: [_PickerPanel(), _FormatsPanel()],
      results: [_ContrastPanel(), _EyedropperPanel(), _PalettePanel()],
    );
  }
}

Future<void> _copy(WidgetRef ref, String text, String what) async {
  await ref.read(fileAccessProvider).copyText(text);
  ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Copied $what: $text');
}

class _PickerPanel extends ConsumerWidget {
  const _PickerPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(colorLabProvider);
    final ctrl = ref.read(colorLabProvider.notifier);
    final c = st.color;
    final hex = ColorFormat.hex(c, order: st.order);
    return NeonPanel(
      kicker: 'Picker',
      title: hex,
      icon: Icons.colorize_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 56,
            decoration: BoxDecoration(
              borderRadius: J3Radius.small,
              border: Border.all(color: J3Colors.borderStrong),
            ),
            clipBehavior: Clip.antiAlias,
            child: CustomPaint(
              painter: const CheckerboardPainter(),
              child: ColoredBox(
                color: toFlutterColor(c),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: J3Space.sm, vertical: 2),
                    color: J3Colors.background.withValues(alpha: 0.75),
                    child: Text(hex, style: J3Type.code),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: J3Space.md),
          HsvPicker(value: st.hsv, onChanged: ctrl.setHsv),
          const SizedBox(height: J3Space.md),
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              NeonButton(
                label: 'Add to palette',
                icon: Icons.bookmark_add_outlined,
                onPressed: () {
                  try {
                    ref.read(paletteProvider.notifier).add(c);
                  } on StateError catch (e) {
                    ref.read(activityProvider.notifier).notify(NoticeKind.warning, e.message);
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FormatsPanel extends ConsumerWidget {
  const _FormatsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(colorLabProvider);
    final ctrl = ref.read(colorLabProvider.notifier);
    final c = st.color;
    return NeonPanel(
      kicker: 'Values',
      title: 'Formats',
      icon: Icons.tag,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChoiceRow<HexAlphaOrder>(
            label: '8-digit HEX order',
            options: HexAlphaOrder.values,
            selected: st.order,
            onSelected: ctrl.setOrder,
            labelOf: (o) => o.label,
          ),
          const SizedBox(height: J3Space.xs),
          Text(
            'HEX accepts #RGB, #RGBA, #RRGGBB and 8 digits in the order above; 0xAARRGGBB is always alpha-first.',
            style: J3Type.caption,
          ),
          const SizedBox(height: J3Space.md),
          _FormatField(
            key: const ValueKey('fmt-hex'),
            label: 'HEX',
            value: c,
            format: (v) => ColorFormat.hex(v, order: st.order),
            parse: (t) => ColorFormat.parseHex(t, order: st.order),
            onParsed: ctrl.setColor,
          ),
          _FormatField(
            key: const ValueKey('fmt-rgb'),
            label: 'RGB(A)',
            value: c,
            format: ColorFormat.rgb,
            parse: ColorFormat.parseRgb,
            onParsed: ctrl.setColor,
          ),
          _FormatField(
            key: const ValueKey('fmt-hsl'),
            label: 'HSL(A)',
            value: c,
            format: ColorFormat.hsl,
            parse: ColorFormat.parseHsl,
            onParsed: ctrl.setColor,
          ),
          _FormatField(
            key: const ValueKey('fmt-hsv'),
            label: 'HSV(A)',
            value: c,
            format: ColorFormat.hsv,
            parse: ColorFormat.parseHsv,
            onParsed: ctrl.setColor,
          ),
          const SizedBox(height: J3Space.xs),
          Text(
            'Flutter: Color(0x${c.argb32.toRadixString(16).padLeft(8, '0').toUpperCase()})',
            style: J3Type.codeSmall,
          ),
        ],
      ),
    );
  }
}

class _FormatField extends ConsumerStatefulWidget {
  const _FormatField({
    super.key,
    required this.label,
    required this.value,
    required this.format,
    required this.parse,
    required this.onParsed,
  });

  final String label;
  final Rgba value;
  final String Function(Rgba) format;
  final Rgba Function(String) parse;
  final ValueChanged<Rgba> onParsed;

  @override
  ConsumerState<_FormatField> createState() => _FormatFieldState();
}

class _FormatFieldState extends ConsumerState<_FormatField> {
  late final TextEditingController _c = TextEditingController(text: widget.format(widget.value));
  String? _error;

  @override
  void didUpdateWidget(_FormatField old) {
    super.didUpdateWidget(old);
    final text = widget.format(widget.value);
    if (text == _c.text) return;
    Rgba? typed;
    try {
      typed = widget.parse(_c.text);
    } on FormatException {
      typed = null;
    }
    // Keep what the user is typing when it already denotes this colour.
    if (typed != widget.value || _error != null) {
      _c.text = text;
      _error = null;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _changed(String v) {
    try {
      final c = widget.parse(v);
      setState(() => _error = null);
      widget.onParsed(c);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: J3Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _c,
              style: J3Type.code,
              onChanged: _changed,
              decoration: InputDecoration(labelText: widget.label, errorText: _error, errorMaxLines: 3),
            ),
          ),
          NeonIconButton(
            icon: Icons.copy_rounded,
            tooltip: 'Copy ${widget.label}',
            onPressed: () => _copy(ref, widget.format(widget.value), widget.label),
          ),
        ],
      ),
    );
  }
}

class _ContrastPanel extends ConsumerWidget {
  const _ContrastPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(colorLabProvider);
    final ctrl = ref.read(colorLabProvider.notifier);
    final fg = st.color;
    final bg = st.background;
    final ratio = ColorMath.contrastRatio(fg, bg);
    final shown = fg.over(bg);
    return NeonPanel(
      kicker: 'WCAG 2.x',
      title: 'Contrast ${ratio.toStringAsFixed(2)} : 1',
      icon: Icons.contrast,
      actions: [NeonIconButton(icon: Icons.swap_vert, tooltip: 'Swap foreground and background', onPressed: ctrl.swap)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ColorChoiceField(label: 'Background', value: bg, presets: backgroundPresets, onChanged: ctrl.setBackground),
          const SizedBox(height: J3Space.md),
          Container(
            padding: const EdgeInsets.all(J3Space.md),
            decoration: BoxDecoration(
              color: toFlutterColor(bg),
              borderRadius: J3Radius.small,
              border: Border.all(color: J3Colors.borderStrong),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Large text 24px', style: J3Type.headline.copyWith(color: toFlutterColor(shown))),
                const SizedBox(height: J3Space.xs),
                Text(
                  'Normal body text at 15px: the quick brown fox.',
                  style: J3Type.body.copyWith(color: toFlutterColor(shown)),
                ),
              ],
            ),
          ),
          const SizedBox(height: J3Space.md),
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              for (final level in WcagLevel.values)
                StatusBadge(
                  kind: level.passes(ratio) ? StatusKind.success : StatusKind.error,
                  text: '${level.grade} ${level.scope}: ${level.passes(ratio) ? 'PASS' : 'FAIL'} (${level.minRatio}:1)',
                ),
            ],
          ),
          if (!fg.isOpaque) ...[
            const SizedBox(height: J3Space.sm),
            StatusLine(
              kind: StatusKind.info,
              text:
                  'The foreground is translucent: it is blended over the background (${ColorFormat.hex(shown)}) first.',
            ),
          ],
        ],
      ),
    );
  }
}

class _EyedropperPanel extends ConsumerWidget {
  const _EyedropperPanel();

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final input = await pickImage(context, ref, decodableImageExtensions, title: 'Open image for the eyedropper');
    if (input == null) return;
    await ref.read(colorLabProvider.notifier).openImage(input);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(colorLabProvider);
    final ctrl = ref.read(colorLabProvider.notifier);
    final img = st.eyedropper;
    final fx = context.effects;
    void pickAt(Offset local, double scale) {
      final r = img!.decoded.raster;
      final x = (local.dx / scale).floor().clamp(0, r.width - 1);
      final y = (local.dy / scale).floor().clamp(0, r.height - 1);
      ctrl.pick(x, y);
    }

    return NeonPanel(
      kicker: 'Eyedropper',
      title: img?.name ?? 'Pick from an image',
      icon: Icons.colorize,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            children: [
              NeonButton.secondary(
                label: img == null ? 'Load image' : 'Load another',
                icon: Icons.image_search,
                busy: st.loadingImage,
                onPressed: () => _open(context, ref),
              ),
            ],
          ),
          if (st.imageError != null) ...[
            const SizedBox(height: J3Space.sm),
            ErrorPanel(title: 'Cannot load image', error: st.imageError!),
          ],
          if (img != null) ...[
            const SizedBox(height: J3Space.sm),
            ImageViewport(
              png: img.decoded.previewPng,
              sourceWidth: img.decoded.raster.width,
              sourceHeight: img.decoded.raster.height,
              height: 240,
              semanticLabel: 'Eyedropper image; tap a pixel to pick its colour',
              overlay: (context, scale) => MouseRegion(
                cursor: SystemMouseCursors.precise,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => pickAt(d.localPosition, scale),
                  onPanUpdate: (d) => pickAt(d.localPosition, scale),
                  child: CustomPaint(painter: _PickMarker(st.lastPick, scale, fx.accentColor)),
                ),
              ),
            ),
            const SizedBox(height: J3Space.xs),
            Text(
              st.lastPick == null
                  ? 'Tap or drag on the image to sample a pixel (alpha included).'
                  : 'Picked (${st.lastPick!.$1}, ${st.lastPick!.$2}) -> ${ColorFormat.hex(st.color, order: st.order)}',
              style: J3Type.codeSmall.copyWith(color: st.lastPick == null ? null : fx.accentText),
            ),
          ],
        ],
      ),
    );
  }
}

class _PickMarker extends CustomPainter {
  _PickMarker(this.pick, this.scale, this.accent);
  final (int, int)? pick;
  final double scale;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final p = pick;
    if (p == null) return;
    final r = Rect.fromLTWH(p.$1 * scale, p.$2 * scale, scale, scale).inflate(scale < 6 ? 4 : 1);
    canvas.drawRect(
      r,
      Paint()
        ..color = J3Colors.background
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawRect(
      r,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_PickMarker old) => old.pick != pick || old.scale != scale || old.accent != accent;
}

class _PalettePanel extends ConsumerWidget {
  const _PalettePanel();

  Future<void> _rename(BuildContext context, WidgetRef ref, Swatch s) async {
    final name = await showJ3TextInput(
      context,
      title: 'Rename colour',
      initial: s.name,
      validator: (v) => v.trim().isEmpty ? 'Enter a name' : (v.length > 60 ? 'Keep it under 60 characters' : null),
    );
    if (name != null) ref.read(paletteProvider.notifier).rename(s.id, name);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(paletteProvider);
    final ctrl = ref.read(paletteProvider.notifier);
    final lab = ref.read(colorLabProvider.notifier);
    final order = ref.watch(colorLabProvider.select((s) => s.order));
    final format = ref.draft<PaletteExportFormat>('$_tool/exportFormat', PaletteExportFormat.json);
    final list = palette.swatches;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeonPanel(
          kicker: 'Saved',
          title: 'Palette (${list.length})',
          icon: Icons.palette_outlined,
          child: list.isEmpty
              ? const EmptyState(
                  title: 'Palette is empty',
                  message: 'Use "Add to palette" to save colours. The palette is stored on this device.',
                  glyph: '[ # # # ]',
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < list.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: J3Space.xs),
                        child: Row(
                          children: [
                            Tooltip(
                              message: 'Use ${list[i].name}',
                              child: InkWell(
                                onTap: () => lab.setColor(list[i].color),
                                borderRadius: J3Radius.small,
                                child: SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: Center(child: ColorSwatchBox(color: list[i].color, size: 32)),
                                ),
                              ),
                            ),
                            const SizedBox(width: J3Space.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(list[i].name, style: J3Type.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  Text(ColorFormat.hex(list[i].color, order: order), style: J3Type.codeSmall),
                                ],
                              ),
                            ),
                            PopupMenuButton<String>(
                              tooltip: 'Actions for ${list[i].name}',
                              icon: const Icon(Icons.more_vert),
                              onSelected: (a) {
                                switch (a) {
                                  case 'use':
                                    lab.setColor(list[i].color);
                                  case 'bg':
                                    lab.setBackground(list[i].color);
                                  case 'rename':
                                    _rename(context, ref, list[i]);
                                  case 'up':
                                    ctrl.move(i, i - 1);
                                  case 'down':
                                    ctrl.move(i, i + 1);
                                  case 'remove':
                                    ctrl.remove(list[i].id);
                                }
                              },
                              itemBuilder: (_) => [
                                const PopupMenuItem(value: 'use', child: Text('Use as colour')),
                                const PopupMenuItem(value: 'bg', child: Text('Use as contrast background')),
                                const PopupMenuItem(value: 'rename', child: Text('Rename...')),
                                PopupMenuItem(value: 'up', enabled: i > 0, child: const Text('Move up')),
                                PopupMenuItem(
                                  value: 'down',
                                  enabled: i < list.length - 1,
                                  child: const Text('Move down'),
                                ),
                                const PopupMenuItem(value: 'remove', child: Text('Remove')),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        if (list.isNotEmpty) ...[
          const SizedBox(height: J3Space.lg),
          ChoiceRow<PaletteExportFormat>(
            label: 'Export format',
            options: PaletteExportFormat.values,
            selected: format,
            onSelected: (f) => ref.setDraft('$_tool/exportFormat', f),
            labelOf: (f) => f.label,
          ),
          const SizedBox(height: J3Space.sm),
          ResultPanel(
            text: PaletteExport.render(list, format, order: order),
            title: format.fileName,
            kicker: 'Palette export',
            fileName: format.fileName,
            mimeType: format.mimeType,
            toolId: _tool,
            maxHeight: 240,
          ),
        ],
      ],
    );
  }
}
