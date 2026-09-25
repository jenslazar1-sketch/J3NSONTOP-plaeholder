import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../data/asset_worker.dart';
import '../../domain/color_model.dart';
import '../../domain/image_codec.dart';
import '../../domain/image_ops.dart';
import '../asset_actions.dart';
import '../widgets/color_widgets.dart';
import '../widgets/crop_overlay.dart';
import '../widgets/image_viewport.dart';
import '../widgets/panel_switch.dart';
import '../widgets/status_line.dart';
import 'studio_controller.dart';

const String _tool = 'assets.image';

/// Image Studio: open an image, inspect metadata, build a non-destructive
/// operation pipeline (resize, crop, rotate, flip) with undo/redo and export
/// to any encodable format without touching the original.
class ImageStudioPage extends ConsumerWidget {
  const ImageStudioPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSource = ref.watch(studioProvider.select((s) => s.source != null));
    // Source + preview first so phones see the image right after opening it;
    // on wide screens the pipeline and export sit in the right column.
    return ToolScaffold(
      toolId: _tool,
      inputs: [const _SourcePanel(), if (hasSource) const _PreviewPanel()],
      results: hasSource ? const [_OpsPanel(), _ExportPanel()] : const [_PreviewPanel()],
    );
  }
}

Future<void> _open(BuildContext context, WidgetRef ref) async {
  final input = await pickImage(context, ref, decodableImageExtensions);
  if (input == null) return;
  await ref.read(studioProvider.notifier).open(input);
}

class _SourcePanel extends ConsumerWidget {
  const _SourcePanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(studioProvider);
    final src = s.source;
    final m = src?.decoded.metadata;
    return NeonPanel(
      kicker: 'Input',
      title: src == null ? 'Source image' : src.name,
      icon: Icons.image_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              NeonButton(
                label: src == null ? 'Open image' : 'Open another',
                icon: Icons.folder_open,
                busy: s.loading,
                onPressed: () => _open(context, ref),
              ),
            ],
          ),
          const SizedBox(height: J3Space.sm),
          Text(
            'Reads ${decodableImageExtensions.map((e) => e.toUpperCase()).toSet().join(' ')}. '
            'The original is never modified.',
            style: J3Type.caption,
          ),
          if (s.loadError != null) ...[
            const SizedBox(height: J3Space.md),
            ErrorPanel(
              title: 'Cannot open image',
              error: s.loadError!,
              hint: 'Check that the file is a complete image in a supported format.',
            ),
          ],
          if (m != null) ...[
            const SizedBox(height: J3Space.md),
            KeyValueTable(
              keyWidth: 110,
              rows: [
                ('Format', m.formatName + (m.indexed ? ' (indexed palette)' : '')),
                ('Dimensions', '${m.width} x ${m.height} px'),
                ('Channels', '${m.channels} (${m.hasAlpha ? 'has alpha' : 'no alpha'})'),
                ('Bits/channel', '${m.bitsPerChannel}'),
                ('Frames', '${m.frameCount}'),
                ('File size', '${Fmt.bytes(m.fileSize)} (${m.fileSize} B)'),
                ('Location', src!.fromWorkspace ? 'workspace: ${src.label}' : 'imported copy (original untouched)'),
              ],
            ),
            if (m.exif.isNotEmpty) ...[
              const SizedBox(height: J3Space.sm),
              Text('EXIF', style: J3Type.label.copyWith(color: context.effects.accentText)),
              KeyValueTable(keyWidth: 110, rows: m.exif),
            ],
            for (final n in m.notes) ...[
              const SizedBox(height: J3Space.xs),
              StatusLine(kind: StatusKind.info, text: n),
            ],
          ],
        ],
      ),
    );
  }
}

enum _OpKind {
  resize('Resize', Icons.photo_size_select_large),
  crop('Crop', Icons.crop),
  rotate('Rotate', Icons.rotate_right),
  flip('Flip', Icons.flip);

  const _OpKind(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _OpsPanel extends ConsumerStatefulWidget {
  const _OpsPanel();

  @override
  ConsumerState<_OpsPanel> createState() => _OpsPanelState();
}

class _OpsPanelState extends ConsumerState<_OpsPanel> {
  String? _formError;

  TextEditingController _t(String field) => ref.read(draftTextProvider('$_tool/$field'));

  @override
  void initState() {
    super.initState();
    final size = ref.read(studioProvider).currentSize;
    if (size != null && _t('resize.w').text.isEmpty) _fillResize(size);
    final crop = ref.read(studioProvider).crop.rect;
    if (_t('crop.w').text.isEmpty) _fillCrop(crop);
  }

  void _fillResize(PixelSize size) {
    _t('resize.w').text = '${size.width}';
    _t('resize.h').text = '${size.height}';
    _t('resize.pct').text = '100';
  }

  void _fillCrop(CropRect r) {
    void put(String f, int v) {
      final c = _t(f);
      if (int.tryParse(c.text) != v) c.text = '$v';
    }

    put('crop.x', r.x);
    put('crop.y', r.y);
    put('crop.w', r.width);
    put('crop.h', r.height);
  }

  int? _int(String field) => int.tryParse(_t(field).text.trim());

  void _onResizeEdited(String changed) {
    final size = ref.read(studioProvider).currentSize;
    if (size == null || !ref.read(draftValueProvider('$_tool/resize.lock')).asBool(true)) return;
    if (changed == 'w') {
      final w = _int('resize.w');
      if (w != null && w > 0) _t('resize.h').text = '${aspectLockedSide(w, size.width, size.height)}';
    } else {
      final h = _int('resize.h');
      if (h != null && h > 0) _t('resize.w').text = '${aspectLockedSide(h, size.height, size.width)}';
    }
  }

  void _onPercent(String v) {
    final size = ref.read(studioProvider).currentSize;
    final pct = double.tryParse(v.trim());
    if (size == null || pct == null || pct <= 0) return;
    final out = scaledByPercent(size, pct);
    _t('resize.w').text = '${out.width}';
    _t('resize.h').text = '${out.height}';
  }

  void _add(ImageOp op) {
    final size = ref.read(studioProvider).currentSize;
    final err = size == null ? 'Open an image first.' : op.validate(size);
    setState(() => _formError = err);
    if (err == null) ref.read(studioProvider.notifier).addOp(op);
  }

  void _addResize() {
    final w = _int('resize.w'), h = _int('resize.h');
    if (w == null || h == null) {
      setState(() => _formError = 'Resize: enter whole numbers for width and height.');
      return;
    }
    final interp = ref.read(draftValueProvider('$_tool/resize.interp'));
    _add(ResizeOp(w, h, interp is ResizeInterpolation ? interp : ResizeInterpolation.linear));
  }

  void _cropFieldsChanged() {
    final x = _int('crop.x'), y = _int('crop.y'), w = _int('crop.w'), h = _int('crop.h');
    final size = ref.read(studioProvider).currentSize;
    if (x == null || y == null || w == null || h == null || size == null) {
      setState(() => _formError = 'Crop: enter whole numbers for X, Y, width and height.');
      return;
    }
    final err = CropOp.check(x, y, w, h, size);
    setState(() => _formError = err);
    if (err == null) ref.read(studioProvider.notifier).setCropRect(CropRect(x, y, w, h));
  }

  void _addCrop() {
    final x = _int('crop.x'), y = _int('crop.y'), w = _int('crop.w'), h = _int('crop.h');
    if (x == null || y == null || w == null || h == null) {
      setState(() => _formError = 'Crop: enter whole numbers for X, Y, width and height.');
      return;
    }
    _add(CropOp(x, y, w, h));
  }

  void _addRotate() {
    final raw = _t('rotate.deg').text.trim().replaceAll('°', '');
    final d = double.tryParse(raw);
    if (d == null || d.isNaN || d.isInfinite) {
      setState(() => _formError = 'Rotate: enter an angle in degrees, e.g. 15 or -7.5.');
      return;
    }
    if (d.abs() > 360) {
      setState(() => _formError = 'Rotate: use an angle between -360 and 360.');
      return;
    }
    _add(RotateOp(d));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(studioProvider);
    final ctrl = ref.read(studioProvider.notifier);
    ref.listen(studioProvider.select((s) => s.currentSize), (prev, next) {
      if (next != null && next != prev) _fillResize(next);
    });
    ref.listen(studioProvider.select((s) => s.crop.rect), (prev, next) {
      if (prev != next) _fillCrop(next);
    });
    final kind = ref.draft<_OpKind>('$_tool/opKind', _OpKind.resize);
    final lock = ref.watch(draftValueProvider('$_tool/resize.lock')).asBool(true);
    final interp = ref.draft<ResizeInterpolation>('$_tool/resize.interp', ResizeInterpolation.linear);
    final plan = s.plan!;
    final size = s.currentSize!;

    final form = switch (kind) {
      _OpKind.resize => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              NumberField(
                controller: _t('resize.w'),
                label: 'Width px',
                min: 1,
                max: maxOutputSide,
                width: 120,
                onChanged: (_) => _onResizeEdited('w'),
              ),
              NeonIconButton(
                icon: lock ? Icons.link : Icons.link_off,
                tooltip: lock ? 'Aspect ratio locked (tap to unlock)' : 'Aspect ratio unlocked (tap to lock)',
                selected: lock,
                onPressed: () => ref.setDraft('$_tool/resize.lock', !lock),
              ),
              NumberField(
                controller: _t('resize.h'),
                label: 'Height px',
                min: 1,
                max: maxOutputSide,
                width: 120,
                onChanged: (_) => _onResizeEdited('h'),
              ),
              NumberField(
                controller: _t('resize.pct'),
                label: 'Percent',
                min: 1,
                max: 1000,
                allowDecimal: true,
                width: 100,
                onChanged: _onPercent,
              ),
            ],
          ),
          const SizedBox(height: J3Space.sm),
          ChoiceRow<ResizeInterpolation>(
            label: 'Interpolation: ${interp.hint}',
            options: ResizeInterpolation.values,
            selected: interp,
            onSelected: (v) => ref.setDraft('$_tool/resize.interp', v),
            labelOf: (v) => v.label,
          ),
          const SizedBox(height: J3Space.md),
          NeonButton.secondary(label: 'Add resize', icon: Icons.add, onPressed: _addResize),
        ],
      ),
      _OpKind.crop => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Current image: ${size.width} x ${size.height} px', style: J3Type.caption),
          const SizedBox(height: J3Space.sm),
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              for (final (f, l) in const [('crop.x', 'X'), ('crop.y', 'Y'), ('crop.w', 'Width'), ('crop.h', 'Height')])
                NumberField(controller: _t(f), label: l, min: 0, width: 96, onChanged: (_) => _cropFieldsChanged()),
            ],
          ),
          const SizedBox(height: J3Space.sm),
          ChoiceRow<CropAspect>(
            label: 'Aspect',
            options: CropAspect.values,
            selected: s.crop.aspect,
            onSelected: ctrl.setCropAspect,
            labelOf: (a) => a.label,
          ),
          const SizedBox(height: J3Space.md),
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              s.crop.active
                  ? NeonButton.ghost(label: 'Stop drawing', icon: Icons.close, onPressed: ctrl.cancelCrop)
                  : NeonButton.ghost(label: 'Draw on preview', icon: Icons.highlight_alt, onPressed: ctrl.startCrop),
              NeonButton.secondary(label: 'Add crop', icon: Icons.add, onPressed: _addCrop),
            ],
          ),
        ],
      ),
      _OpKind.rotate => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              for (final d in const [90, 180, 270])
                NeonButton.secondary(
                  label: '$d°',
                  icon: d == 270 ? Icons.rotate_left : Icons.rotate_right,
                  tooltip: 'Rotate $d° clockwise (lossless)',
                  onPressed: () => _add(RotateOp(d.toDouble())),
                ),
            ],
          ),
          const SizedBox(height: J3Space.md),
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              NumberField(
                controller: _t('rotate.deg'),
                label: 'Degrees',
                min: -360,
                max: 360,
                allowDecimal: true,
                width: 110,
              ),
              NeonButton.secondary(label: 'Rotate', icon: Icons.add, onPressed: _addRotate),
            ],
          ),
          const SizedBox(height: J3Space.xs),
          Text(
            'Arbitrary angles expand the canvas; new corners are transparent (flattened for JPEG/GIF).',
            style: J3Type.caption,
          ),
        ],
      ),
      _OpKind.flip => Wrap(
        spacing: J3Space.sm,
        runSpacing: J3Space.sm,
        children: [
          NeonButton.secondary(
            label: 'Flip horizontal',
            icon: Icons.swap_horiz,
            onPressed: () => _add(const FlipOp(FlipAxis.horizontal)),
          ),
          NeonButton.secondary(
            label: 'Flip vertical',
            icon: Icons.swap_vert,
            onPressed: () => _add(const FlipOp(FlipAxis.vertical)),
          ),
        ],
      ),
    };

    return NeonPanel(
      kicker: 'Pipeline',
      title: 'Operations',
      icon: Icons.layers_outlined,
      actions: [
        NeonIconButton(icon: Icons.undo, tooltip: 'Undo', onPressed: s.history.canUndo ? ctrl.undo : null),
        NeonIconButton(icon: Icons.redo, tooltip: 'Redo', onPressed: s.history.canRedo ? ctrl.redo : null),
        NeonIconButton(
          icon: Icons.restart_alt,
          tooltip: 'Reset (remove all operations)',
          onPressed: s.history.ops.isEmpty ? null : ctrl.reset,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChoiceRow<_OpKind>(
            label: 'Add an operation',
            options: _OpKind.values,
            selected: kind,
            onSelected: (k) {
              setState(() => _formError = null);
              ref.setDraft('$_tool/opKind', k);
              if (k != _OpKind.crop && s.crop.active) ctrl.cancelCrop();
            },
            labelOf: (k) => k.label,
          ),
          const SizedBox(height: J3Space.md),
          form,
          if (_formError != null) ...[
            const SizedBox(height: J3Space.sm),
            StatusLine(kind: StatusKind.error, text: _formError!),
          ],
          const SizedBox(height: J3Space.lg),
          const Divider(),
          const SizedBox(height: J3Space.sm),
          if (s.history.ops.isEmpty)
            Text('No operations yet: the export equals the source.', style: J3Type.caption)
          else
            for (var i = 0; i < s.history.ops.length; i++)
              _OpRow(
                index: i,
                op: s.history.ops[i],
                count: s.history.ops.length,
                error: plan.errorIndex == i ? plan.error : null,
                skipped: plan.errorIndex != null && i > plan.errorIndex!,
                outSize: i + 1 < plan.sizes.length ? plan.sizes[i + 1] : null,
              ),
        ],
      ),
    );
  }
}

extension on Object? {
  bool asBool(bool fallback) {
    final v = this;
    return v is bool ? v : fallback;
  }
}

class _OpRow extends ConsumerWidget {
  const _OpRow({
    required this.index,
    required this.op,
    required this.count,
    required this.error,
    required this.skipped,
    required this.outSize,
  });
  final int index;
  final ImageOp op;
  final int count;
  final String? error;
  final bool skipped;
  final PixelSize? outSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(studioProvider.notifier);
    final fx = context.effects;
    return Padding(
      padding: const EdgeInsets.only(bottom: J3Space.xs),
      child: Container(
        padding: const EdgeInsets.only(left: J3Space.sm),
        decoration: BoxDecoration(
          color: J3Colors.surfaceRaised,
          borderRadius: J3Radius.small,
          border: Border.all(color: error != null ? J3Colors.error : J3Colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('${index + 1}'.padLeft(2, '0'), style: J3Type.codeSmall.copyWith(color: fx.accentText)),
                const SizedBox(width: J3Space.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(op.label, style: J3Type.body.copyWith(color: skipped ? J3Colors.textMuted : null)),
                      if (outSize != null)
                        Text('-> ${outSize!.width} x ${outSize!.height}', style: J3Type.codeSmall)
                      else if (skipped)
                        Text('skipped (after an invalid step)', style: J3Type.caption),
                    ],
                  ),
                ),
                NeonIconButton(
                  icon: Icons.arrow_upward,
                  tooltip: 'Move up',
                  onPressed: index == 0 ? null : () => ctrl.moveOp(index, index - 1),
                ),
                NeonIconButton(
                  icon: Icons.arrow_downward,
                  tooltip: 'Move down',
                  onPressed: index == count - 1 ? null : () => ctrl.moveOp(index, index + 1),
                ),
                NeonIconButton(
                  icon: Icons.delete_outline,
                  tooltip: 'Remove step',
                  onPressed: () => ctrl.removeOp(index),
                ),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, J3Space.sm, J3Space.sm),
                child: StatusLine(kind: StatusKind.error, text: error!),
              ),
          ],
        ),
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
  double? _quality;
  String? _savedNote;
  late final TextEditingController _name = ref.read(draftTextProvider('$_tool/outputName'));

  @override
  void initState() {
    super.initState();
    final s = ref.read(studioProvider);
    if (s.customName == null || _name.text.isEmpty) _name.text = s.outputName;
  }

  Future<void> _saveNextToOriginal() async {
    final s = ref.read(studioProvider);
    final src = s.source;
    final bytes = s.output?.encoded?.bytes;
    final ws = ref.read(activeWorkspaceProvider);
    if (src == null || bytes == null || ws == null) return;
    final activity = ref.read(activityProvider.notifier);
    final worker = ref.read(assetWorkerProvider);
    final name = s.outputName;
    try {
      final written = await activity.run<List<String>>(
        toolId: _tool,
        title: 'Save $name next to the original',
        workspaceId: ws.id,
        body: (op) async {
          final paths = await worker.run(writeNewFilesTask(ws.rootPath, p.dirname(src.path), [(name, bytes)]));
          final rel = [for (final x in paths) p.relative(x, from: ws.rootPath).replaceAll(r'\', '/')];
          op.succeed('Saved ${rel.first}', counts: {'bytes': bytes.length}, details: rel);
          return rel;
        },
      );
      if (mounted) setState(() => _savedNote = 'Saved as ${written.first} (original untouched).');
    } catch (_) {
      // The failure is recorded and shown as a toast by the activity log.
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(studioProvider);
    final ctrl = ref.read(studioProvider.notifier);
    final ex = s.export;
    final out = s.output;
    final src = s.source!;
    final enc = out?.encoded;
    final transparent = out?.raster.usesTransparency ?? src.decoded.raster.usesTransparency;
    // Refresh the suggested name when the source or the format changes.
    ref.listen(studioProvider.select((s) => (s.source?.path, s.export.format)), (prev, next) {
      if (prev != next) _name.text = ref.read(studioProvider).outputName;
    });
    final lossy = ex.format == ExportFormat.jpeg || (ex.format == ExportFormat.webp && !ex.webpLossless);
    final canSaveBeside = src.fromWorkspace && ref.watch(activeWorkspaceProvider) != null;

    return NeonPanel(
      kicker: 'Output',
      title: 'Export',
      icon: Icons.save_alt,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChoiceRow<ExportFormat>(
            label: 'Format',
            options: ExportFormat.values,
            selected: ex.format,
            onSelected: (f) => ctrl.setExport(ex.copyWith(format: f)),
            labelOf: (f) => f.label,
          ),
          if (ex.format == ExportFormat.webp) ...[
            const SizedBox(height: J3Space.sm),
            PanelSwitch(
              label: 'Lossless WebP',
              description: 'Exact pixels (VP8L). Turn off for smaller lossy files.',
              value: ex.webpLossless,
              onChanged: (v) => ctrl.setExport(ex.copyWith(webpLossless: v)),
            ),
          ],
          if (lossy) ...[
            const SizedBox(height: J3Space.sm),
            Text('Quality: ${(_quality ?? ex.quality.toDouble()).round()}', style: J3Type.caption),
            Slider(
              value: _quality ?? ex.quality.toDouble(),
              min: 1,
              max: 100,
              divisions: 99,
              label: '${(_quality ?? ex.quality.toDouble()).round()}',
              semanticFormatterCallback: (v) => 'Quality ${v.round()}',
              onChanged: (v) => setState(() => _quality = v),
              onChangeEnd: (v) {
                setState(() => _quality = null);
                ctrl.setExport(ex.copyWith(quality: v.round()));
              },
            ),
          ],
          if (!ex.format.alpha) ...[
            const SizedBox(height: J3Space.sm),
            ColorChoiceField(
              label: 'Flatten onto',
              value: ex.background,
              presets: backgroundPresets,
              onChanged: (c) => ctrl.setExport(ex.copyWith(background: c)),
            ),
            if (transparent) ...[
              const SizedBox(height: J3Space.sm),
              StatusBanner(
                kind: StatusKind.warning,
                title: '${ex.format.label} has no transparency',
                message:
                    'Transparent and semi-transparent pixels will be flattened onto '
                    '${ColorFormat.hex(ex.background)}. Choose PNG, WebP, TGA, TIFF or BMP to keep alpha.',
              ),
            ],
          ],
          if (ex.format.maxSide != null) ...[
            const SizedBox(height: J3Space.xs),
            Text(
              '${ex.format.label} supports up to ${ex.format.maxSide} x ${ex.format.maxSide} px.',
              style: J3Type.caption,
            ),
          ],
          const SizedBox(height: J3Space.md),
          TextField(
            controller: _name,
            style: J3Type.code,
            decoration: const InputDecoration(labelText: 'File name', helperText: 'Default: <name>_edited.<ext>'),
            onChanged: (v) => ctrl.setCustomName(v.trim().isEmpty ? null : v),
          ),
          const SizedBox(height: J3Space.md),
          if (s.rendering)
            const LoadingState(label: 'Rendering output...')
          else if (out?.encodeError != null)
            StatusBanner(kind: StatusKind.error, title: 'Cannot export yet', message: out!.encodeError)
          else if (enc != null)
            KeyValueTable(
              keyWidth: 110,
              rows: [
                ('Result', '${enc.width} x ${enc.height} px'),
                ('File size', '${Fmt.bytes(enc.bytes.length)} (${enc.bytes.length} B)'),
                (
                  'Alpha',
                  enc.flattened ? 'flattened onto ${ColorFormat.hex(ex.background)}' : (enc.hasAlpha ? 'kept' : 'none'),
                ),
                ('Name', s.outputName),
              ],
            ),
          const SizedBox(height: J3Space.md),
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              NeonButton(
                label: 'Save / export',
                icon: Icons.save_alt,
                onPressed: enc == null || s.rendering
                    ? null
                    : () => saveOutput(
                        context,
                        ref,
                        suggestedName: s.outputName,
                        bytes: enc.bytes,
                        mimeType: ex.format.mimeType,
                        toolId: _tool,
                      ),
              ),
              if (canSaveBeside)
                NeonButton.secondary(
                  label: 'Save next to original',
                  icon: Icons.drive_file_rename_outline,
                  tooltip: 'Writes a new file in the same workspace folder; never replaces the original',
                  onPressed: enc == null || s.rendering ? null : _saveNextToOriginal,
                ),
            ],
          ),
          if (_savedNote != null) ...[
            const SizedBox(height: J3Space.sm),
            StatusLine(kind: StatusKind.success, text: _savedNote!),
          ],
        ],
      ),
    );
  }
}

class _PreviewPanel extends ConsumerWidget {
  const _PreviewPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(studioProvider);
    final ctrl = ref.read(studioProvider.notifier);
    final src = s.source;
    if (src == null) {
      return NeonPanel(
        kicker: 'Preview',
        title: 'Nothing open',
        child: EmptyState(
          title: 'Open an image to start',
          message: 'PNG, JPEG, GIF, WebP, TGA, TIFF, BMP, ICO, PSD and more. Edits are non-destructive.',
          glyph: '[ o_O ]',
          action: NeonButton(label: 'Open image', icon: Icons.folder_open, onPressed: () => _open(context, ref)),
        ),
      );
    }
    final out = s.output;
    final before = s.showBefore || out == null;
    final cropping = s.crop.active && !before;
    final size = s.currentSize!;
    return NeonPanel(
      kicker: 'Preview',
      title: before ? 'Before (source)' : 'After (${out.render.width} x ${out.render.height})',
      icon: Icons.visibility_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChoiceRow<bool>(
            label: 'Compare',
            options: const [true, false],
            selected: before,
            onSelected: ctrl.toggleBefore,
            labelOf: (b) => b ? 'Before' : 'After',
          ),
          const SizedBox(height: J3Space.sm),
          if (s.rendering) ...[const NeonProgressBar(), const SizedBox(height: J3Space.xs)],
          if (s.renderError != null) ...[
            ErrorPanel(title: 'Render failed', error: s.renderError!),
            const SizedBox(height: J3Space.sm),
          ],
          if (!before && out.render.pipelineError != null) ...[
            StatusBanner(
              kind: StatusKind.error,
              title: 'Pipeline stopped',
              message: '${out.render.pipelineError}\nThe preview shows the steps before it.',
            ),
            const SizedBox(height: J3Space.sm),
          ],
          if (before)
            ImageViewport(
              png: src.decoded.previewPng,
              sourceWidth: src.decoded.raster.width,
              sourceHeight: src.decoded.raster.height,
              semanticLabel: 'Source image',
            )
          else
            ImageViewport(
              png: out.render.previewPng,
              sourceWidth: out.render.width,
              sourceHeight: out.render.height,
              fitOnly: cropping,
              overlayMargin: cropping ? 10 : 0,
              semanticLabel: 'Result preview',
              overlay: cropping && size.width == out.render.width && size.height == out.render.height
                  ? (context, scale) => CropOverlay(
                      rect: s.crop.rect,
                      bounds: size,
                      scale: scale,
                      aspect: s.crop.aspect.ratio,
                      onChanged: ctrl.setCropRect,
                    )
                  : null,
            ),
          if (cropping) ...[
            const SizedBox(height: J3Space.xs),
            StatusLine(
              kind: StatusKind.info,
              text:
                  'Drag the neon handles or draw a new box, then press "Add crop". '
                  'Selection: ${s.crop.rect.width} x ${s.crop.rect.height} at (${s.crop.rect.x}, ${s.crop.rect.y}).',
            ),
          ],
          if (src.decoded.previewScale < 1) ...[
            const SizedBox(height: J3Space.xs),
            Text('Preview is downscaled for display; exports use full resolution.', style: J3Type.caption),
          ],
        ],
      ),
    );
  }
}
