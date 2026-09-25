import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/platform/file_access.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../data/asset_worker.dart';
import '../../domain/atlas_packer.dart';
import '../../domain/image_codec.dart';
import '../asset_actions.dart';
import '../widgets/checkerboard.dart';
import '../widgets/image_viewport.dart';
import '../widgets/status_line.dart';
import 'atlas_controller.dart';

const String _tool = 'assets.atlas';

/// Atlas Packer: combine many images into one texture atlas with a
/// documented JSON index (docs/ATLAS_FORMAT.md). Every pack is checked by an
/// independent overlap/bounds validator.
class AtlasPackerPage extends ConsumerWidget {
  const AtlasPackerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const ToolScaffold(toolId: _tool, inputs: [_SpritesPanel(), _OptionsPanel()], results: [_ResultPanel()]);
  }
}

Future<void> _addFromDevice(WidgetRef ref) async {
  try {
    final files = await ref.read(fileAccessProvider).pickFiles(multiple: true, extensions: decodableImageExtensions);
    await ref.read(atlasProvider.notifier).addFiles([for (final f in files) (f.path, f.name)]);
  } catch (e) {
    ref.read(activityProvider.notifier).notify(NoticeKind.error, 'Could not open the file picker: $e');
  }
}

Future<void> _addFromWorkspace(BuildContext context, WidgetRef ref) async {
  final ws = ref.read(activeWorkspaceProvider);
  if (ws == null) return;
  final folder = await showWorkspaceBrowser(
    context,
    workspace: ws,
    mode: BrowseMode.pickFolder,
    title: 'Add all images in folder',
  );
  if (folder == null) return;
  final paths = await ref.read(assetWorkerProvider).run(listImagesTask(folder));
  if (paths.isEmpty) {
    ref.read(activityProvider.notifier).notify(NoticeKind.info, 'No supported images in that folder.');
    return;
  }
  await ref.read(atlasProvider.notifier).addFiles([for (final x in paths) (x, p.basename(x))]);
}

class _SpritesPanel extends ConsumerWidget {
  const _SpritesPanel();

  Future<void> _rename(BuildContext context, WidgetRef ref, AtlasSprite s) async {
    final ctrl = ref.read(atlasProvider.notifier);
    final others = [
      for (final o in ref.read(atlasProvider).sprites)
        if (o.id != s.id) o.name,
    ];
    final name = await showJ3TextInput(
      context,
      title: 'Rename sprite',
      label: 'Name in the atlas JSON',
      initial: s.name,
      monospace: true,
      validator: (v) => validateSpriteName(v, others),
    );
    if (name != null) ctrl.rename(s.id, name);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(atlasProvider);
    final ctrl = ref.read(atlasProvider.notifier);
    final hasWs = ref.watch(activeWorkspaceProvider) != null;
    final fx = context.effects;
    // Two text lines per row; grow with the text scale so nothing clips.
    final rowH = math.max(56.0, 12 + MediaQuery.textScalerOf(context).scale(40));
    return NeonPanel(
      kicker: 'Input',
      title: 'Sprites (${st.sprites.length})',
      icon: Icons.collections_outlined,
      actions: [
        NeonIconButton(
          icon: Icons.delete_sweep_outlined,
          tooltip: 'Remove all sprites',
          onPressed: st.sprites.isEmpty ? null : ctrl.clear,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              NeonButton.secondary(
                label: 'Add images',
                icon: Icons.add_photo_alternate_outlined,
                busy: st.importing,
                tooltip: 'Pick several images from the device',
                onPressed: () => _addFromDevice(ref),
              ),
              NeonButton.secondary(
                label: 'Add workspace folder',
                icon: Icons.folder_copy_outlined,
                tooltip: hasWs ? 'Add every image in a workspace folder' : 'No active workspace',
                onPressed: hasWs && !st.importing ? () => _addFromWorkspace(context, ref) : null,
              ),
            ],
          ),
          const SizedBox(height: J3Space.xs),
          Text('Names default to the file name; duplicate names are rejected.', style: J3Type.caption),
          for (final n in st.importNotes) ...[
            const SizedBox(height: J3Space.xs),
            StatusLine(kind: StatusKind.warning, text: n),
          ],
          const SizedBox(height: J3Space.sm),
          if (st.sprites.isEmpty)
            const EmptyState(title: 'No sprites yet', message: 'Add PNGs or other images to pack.', glyph: '[ ][ ]')
          else
            SizedBox(
              height: math.min(st.sprites.length * rowH, math.max(336, rowH * 3)),
              child: ListView.builder(
                itemCount: st.sprites.length,
                itemExtent: rowH,
                itemBuilder: (context, i) {
                  final s = st.sprites[i];
                  return Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(border: Border.all(color: J3Colors.border)),
                        child: CustomPaint(
                          painter: const CheckerboardPainter(cell: 5),
                          child: Image.memory(
                            s.thumb,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.none,
                            excludeFromSemantics: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: J3Space.sm),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s.name, style: J3Type.code, maxLines: 1, overflow: TextOverflow.ellipsis),
                            Text(
                              '${s.raster.width}x${s.raster.height}  ${s.fileName}',
                              style: J3Type.codeSmall.copyWith(color: fx.accentText),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      NeonIconButton(
                        icon: Icons.edit_outlined,
                        tooltip: 'Rename ${s.name}',
                        onPressed: () => _rename(context, ref, s),
                      ),
                      NeonIconButton(
                        icon: Icons.close,
                        tooltip: 'Remove ${s.name}',
                        onPressed: () => ctrl.remove(s.id),
                      ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _OptionsPanel extends ConsumerStatefulWidget {
  const _OptionsPanel();

  @override
  ConsumerState<_OptionsPanel> createState() => _OptionsPanelState();
}

class _OptionsPanelState extends ConsumerState<_OptionsPanel> {
  late final TextEditingController _pad = ref.read(draftTextProvider('$_tool/padding'));
  late final TextEditingController _name = ref.read(draftTextProvider('$_tool/name'));

  @override
  void initState() {
    super.initState();
    final st = ref.read(atlasProvider);
    if (_pad.text.isEmpty) _pad.text = '${st.options.padding}';
    if (_name.text.isEmpty) _name.text = st.atlasName;
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(atlasProvider);
    final ctrl = ref.read(atlasProvider.notifier);
    final o = st.options;
    return NeonPanel(
      kicker: 'Options',
      title: 'Packing',
      icon: Icons.tune,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              SizedBox(
                width: 200,
                child: TextField(
                  controller: _name,
                  style: J3Type.code,
                  decoration: const InputDecoration(labelText: 'Atlas name', helperText: '<name>.png + <name>.json'),
                  onChanged: ctrl.setName,
                ),
              ),
              NumberField(
                controller: _pad,
                label: 'Padding px',
                min: 0,
                max: 64,
                width: 120,
                onChanged: (v) {
                  final n = int.tryParse(v.trim());
                  if (n != null && n >= 0 && n <= 64) ctrl.setOptions(o.copyWith(padding: n));
                },
              ),
            ],
          ),
          const SizedBox(height: J3Space.md),
          ChoiceRow<int>(
            label: 'Extrude edges',
            options: const [0, 1],
            selected: o.extrude,
            onSelected: (v) => ctrl.setOptions(o.copyWith(extrude: v)),
            labelOf: (v) => v == 0 ? 'Off' : '1 px',
          ),
          const SizedBox(height: J3Space.md),
          ChoiceRow<int>(
            label: 'Maximum atlas size',
            options: atlasMaxSizes,
            selected: o.maxSize,
            onSelected: (v) => ctrl.setOptions(o.copyWith(maxSize: v)),
            labelOf: (v) => '$v',
          ),
          const SizedBox(height: J3Space.sm),
          OptionSwitch(
            label: 'Power-of-two size',
            description: 'Width and height rounded up to 256, 512, 1024...',
            value: o.powerOfTwo,
            onChanged: (v) => ctrl.setOptions(o.copyWith(powerOfTwo: v)),
          ),
          const SizedBox(height: J3Space.xs),
          StatusLine(
            kind: StatusKind.neutral,
            text:
                'Rotation: off. Sprites are never rotated, so engines need no rotation flag. '
                'Algorithm: MaxRects best-short-side-fit, falling back to best-area-fit and bottom-left.',
          ),
          const SizedBox(height: J3Space.md),
          Wrap(
            children: [
              NeonButton(
                label: 'Pack atlas',
                icon: Icons.dashboard_customize_outlined,
                busy: st.packing,
                onPressed: st.sprites.isEmpty || st.importing ? null : ctrl.pack,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> _saveToWorkspace(BuildContext context, WidgetRef ref, AtlasResult r, String name) async {
  final ws = ref.read(activeWorkspaceProvider);
  if (ws == null) return;
  final folder = await showWorkspaceBrowser(
    context,
    workspace: ws,
    mode: BrowseMode.pickFolder,
    title: 'Save atlas into folder',
  );
  if (folder == null) return;
  try {
    await ref
        .read(activityProvider.notifier)
        .run<List<String>>(
          toolId: _tool,
          title: 'Save atlas $name',
          workspaceId: ws.id,
          body: (op) async {
            final paths = await ref
                .read(assetWorkerProvider)
                .run(saveAtlasTask(ws.rootPath, folder, name, r.png, r.layout));
            final rel = [for (final x in paths) p.relative(x, from: ws.rootPath).replaceAll(r'\', '/')];
            op.succeed('Saved ${rel.join(' + ')}', details: rel, counts: {'files': 2});
            return rel;
          },
        );
  } catch (_) {
    // Recorded and announced by the activity log.
  }
}

class _ResultPanel extends ConsumerWidget {
  const _ResultPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(atlasProvider);
    final r = st.result;
    final hasWs = ref.watch(activeWorkspaceProvider) != null;
    if (st.packing) {
      return const NeonPanel(
        kicker: 'Result',
        title: 'Packing',
        child: LoadingState(label: 'Packing sprites...'),
      );
    }
    if (st.packError != null) {
      return NeonPanel(
        kicker: 'Result',
        title: 'Could not pack',
        emphasis: PanelEmphasis.danger,
        child: ErrorPanel(
          title: 'Atlas not created',
          error: st.packError!,
          hint: 'Raise the maximum size, lower the padding, or split the sprites over several atlases.',
        ),
      );
    }
    if (r == null) {
      return const NeonPanel(
        kicker: 'Result',
        title: 'No atlas yet',
        child: EmptyState(
          title: 'Add sprites and press "Pack atlas"',
          message: 'The result is a PNG plus a j3atlas JSON index, checked by an overlap validator.',
          glyph: '[#|#]\n[#|#]',
        ),
      );
    }
    final l = r.layout;
    final v = r.validation;
    final name = r.imageName.substring(0, r.imageName.length - 4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeonPanel(
          kicker: 'Result',
          title: '${l.width} x ${l.height} atlas',
          icon: Icons.dashboard_customize_outlined,
          emphasis: v.ok ? PanelEmphasis.success : PanelEmphasis.danger,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (st.isStale) ...[
                const StatusLine(
                  kind: StatusKind.warning,
                  text: 'Inputs changed since this pack. Press "Pack atlas" again.',
                ),
                const SizedBox(height: J3Space.sm),
              ],
              StatusBanner(
                kind: v.ok ? StatusKind.success : StatusKind.error,
                title: v.ok ? 'Validator passed' : 'Validator found problems',
                message: v.ok
                    ? '${v.frameCount} frames, no overlaps (${v.pairsChecked} padded-box pairs compared), all inside '
                          '${l.width} x ${l.height} with ${l.padding} px padding and ${l.extrude} px extrusion.'
                    : '${v.issues.length} issue(s).',
                details: v.issues,
              ),
              const SizedBox(height: J3Space.md),
              KeyValueTable(
                keyWidth: 110,
                rows: [
                  (
                    'Size',
                    '${l.width} x ${l.height} px${isPowerOfTwo(l.width) && isPowerOfTwo(l.height) ? ' (power of two)' : ''}',
                  ),
                  ('Frames', '${l.frames.length}'),
                  ('Coverage', '${(l.efficiency * 100).toStringAsFixed(1)}% of the atlas is sprite pixels'),
                  ('Algorithm', l.heuristic.label),
                  ('PNG', Fmt.bytes(r.png.length)),
                ],
              ),
              const SizedBox(height: J3Space.md),
              _AtlasPreview(result: r),
              const SizedBox(height: J3Space.md),
              Wrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                children: [
                  NeonButton(
                    label: 'Export ZIP (PNG + JSON)',
                    icon: Icons.archive_outlined,
                    onPressed: () {
                      final png = r.png;
                      final json = utf8.encode(r.json);
                      exportZip(
                        context,
                        ref,
                        toolId: _tool,
                        title: 'Export atlas $name',
                        zipName: '$name.zip',
                        prepare: filesTask([('$name.png', png), ('$name.json', json)]),
                      );
                    },
                  ),
                  NeonButton.secondary(
                    label: 'Save to workspace folder',
                    icon: Icons.create_new_folder_outlined,
                    tooltip: hasWs ? 'Writes <name>.png and <name>.json, never overwriting' : 'No active workspace',
                    onPressed: hasWs ? () => _saveToWorkspace(context, ref, r, name) : null,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: J3Space.lg),
        ResultPanel(
          text: r.json,
          title: '$name.json',
          kicker: 'j3atlas v1',
          fileName: '$name.json',
          mimeType: 'application/json',
          toolId: _tool,
          maxHeight: 280,
        ),
      ],
    );
  }
}

class _AtlasPreview extends StatefulWidget {
  const _AtlasPreview({required this.result});
  final AtlasResult result;

  @override
  State<_AtlasPreview> createState() => _AtlasPreviewState();
}

class _AtlasPreviewState extends State<_AtlasPreview> {
  AtlasFrame? _hover;

  AtlasFrame? _at(Offset local, double scale) {
    final x = local.dx / scale, y = local.dy / scale;
    for (final f in widget.result.layout.frames) {
      if (x >= f.x && x < f.x + f.w && y >= f.y && y < f.y + f.h) return f;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.result.layout;
    final fx = context.effects;
    final h = _hover;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ImageViewport(
          png: widget.result.previewPng,
          sourceWidth: l.width,
          sourceHeight: l.height,
          height: 320,
          semanticLabel: 'Packed atlas with sprite outlines',
          overlay: (context, scale) => MouseRegion(
            onHover: (e) {
              final f = _at(e.localPosition, scale);
              if (f != _hover) setState(() => _hover = f);
            },
            onExit: (_) => setState(() => _hover = null),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => setState(() => _hover = _at(d.localPosition, scale)),
              child: CustomPaint(
                painter: _OutlinePainter(layout: l, scale: scale, hover: _hover, accent: fx.accentColor),
              ),
            ),
          ),
        ),
        const SizedBox(height: J3Space.xs),
        Text(
          h == null
              ? 'Hover or tap a sprite to see its name and rectangle.'
              : '${h.name}  x=${h.x} y=${h.y} w=${h.w} h=${h.h}',
          style: J3Type.code.copyWith(color: h == null ? J3Colors.textMuted : fx.accentText),
        ),
      ],
    );
  }
}

class _OutlinePainter extends CustomPainter {
  _OutlinePainter({required this.layout, required this.scale, required this.hover, required this.accent});
  final AtlasLayout layout;
  final double scale;
  final AtlasFrame? hover;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = accent.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final f in layout.frames) {
      canvas.drawRect(Rect.fromLTWH(f.x * scale, f.y * scale, f.w * scale, f.h * scale).deflate(0.5), line);
    }
    final h = hover;
    if (h == null) return;
    final r = Rect.fromLTWH(h.x * scale, h.y * scale, h.w * scale, h.h * scale);
    canvas.drawRect(r, Paint()..color = accent.withValues(alpha: 0.25));
    canvas.drawRect(
      r,
      Paint()
        ..color = J3Colors.text
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: h.name,
        style: J3Type.codeSmall.copyWith(color: J3Colors.text, fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '...',
    )..layout(maxWidth: math.max(40, size.width - 8));
    var dx = r.left;
    var dy = r.top - tp.height - 4;
    if (dy < 0) dy = r.bottom + 2;
    if (dx + tp.width + 6 > size.width) dx = size.width - tp.width - 6;
    final bg = Rect.fromLTWH(math.max(0, dx), dy, tp.width + 6, tp.height + 2);
    canvas.drawRect(bg, Paint()..color = J3Colors.background.withValues(alpha: 0.9));
    tp.paint(canvas, Offset(bg.left + 3, bg.top + 1));
    tp.dispose();
  }

  @override
  bool shouldRepaint(_OutlinePainter old) =>
      old.layout != layout || old.scale != scale || old.hover != hover || old.accent != accent;
}
