import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_info.dart';
import '../../core/activity/activity_controller.dart';
import '../../core/diagnostics/diagnostics_report.dart';
import '../../core/diagnostics/error_log.dart';
import '../../core/platform/app_paths.dart';
import '../../core/platform/capabilities.dart';
import '../../core/platform/file_access.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme/j3_spacing.dart';
import '../../core/theme/j3_typography.dart';
import '../../core/widgets/widgets.dart';

/// About -> Diagnostics: the facts a tester needs for a bug report, with
/// "Copy diagnostics" (summary + recent errors) and "Save diagnostics file"
/// (summary + the whole error log). Nothing is sent anywhere by the app.
class DiagnosticsPanel extends ConsumerWidget {
  const DiagnosticsPanel({super.key, this.keyWidth = 160});
  final double keyWidth;

  /// The error log is bounded to ~1 MB; the saved file keeps the newest part.
  static const int maxLogBytes = 1 << 20;

  static DisplayFacts displayFacts(BuildContext context) {
    final mq = MediaQuery.of(context);
    return DisplayFacts(
      width: mq.size.width,
      height: mq.size.height,
      pixelRatio: mq.devicePixelRatio,
      textScale: mq.textScaler.scale(1),
      reduceMotion: mq.disableAnimations,
      highContrast: mq.highContrast,
    );
  }

  static Future<String> buildReport(BuildContext context, WidgetRef ref, {required bool includeLog}) async {
    // Everything that needs the context is read before the first await.
    final display = displayFacts(context);
    final platform = ref.read(capabilitiesProvider).platform;
    final dataRoot = ref.read(appPathsProvider).root;
    final settings = ref.read(settingsProvider);
    final log = ErrorLog.instance;
    final errors = List.of(log.recent);
    final path = log.logPath;
    final file = path == null ? null : File(path);
    final exists = file != null && await file.exists();
    final size = exists ? await file.length() : null;
    String? contents;
    if (includeLog && exists) {
      final bytes = await file.readAsBytes();
      final tail = bytes.length > maxLogBytes ? bytes.sublist(bytes.length - maxLogBytes) : bytes;
      contents = utf8.decode(tail, allowMalformed: true);
    }
    return DiagnosticsReport.build(
      platform: platform,
      dataRoot: dataRoot,
      settings: settings,
      now: DateTime.now(),
      display: display,
      errors: errors,
      errorLogPath: path,
      errorLogBytes: size,
      errorLogContents: contents,
    );
  }

  Future<void> _copy(BuildContext context, WidgetRef ref) async {
    final text = await buildReport(context, ref, includeLog: false);
    await ref.read(fileAccessProvider).copyText(text);
    ref
        .read(activityProvider.notifier)
        .notify(NoticeKind.success, 'Diagnostics copied - paste them into your bug report');
  }

  Future<void> _save(BuildContext context, WidgetRef ref) async {
    final text = await buildReport(context, ref, includeLog: true);
    if (!context.mounted) return;
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    await saveOutput(
      context,
      ref,
      suggestedName: 'j3nsontop-diagnostics-$stamp.txt',
      bytes: Uint8List.fromList(utf8.encode(text)),
      mimeType: 'text/plain',
      toolId: 'about.diagnostics',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final caps = ref.watch(capabilitiesProvider);
    final log = ErrorLog.instance;
    final home = DiagnosticsReport.homeDirectory();
    final errors = log.recent.length;
    return NeonPanel(
      kicker: '// DIAGNOSTICS',
      title: 'Report a problem',
      icon: Icons.bug_report_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Found a bug? Copy these details into your report. They stay on this device unless you paste or '
            'save them yourself; your home folder is shortened to ~.',
            style: J3Type.bodySecondary,
          ),
          const SizedBox(height: J3Space.md),
          KeyValueTable(
            keyWidth: keyWidth,
            rows: [
              ('Build label', AppInfo.buildLabel),
              ('System', '${caps.platform.label} - ${Platform.operatingSystemVersion}'),
              ('Errors this session', errors == 0 ? 'none' : '$errors (newest: ${log.recent.last.split('\n').first})'),
              ('Error log', log.logPath == null ? 'not attached' : DiagnosticsReport.redactHome(log.logPath!, home)),
            ],
          ),
          const SizedBox(height: J3Space.md),
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              IntrinsicWidth(
                child: NeonButton(
                  label: 'Copy diagnostics',
                  icon: Icons.copy_all_outlined,
                  tooltip: 'Version, build, system, settings and recent errors as text',
                  onPressed: () => _copy(context, ref),
                ),
              ),
              IntrinsicWidth(
                child: NeonButton.secondary(
                  label: 'Save diagnostics file',
                  icon: Icons.save_alt_outlined,
                  tooltip: 'The same details plus the whole error log, as a .txt file',
                  onPressed: () => _save(context, ref),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
