import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_info.dart';
import '../../core/activity/activity_controller.dart';
import '../../core/platform/app_paths.dart';
import '../../core/platform/capabilities.dart';
import '../../core/platform/file_access.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/tasks/cancellation.dart';
import '../../core/theme/effects.dart';
import '../../core/theme/j3_colors.dart';
import '../../core/theme/j3_spacing.dart';
import '../../core/theme/j3_typography.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../shell/destinations.dart';
import 'capability_views.dart';
import 'storage_usage.dart';

/// Every user preference, applied live and saved to `settings.json`.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// Slider values while dragging (persisted on release).
  double? _intensityDrag;
  double? _volumeDrag;

  final ScrollController _scroll = ScrollController();

  // Storage scan state. A generation counter discards stale results, the
  // token stops the walker when the page closes or a new scan starts.
  CancellationToken? _scanToken;
  int _scanGen = 0;
  bool _scanning = false;
  bool _scanCancelled = false;
  StorageUsage? _scanPartial;
  StorageBreakdown? _storage;
  Object? _scanError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scan();
    });
  }

  @override
  void dispose() {
    _scanToken?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  SettingsController get _settings => ref.read(settingsProvider.notifier);

  Future<void> _update(AppSettings Function(AppSettings s) change) => _settings.update(change);

  Future<void> _scan() async {
    _scanToken?.cancel();
    final token = CancellationToken();
    final gen = ++_scanGen;
    _scanToken = token;
    setState(() {
      _scanning = true;
      _scanCancelled = false;
      _scanError = null;
      _scanPartial = null;
    });
    try {
      final result = await measureBreakdown(
        ref.read(appPathsProvider).root,
        token: token,
        onProgress: (partial) {
          if (mounted && gen == _scanGen) setState(() => _scanPartial = partial);
        },
      );
      if (!mounted || gen != _scanGen) return;
      setState(() {
        _storage = result;
        _scanning = false;
      });
    } on OperationCancelled {
      if (!mounted || gen != _scanGen) return;
      setState(() {
        _scanning = false;
        _scanCancelled = true;
      });
    } catch (e) {
      if (!mounted || gen != _scanGen) return;
      setState(() {
        _scanning = false;
        _scanError = e;
      });
    }
  }

  void _cancelScan() => _scanToken?.cancel();

  Future<void> _clearHistory() async {
    final activity = ref.read(activityProvider);
    final finished = activity.operations.where((o) => o.status.isFinished).length;
    final running = activity.running.length;
    final ok = await showJ3Confirm(
      context,
      title: 'Clear operation history?',
      message:
          'Removes $finished finished ${finished == 1 ? 'operation' : 'operations'} from the activity history on '
          'this device. This cannot be undone.',
      details: [
        if (running > 0) '$running running ${running == 1 ? 'operation is' : 'operations are'} kept',
        'Files, workspaces, backups and mod journals are not touched',
      ],
      confirmLabel: 'Clear history',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await ref.read(activityProvider.notifier).clearHistory();
    ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Operation history cleared ($finished removed)');
  }

  Future<void> _resetSettings() async {
    final ok = await showJ3Confirm(
      context,
      title: 'Reset settings to defaults?',
      message: 'Effects, motion, intro, sound, accent and layout preferences return to their defaults.',
      details: const ['Workspaces, favourites, presets and history are not affected'],
      confirmLabel: 'Reset settings',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() {
      _intensityDrag = null;
      _volumeDrag = null;
    });
    // Keep the first-run marker so the sample workspace is not recreated.
    await _update((s) => AppSettings(sampleWorkspaceCreated: s.sampleWorkspaceCreated));
    ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Settings reset to defaults');
  }

  Future<void> _copyPath(String path) async {
    await ref.read(fileAccessProvider).copyText(path);
    ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Copied data directory path');
  }

  Future<void> _reveal(String path) async {
    final ok = await ref.read(fileAccessProvider).reveal(path);
    if (!ok) {
      ref.read(activityProvider.notifier).notify(NoticeKind.warning, 'Could not open the file manager for $path');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final caps = ref.watch(capabilitiesProvider);
    final fx = context.effects;

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 980;
        final pad = c.maxWidth >= J3Breakpoints.medium ? J3Space.pagePaddingWide : J3Space.pagePadding;

        final left = <Widget>[
          _effectsPanel(settings),
          _introPanel(settings),
          _soundPanel(settings),
          _themePanel(settings),
        ];
        final right = <Widget>[
          _dataPanel(),
          _shortcutsPanel(caps),
          NeonPanel(
            kicker: '// PLATFORM',
            title: 'Capabilities on ${caps.platform.label}',
            icon: Icons.devices_other,
            child: DeviceCapabilityList(caps: caps),
          ),
          _aboutPanel(),
        ];

        Widget column(List<Widget> items) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < items.length; i++) ...[if (i > 0) const SizedBox(height: J3Space.lg), items[i]],
          ],
        );

        return Scrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            controller: _scroll,
            padding: pad,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: J3Size.maxContentWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('// CONTROL STATION', style: J3Type.kicker.copyWith(color: fx.accentText)),
                    const SizedBox(height: 2),
                    GlitchText('Settings', style: J3Type.headline),
                    const SizedBox(height: J3Space.xs),
                    Text('Changes apply immediately and are saved on this device only.', style: J3Type.bodySecondary),
                    const SizedBox(height: J3Space.lg),
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: column(left)),
                          const SizedBox(width: J3Space.lg),
                          Expanded(child: column(right)),
                        ],
                      )
                    else
                      column([...left, ...right]),
                    const SizedBox(height: J3Space.xxl),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------- effects

  Widget _effectsPanel(AppSettings s) {
    final intensity = _intensityDrag ?? s.intensity;
    final preview = s.copyWith(intensity: intensity);
    final systemReduce = MediaQuery.disableAnimationsOf(context);
    final resolved = EffectsConfig.resolve(preview, systemReduce: systemReduce);
    final low = s.lowEffects;
    return NeonPanel(
      kicker: '// EFFECTS',
      title: 'Visual effects',
      icon: Icons.auto_awesome_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _EffectsPreview(settings: preview, systemReduce: systemReduce),
          const SizedBox(height: J3Space.lg),
          Wrap(
            spacing: J3Space.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Animation intensity', style: J3Type.body),
              Text(
                low ? '0 % (low-effects mode)' : '${(intensity * 100).round()} %',
                style: J3Type.code.copyWith(color: context.effects.accentText),
              ),
            ],
          ),
          MergeSemantics(
            child: Semantics(
              label: 'Animation intensity',
              child: Slider(
                value: intensity,
                divisions: 20,
                label: '${(intensity * 100).round()} %',
                semanticFormatterCallback: (v) => '${(v * 100).round()} percent',
                onChanged: low ? null : (v) => setState(() => _intensityDrag = v),
                onChangeEnd: low
                    ? null
                    : (v) async {
                        await _update((x) => x.copyWith(intensity: v));
                        if (mounted) setState(() => _intensityDrag = null);
                      },
              ),
            ),
          ),
          Text(
            'Scales glitch strength, glow and particle count. Intense effects are reserved for the intro and a '
            'few selected interactions.',
            style: J3Type.caption,
          ),
          const SizedBox(height: J3Space.sm),
          const Divider(),
          _PanelSwitch(
            label: 'Low-effects mode',
            description:
                'Master switch for long sessions and slower devices: turns off scanlines, particles, glow/bloom '
                'and glitch animations and treats intensity as 0 %. Your individual choices below are kept and '
                'return when you switch it off.',
            value: low,
            onChanged: (v) => _update((x) => x.copyWith(lowEffects: v)),
          ),
          const Divider(),
          _PanelSwitch(
            label: 'Scanlines',
            description: low ? 'Disabled by low-effects mode.' : 'Faint CRT lines over the whole interface.',
            value: s.scanlines,
            onChanged: low ? null : (v) => _update((x) => x.copyWith(scanlines: v)),
          ),
          _PanelSwitch(
            label: 'Particles',
            description: low
                ? 'Disabled by low-effects mode.'
                : resolved.reduceMotion
                ? 'Paused while motion is reduced.'
                : 'A few slowly drifting glyphs in the background.',
            value: s.particles,
            onChanged: low ? null : (v) => _update((x) => x.copyWith(particles: v)),
          ),
          _PanelSwitch(
            label: 'Glow',
            description: low ? 'Disabled by low-effects mode.' : 'Neon bloom around panels, buttons and the skull.',
            value: s.glow,
            onChanged: low ? null : (v) => _update((x) => x.copyWith(glow: v)),
          ),
          const Divider(),
          const SizedBox(height: J3Space.sm),
          ChoiceRow<MotionPreference>(
            label: 'MOTION',
            options: MotionPreference.values,
            selected: s.motion,
            labelOf: (m) => m.label,
            onSelected: (m) => _update((x) => x.copyWith(motion: m)),
          ),
          const SizedBox(height: J3Space.sm),
          _InfoLine(
            icon: systemReduce ? Icons.motion_photos_off_outlined : Icons.motion_photos_on_outlined,
            text: 'System setting: reduce motion is ${systemReduce ? 'ON' : 'OFF'}.',
          ),
          _InfoLine(
            icon: resolved.reduceMotion ? Icons.pause_circle_outline : Icons.play_circle_outline,
            text: resolved.reduceMotion
                ? 'Result: motion is reduced - no glitches, drifting particles or laughing jaw.'
                : 'Result: full motion - glitches and animations play.',
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ intro

  Widget _introPanel(AppSettings s) {
    return NeonPanel(
      kicker: '// INTRO',
      title: 'Laughing-skull intro',
      icon: Icons.movie_filter_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PanelSwitch(
            label: 'Skip intro on launch',
            description: 'Start directly on the dashboard. The intro never replays on navigation or resume.',
            value: s.skipIntro,
            onChanged: (v) => _update((x) => x.copyWith(skipIntro: v)),
          ),
          const SizedBox(height: J3Space.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: IntrinsicWidth(
              child: NeonButton.secondary(
                label: 'Replay intro now',
                icon: Icons.replay,
                tooltip: 'Watch the laughing skull again',
                onPressed: () => context.go('/intro?replay=1'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ sound

  Widget _soundPanel(AppSettings s) {
    final volume = _volumeDrag ?? s.volume;
    return NeonPanel(
      kicker: '// SOUND',
      title: 'Sound',
      icon: s.sound ? Icons.volume_up_outlined : Icons.volume_off_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PanelSwitch(
            label: 'Sound effects',
            description: 'Off by default. Plays the intro sound and a few interface sounds.',
            value: s.sound,
            onChanged: (v) => _update((x) => x.copyWith(sound: v)),
          ),
          const SizedBox(height: J3Space.sm),
          Wrap(
            spacing: J3Space.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Volume', style: J3Type.body.copyWith(color: s.sound ? J3Colors.text : J3Colors.textDisabled)),
              Text(
                s.sound ? '${(volume * 100).round()} %' : 'sound is off',
                style: J3Type.code.copyWith(color: s.sound ? context.effects.accentText : J3Colors.textMuted),
              ),
            ],
          ),
          MergeSemantics(
            child: Semantics(
              label: 'Sound volume',
              child: Slider(
                value: volume,
                divisions: 20,
                label: '${(volume * 100).round()} %',
                semanticFormatterCallback: (v) => '${(v * 100).round()} percent',
                onChanged: s.sound ? (v) => setState(() => _volumeDrag = v) : null,
                onChangeEnd: s.sound
                    ? (v) async {
                        await _update((x) => x.copyWith(volume: v));
                        if (mounted) setState(() => _volumeDrag = null);
                      }
                    : null,
              ),
            ),
          ),
          Text(
            'All sounds are original to this app (synthesized for it) and entirely optional. Nothing plays '
            'while sound is off.',
            style: J3Type.caption,
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ theme

  Widget _themePanel(AppSettings s) {
    return NeonPanel(
      kicker: '// THEME',
      title: 'Accent and layout',
      icon: Icons.palette_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('ACCENT', style: J3Type.caption),
          const SizedBox(height: J3Space.sm),
          LayoutBuilder(
            builder: (context, c) {
              final cols = c.maxWidth >= 440 ? 4 : 2;
              final w = (c.maxWidth - (cols - 1) * J3Space.sm) / cols;
              return Wrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                children: [
                  for (final a in AccentPreset.values)
                    SizedBox(
                      width: w,
                      child: _AccentSwatch(
                        preset: a,
                        selected: s.accent == a,
                        onTap: () => _update((x) => x.copyWith(accent: a)),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: J3Space.sm),
          Text(
            'Every preset stays within the red identity and keeps small text at 4.5:1 contrast or better. '
            'The whole interface updates immediately.',
            style: J3Type.caption,
          ),
          const SizedBox(height: J3Space.sm),
          const Divider(),
          _PanelSwitch(
            label: 'Show the activity panel on wide screens',
            description: 'Windows at least 1200 px wide show live operations on the right (Ctrl+J toggles it).',
            value: s.showActivityPanel,
            onChanged: (v) => _update((x) => x.copyWith(showActivityPanel: v)),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------- data

  Widget _dataPanel() {
    final paths = ref.watch(appPathsProvider);
    final caps = ref.watch(capabilitiesProvider);
    final finished = ref.watch(activityProvider.select((a) => a.operations.where((o) => o.status.isFinished).length));
    final st = _storage;
    return NeonPanel(
      kicker: '// DATA & PRIVACY',
      title: 'Your data stays on this device',
      icon: Icons.shield_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('DATA DIRECTORY', style: J3Type.caption),
          const SizedBox(height: J3Space.xs),
          Container(
            padding: const EdgeInsets.all(J3Space.sm),
            decoration: BoxDecoration(
              color: J3Colors.inputFill,
              borderRadius: J3Radius.small,
              border: Border.all(color: J3Colors.border),
            ),
            child: SelectableText(paths.root, style: J3Type.code),
          ),
          const SizedBox(height: J3Space.xs),
          Wrap(
            spacing: J3Space.xs,
            children: [
              TextButton.icon(
                onPressed: () => _copyPath(paths.root),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy path'),
              ),
              if (caps.supports(Capability.revealInFileManager))
                TextButton.icon(
                  onPressed: () => _reveal(paths.root),
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  label: const Text('Open in file manager'),
                ),
            ],
          ),
          const SizedBox(height: J3Space.md),
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('STORAGE USED', style: J3Type.caption),
              if (_scanning)
                const StatusBadge(kind: StatusKind.running, text: 'SCANNING', dense: true)
              else if (_scanError != null)
                const StatusBadge(kind: StatusKind.error, text: 'SCAN FAILED', dense: true)
              else if (_scanCancelled)
                const StatusBadge(kind: StatusKind.neutral, text: 'CANCELLED', dense: true)
              else if (st != null)
                const StatusBadge(kind: StatusKind.success, text: 'MEASURED', dense: true),
            ],
          ),
          const SizedBox(height: J3Space.xs),
          if (_scanning) ...[
            const NeonProgressBar(height: 4),
            const SizedBox(height: J3Space.xs),
            Text(
              _scanPartial == null
                  ? 'Measuring files in the data directory...'
                  : 'Measured ${_scanPartial!.files} files (${Fmt.bytes(_scanPartial!.bytes)}) so far...',
              style: J3Type.caption,
            ),
          ] else if (_scanError != null)
            Text('Could not measure storage: $_scanError', style: J3Type.caption.copyWith(color: J3Colors.error))
          else if (_scanCancelled)
            Text('Measurement cancelled. No numbers are shown for an incomplete scan.', style: J3Type.caption),
          if (st != null && !_scanning) ...[
            _StorageRow(
              label: 'Workspaces',
              hint: 'Imported copies, samples, mod libraries, journals and backups',
              usage: st.of('workspaces'),
            ),
            _StorageRow(label: 'Cache', hint: 'Picked-file copies and export staging', usage: st.of('cache')),
            _StorageRow(
              label: 'Settings and history',
              hint: 'settings.json, userdata.json, history.json and other documents',
              usage: st.excluding(const ['workspaces', 'cache']),
            ),
            const Divider(),
            _StorageRow(label: 'Total', usage: st.total, strong: true),
            if (st.total.unreadable > 0)
              Text('${st.total.unreadable} entries could not be read and were skipped.', style: J3Type.caption),
          ],
          const SizedBox(height: J3Space.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: _scanning
                ? TextButton.icon(
                    onPressed: _cancelScan,
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: const Text('Cancel measurement'),
                  )
                : TextButton.icon(
                    onPressed: _scan,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(st == null ? 'Measure storage' : 'Measure again'),
                  ),
          ),
          const SizedBox(height: J3Space.sm),
          const Divider(),
          const SizedBox(height: J3Space.sm),
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              IntrinsicWidth(
                child: NeonButton.danger(
                  label: 'Clear operation history ($finished)',
                  icon: Icons.delete_sweep_outlined,
                  tooltip: 'Remove finished operations from the activity history',
                  onPressed: finished == 0 ? null : _clearHistory,
                ),
              ),
              IntrinsicWidth(
                child: NeonButton.danger(
                  label: 'Reset settings to defaults',
                  icon: Icons.settings_backup_restore,
                  onPressed: _resetSettings,
                ),
              ),
            ],
          ),
          const SizedBox(height: J3Space.lg),
          Container(
            padding: const EdgeInsets.all(J3Space.md),
            decoration: BoxDecoration(
              color: J3Colors.success.withValues(alpha: 0.06),
              borderRadius: J3Radius.medium,
              border: Border.all(color: J3Colors.success.withValues(alpha: 0.45)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.verified_user_outlined, size: 20, color: J3Colors.success),
                const SizedBox(width: J3Space.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('PRIVACY // NO TELEMETRY', style: J3Type.label.copyWith(color: J3Colors.success)),
                      const SizedBox(height: J3Space.xs),
                      Text(
                        'No telemetry, analytics, accounts or cloud upload. The app makes no network access except '
                        'the HTTP tool, and only when you send a request yourself. Files are read only from '
                        'places you pick, import or link.',
                        style: J3Type.bodySecondary,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- shortcuts

  Widget _shortcutsPanel(CapabilityMatrix caps) {
    final supported = caps.supports(Capability.keyboardShortcuts);
    final rows = <(List<String>, String)>[
      (['Ctrl', 'K'], 'Open the command palette (also Ctrl+Shift+P)'),
      (['Ctrl', '`'], 'Open the terminal'),
      for (final d in kDestinations)
        if (d.shortcutDigit != null) (['Ctrl', '${d.shortcutDigit}'], 'Go to ${d.label}'),
      (['Ctrl', ','], 'Open settings'),
      (['Ctrl', 'J'], 'Show or hide the activity panel'),
      (['Esc'], 'Close dialogs, menus and the palette'),
      (['Tab'], 'Move keyboard focus (Shift+Tab goes back)'),
      (['Alt', 'Arrows'], 'Move the focused favourite on the dashboard'),
    ];
    return NeonPanel(
      kicker: '// KEYBOARD',
      title: 'Keyboard shortcuts',
      icon: Icons.keyboard_outlined,
      child: supported
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (keys, action) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: J3Space.xs),
                    child: Wrap(
                      spacing: J3Space.md,
                      runSpacing: J3Space.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 124,
                          child: Wrap(spacing: 4, runSpacing: 4, children: [for (final k in keys) _KeyCap(k)]),
                        ),
                        Text(action, style: J3Type.bodySecondary),
                      ],
                    ),
                  ),
              ],
            )
          : _InfoLine(
              icon: Icons.info_outline,
              text:
                  'Keyboard shortcuts are not available on ${caps.platform.label}. '
                  '${caps.alternativeFor(Capability.keyboardShortcuts) ?? ''}',
            ),
    );
  }

  Widget _aboutPanel() {
    return NeonPanel(
      kicker: '// ABOUT',
      title: AppInfo.fullName,
      icon: Icons.info_outline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Version ${AppInfo.version} (build ${AppInfo.buildNumber}). Credits, licences and the full '
            'capability matrix.',
            style: J3Type.bodySecondary,
          ),
          const SizedBox(height: J3Space.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: IntrinsicWidth(
              child: NeonButton.secondary(
                label: 'About this app',
                icon: Icons.arrow_forward,
                onPressed: () => context.go('/about'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: J3Colors.info),
          const SizedBox(width: J3Space.sm),
          Expanded(
            child: Text(text, style: J3Type.caption.copyWith(color: J3Colors.textSecondary)),
          ),
        ],
      ),
    );
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: J3Colors.surfaceRaised,
        borderRadius: J3Radius.small,
        border: Border.all(color: J3Colors.borderStrong),
      ),
      child: Text(label, style: J3Type.codeSmall.copyWith(color: J3Colors.text)),
    );
  }
}

class _StorageRow extends StatelessWidget {
  const _StorageRow({required this.label, required this.usage, this.hint, this.strong = false});
  final String label;
  final String? hint;
  final StorageUsage usage;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: J3Space.xs),
      child: Wrap(
        spacing: J3Space.md,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.end,
        alignment: WrapAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: strong ? J3Type.label : J3Type.body),
              if (hint != null) Text(hint!, style: J3Type.caption),
            ],
          ),
          Text(
            '${Fmt.bytes(usage.bytes)}  |  ${Fmt.count(usage.files, 'file')}',
            style: J3Type.code.copyWith(color: strong ? context.effects.accentText : J3Colors.text),
          ),
        ],
      ),
    );
  }
}

/// A selectable accent preset with its swatch; selection is shown by an
/// icon and text, not only by colour.
class _AccentSwatch extends StatefulWidget {
  const _AccentSwatch({required this.preset, required this.selected, required this.onTap});
  final AccentPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_AccentSwatch> createState() => _AccentSwatchState();
}

class _AccentSwatchState extends State<_AccentSwatch> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final a = widget.preset;
    final sel = widget.selected;
    return Semantics(
      button: true,
      selected: sel,
      label: 'Accent ${a.label}${sel ? ', selected' : ''}',
      excludeSemantics: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (h) => setState(() => _hover = h),
        onShowFocusHighlight: (f) => setState(() => _focus = f),
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap())},
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: fx.motion(J3Durations.fast),
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.all(J3Space.sm),
            decoration: BoxDecoration(
              color: sel || _hover ? J3Colors.surfaceRaised : J3Colors.inputFill,
              borderRadius: J3Radius.medium,
              border: Border.all(
                color: _focus ? J3Colors.text : (sel ? a.accent : J3Colors.border),
                width: _focus || sel ? 2 : 1,
              ),
              boxShadow: sel && fx.glow
                  ? [BoxShadow(color: a.accent.withValues(alpha: 0.3), blurRadius: fx.glowBlur(14), spreadRadius: -3)]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 22,
                  decoration: BoxDecoration(
                    borderRadius: J3Radius.small,
                    gradient: LinearGradient(colors: [a.accentDeep, a.accent, a.accentText]),
                  ),
                ),
                const SizedBox(height: J3Space.xs),
                Row(
                  children: [
                    Icon(
                      sel ? Icons.check_circle : Icons.circle_outlined,
                      size: 14,
                      color: sel ? a.accentText : J3Colors.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(a.label, style: J3Type.caption.copyWith(color: J3Colors.text)),
                    ),
                  ],
                ),
                if (sel) Text('ACTIVE', style: J3Type.codeSmall.copyWith(fontSize: 10, color: a.accentText)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Live preview of the effect settings: applies the (unsaved while
/// dragging) values to a sample panel with its own [J3Effects] scope.
class _EffectsPreview extends StatelessWidget {
  const _EffectsPreview({required this.settings, required this.systemReduce});
  final AppSettings settings;
  final bool systemReduce;

  @override
  Widget build(BuildContext context) {
    final cfg = EffectsConfig.resolve(settings, systemReduce: systemReduce);
    String onOff(bool v) => v ? 'ON' : 'OFF';
    final chips = <(String, bool)>[
      ('GLOW', cfg.glow),
      ('SCANLINES', cfg.scanlines),
      ('PARTICLES', cfg.particles),
      ('GLITCH', cfg.decorativeMotion),
    ];
    return J3Effects(
      config: cfg,
      child: Builder(
        builder: (context) => Stack(
          children: [
            NeonPanel(
              kicker: '// LIVE PREVIEW',
              emphasis: PanelEmphasis.strong,
              padding: const EdgeInsets.all(J3Space.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: GlitchText(
                      'J3NSONTOP',
                      trigger: '${cfg.intensity}|${cfg.accent}|${cfg.glow}',
                      glitchOnMount: false,
                      style: J3Type.headline.copyWith(
                        color: cfg.accentText,
                        letterSpacing: 3,
                        shadows: cfg.glow
                            ? [Shadow(color: cfg.accentColor.withValues(alpha: 0.8), blurRadius: cfg.glowBlur(18))]
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: J3Space.sm),
                  Wrap(
                    spacing: J3Space.xs,
                    runSpacing: J3Space.xs,
                    children: [
                      for (final (name, on) in chips)
                        StatusBadge(
                          kind: on ? StatusKind.success : StatusKind.neutral,
                          text: '$name ${onOff(on)}',
                          dense: true,
                        ),
                      StatusBadge(
                        kind: StatusKind.info,
                        text: 'INTENSITY ${(cfg.intensity * 100).round()}%',
                        dense: true,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (cfg.scanlines)
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: J3Radius.medium,
                    child: CustomPaint(painter: _PreviewScanlines(opacity: 0.05 + 0.05 * cfg.intensity)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PreviewScanlines extends CustomPainter {
  _PreviewScanlines({required this.opacity});
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withValues(alpha: (opacity * 4).clamp(0, 1));
    for (double y = 0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), paint);
    }
  }

  @override
  bool shouldRepaint(_PreviewScanlines old) => old.opacity != opacity;
}

/// [OptionSwitch] on its own transparent [Material] so its ink ripple and
/// focus highlight are painted above the panel's background.
class _PanelSwitch extends StatelessWidget {
  const _PanelSwitch({required this.label, required this.value, required this.onChanged, this.description});

  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: OptionSwitch(label: label, description: description, value: value, onChanged: onChanged),
    );
  }
}
