import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../data/asset_worker.dart';
import '../../domain/color_model.dart';
import '../../domain/icon_export.dart';
import '../../domain/image_codec.dart';
import '../asset_actions.dart';
import '../widgets/checkerboard.dart';
import '../widgets/color_widgets.dart';
import '../widgets/image_viewport.dart';
import '../widgets/status_line.dart';
import 'icon_controller.dart';

const String _tool = 'assets.icons';

/// App Icon Export: one square artwork -> Android (legacy + adaptive),
/// Google Play, iOS AppIcon.appiconset and a Windows .ico, each output
/// decoded again and verified.
class IconExportPage extends ConsumerWidget {
  const IconExportPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const ToolScaffold(toolId: _tool, inputs: [_SourcePanel(), _OptionsPanel()], results: [_ResultPanel()]);
  }
}

Future<void> _open(BuildContext context, WidgetRef ref) async {
  final input = await pickImage(context, ref, decodableImageExtensions, title: 'Open icon artwork');
  if (input == null) return;
  await ref.read(iconExportProvider.notifier).open(input);
}

class _SourcePanel extends ConsumerWidget {
  const _SourcePanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(iconExportProvider);
    final ctrl = ref.read(iconExportProvider.notifier);
    final src = st.source;
    final o = st.options;
    return NeonPanel(
      kicker: 'Input',
      title: src?.name ?? 'Icon artwork',
      icon: Icons.image_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            children: [
              NeonButton(
                label: src == null ? 'Open artwork' : 'Open another',
                icon: Icons.folder_open,
                busy: st.loading,
                onPressed: () => _open(context, ref),
              ),
            ],
          ),
          const SizedBox(height: J3Space.xs),
          Text('Square, 1024 x 1024 px or larger works best.', style: J3Type.caption),
          if (st.loadError != null) ...[
            const SizedBox(height: J3Space.sm),
            ErrorPanel(title: 'Cannot open artwork', error: st.loadError!),
          ],
          if (src != null) ...[
            const SizedBox(height: J3Space.md),
            ImageViewport(
              png: src.previewPng,
              sourceWidth: src.raster.width,
              sourceHeight: src.raster.height,
              height: 200,
              semanticLabel: 'Icon artwork',
            ),
            const SizedBox(height: J3Space.sm),
            if (!src.isSquare) ...[
              StatusLine(
                kind: StatusKind.warning,
                text:
                    'The artwork is ${src.raster.width} x ${src.raster.height}, not square. Choose how to make it square:',
              ),
              const SizedBox(height: J3Space.sm),
              ChoiceRow<NonSquareMode>(
                label: 'Non-square source',
                options: NonSquareMode.values,
                selected: o.nonSquare,
                onSelected: (m) => ctrl.setOptions(o.copyWith(nonSquare: m)),
                labelOf: (m) => m.label,
              ),
              if (o.nonSquare == NonSquareMode.pad) ...[
                const SizedBox(height: J3Space.sm),
                ColorChoiceField(
                  label: 'Padding colour',
                  value: o.padColor,
                  allowAlpha: true,
                  presets: const [('Transparent', Rgba.transparent), ...backgroundPresets],
                  onChanged: (c) => ctrl.setOptions(o.copyWith(padColor: c)),
                ),
              ],
            ] else
              StatusLine(kind: StatusKind.success, text: 'Square ${src.raster.width} x ${src.raster.height} artwork.'),
            if (src.raster.width < 1024 || src.raster.height < 1024) ...[
              const SizedBox(height: J3Space.xs),
              const StatusLine(
                kind: StatusKind.info,
                text: 'Smaller than 1024 px: the largest icons (1024 iOS, 512 Play, 432 adaptive) are upscaled.',
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _OptionsPanel extends ConsumerWidget {
  const _OptionsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(iconExportProvider);
    final ctrl = ref.read(iconExportProvider.notifier);
    final o = st.options;
    return NeonPanel(
      kicker: 'Targets',
      title: 'Platforms',
      icon: Icons.devices_other,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ColorChoiceField(
            label: 'Background colour',
            value: o.background,
            presets: backgroundPresets,
            onChanged: (c) => ctrl.setOptions(o.copyWith(background: c)),
          ),
          const SizedBox(height: J3Space.xs),
          Text(
            'Used where icons must be opaque (iOS, Google Play) and as the Android adaptive background layer.',
            style: J3Type.caption,
          ),
          const SizedBox(height: J3Space.sm),
          OptionSwitch(
            label: 'Android + Google Play',
            description: 'mipmap 48-192 px, adaptive foreground 108-432 px + XML, Play 512 px',
            value: o.android,
            onChanged: (v) => ctrl.setOptions(o.copyWith(android: v)),
          ),
          OptionSwitch(
            label: 'iOS',
            description: 'AppIcon.appiconset: iPhone, iPad and 1024 px App Store, no alpha',
            value: o.ios,
            onChanged: (v) => ctrl.setOptions(o.copyWith(ios: v)),
          ),
          OptionSwitch(
            label: 'Windows',
            description: 'app_icon.ico with 16, 24, 32, 48, 64, 128, 256 px',
            value: o.windows,
            onChanged: (v) => ctrl.setOptions(o.copyWith(windows: v)),
          ),
          const SizedBox(height: J3Space.md),
          Wrap(
            children: [
              NeonButton(
                label: 'Generate & verify',
                icon: Icons.auto_awesome_mosaic_outlined,
                busy: st.generating,
                onPressed: st.source == null || !(o.android || o.ios || o.windows) ? null : ctrl.generate,
              ),
            ],
          ),
          if (!(o.android || o.ios || o.windows)) ...[
            const SizedBox(height: J3Space.xs),
            const StatusLine(kind: StatusKind.warning, text: 'Select at least one platform.'),
          ],
        ],
      ),
    );
  }
}

class _ResultPanel extends ConsumerWidget {
  const _ResultPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(iconExportProvider);
    final run = st.run;
    final hasWs = ref.watch(activeWorkspaceProvider) != null;
    if (st.generating) {
      return const NeonPanel(
        kicker: 'Result',
        title: 'Generating',
        child: LoadingState(label: 'Generating icons...'),
      );
    }
    if (st.error != null) {
      return NeonPanel(
        kicker: 'Result',
        title: 'Generation failed',
        emphasis: PanelEmphasis.danger,
        child: ErrorPanel(title: 'Icons not generated', error: st.error!),
      );
    }
    if (run == null) {
      return const NeonPanel(
        kicker: 'Result',
        title: 'Nothing generated yet',
        child: EmptyState(
          title: 'Open artwork and press "Generate & verify"',
          message: 'Every file is decoded again and checked: sizes, ICO frames, iOS no-alpha, XML and Contents.json.',
          glyph: '[ :: ]',
        ),
      );
    }
    final files = run.result.files;
    _IconPreview? preview(String suffix, String label, {bool adaptive = false}) {
      for (final f in files) {
        if (f.path.endsWith(suffix)) return _IconPreview(f, label, adaptive: adaptive);
      }
      return null;
    }

    final previews = <_IconPreview>[
      ?preview('mipmap-xxxhdpi/ic_launcher.png', 'Android 192'),
      ?preview('mipmap-xxxhdpi/ic_launcher_foreground.png', 'Adaptive (masked)', adaptive: true),
      ?preview('Icon-App-60x60@3x.png', 'iPhone 180'),
      ?preview(playIconPath, 'Play 512'),
    ];
    return NeonPanel(
      kicker: 'Result',
      title: '${files.length} files, ${Fmt.bytes(run.result.totalBytes)}',
      icon: Icons.verified_outlined,
      emphasis: run.allPassed ? PanelEmphasis.success : PanelEmphasis.danger,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (st.isStale) ...[
            const StatusLine(
              kind: StatusKind.warning,
              text: 'Settings changed since generating. Generate again to update.',
            ),
            const SizedBox(height: J3Space.sm),
          ],
          StatusBanner(
            kind: run.allPassed ? StatusKind.success : StatusKind.error,
            title: run.allPassed ? 'All outputs verified' : 'Verification failed',
            message: '${run.passed} of ${run.checks.length} files passed after decoding them again.',
            details: run.result.notes,
          ),
          const SizedBox(height: J3Space.md),
          if (previews.isNotEmpty)
            Wrap(
              spacing: J3Space.md,
              runSpacing: J3Space.md,
              children: [for (final p in previews) _PreviewTile(preview: p, background: st.options.background)],
            ),
          const SizedBox(height: J3Space.md),
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              NeonButton(
                label: 'Export all (ZIP)',
                icon: Icons.archive_outlined,
                onPressed: () => exportZip(
                  context,
                  ref,
                  toolId: _tool,
                  title: 'Export ${files.length} icon files',
                  zipName: 'app_icons.zip',
                  prepare: filesTask([for (final f in files) (f.path, f.bytes)]),
                ),
              ),
              NeonButton.secondary(
                label: 'Save to workspace folder',
                icon: Icons.create_new_folder_outlined,
                tooltip: hasWs
                    ? 'Existing files are kept; clashing names get a numbered suffix'
                    : 'No active workspace',
                onPressed: hasWs
                    ? () => saveFilesToWorkspace(
                        context,
                        ref,
                        toolId: _tool,
                        title: 'Save ${files.length} icon files',
                        prepare: filesTask([for (final f in files) (f.path, f.bytes)]),
                      )
                    : null,
              ),
            ],
          ),
          const SizedBox(height: J3Space.xs),
          Text(
            'Paths mirror a Flutter project (android/, ios/, windows/) plus store/. Unpack the ZIP onto a project '
            'to replace its icons deliberately; saving into a workspace never overwrites existing files.',
            style: J3Type.caption,
          ),
          const SizedBox(height: J3Space.lg),
          Text('Verification', style: J3Type.label.copyWith(color: context.effects.accentText)),
          const SizedBox(height: J3Space.sm),
          for (final c in run.checks) _CheckRow(check: c),
        ],
      ),
    );
  }
}

class _IconPreview {
  const _IconPreview(this.file, this.label, {this.adaptive = false});
  final IconFile file;
  final String label;
  final bool adaptive;
}

class _PreviewTile extends StatelessWidget {
  const _PreviewTile({required this.preview, required this.background});
  final _IconPreview preview;
  final Rgba background;

  @override
  Widget build(BuildContext context) {
    final image = Image.memory(
      preview.file.bytes,
      width: 72,
      height: 72,
      fit: BoxFit.contain,
      excludeFromSemantics: true,
    );
    return Semantics(
      image: true,
      label: '${preview.label} preview',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 72,
            height: 72,
            child: preview.adaptive
                ? ClipOval(
                    child: ColoredBox(color: toFlutterColor(background), child: image),
                  )
                : CustomPaint(painter: const CheckerboardPainter(cell: 6), child: image),
          ),
          const SizedBox(height: J3Space.xs),
          Text(preview.label, style: J3Type.caption),
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.check});
  final IconCheck check;

  @override
  Widget build(BuildContext context) {
    final kind = check.ok ? StatusKind.success : StatusKind.error;
    return Padding(
      padding: const EdgeInsets.only(bottom: J3Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Verdict(ok: check.ok, kind: kind),
          const SizedBox(width: J3Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(check.path, style: J3Type.codeSmall.copyWith(color: J3Colors.text)),
                Text('expected: ${check.expected}', style: J3Type.caption),
                Text(
                  'actual: ${check.actual}',
                  style: J3Type.caption.copyWith(color: check.ok ? null : J3Colors.error),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// PASS/FAIL badge with an explicit check or cross icon plus text, so the
/// verdict never depends on colour or on a font having the glyph.
class _Verdict extends StatelessWidget {
  const _Verdict({required this.ok, required this.kind});
  final bool ok;
  final StatusKind kind;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: ok ? 'passed' : 'failed',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: kind.color.withValues(alpha: 0.10),
          borderRadius: J3Radius.small,
          border: Border.all(color: kind.color.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(ok ? Icons.check : Icons.close, size: 14, color: kind.color),
            const SizedBox(width: 2),
            Text(
              ok ? 'PASS' : 'FAIL',
              style: J3Type.codeSmall.copyWith(color: kind.color, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}
