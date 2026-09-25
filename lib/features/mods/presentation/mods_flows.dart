import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/activity/activity_controller.dart';
import '../../../core/platform/file_access.dart';
import '../../../core/tasks/cancellation.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/widgets/widgets.dart';
import '../data/apply_engine.dart';
import '../data/journal.dart';
import '../data/mod_library.dart';
import '../data/profile_store.dart';
import '../domain/issues.dart';
import '../domain/profile.dart';
import 'mods_controller.dart';
import 'mods_widgets.dart';
import 'plan_dialog.dart';

enum _ImportSource { device, workspace }

/// Asks where to import from (device picker or workspace file) and returns
/// a readable local path, or null.
Future<String?> pickPackageSource(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required List<String> extensions,
}) async {
  final ws = ref.read(modsProvider).workspace;
  final choice = ws == null
      ? _ImportSource.device
      : await showModalBottomSheet<_ImportSource>(
          context: context,
          builder: (ctx) => SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(J3Space.lg, 0, J3Space.lg, J3Space.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(title, style: J3Type.title),
                  const SizedBox(height: J3Space.sm),
                  ListTile(
                    leading: const Icon(Icons.upload_file_outlined),
                    title: const Text('From device'),
                    subtitle: Text('System file picker (${extensions.map((e) => '.$e').join(', ')})'),
                    onTap: () => Navigator.of(ctx).pop(_ImportSource.device),
                  ),
                  ListTile(
                    leading: const Icon(Icons.folder_special_outlined),
                    title: Text('From workspace "${ws.name}"'),
                    subtitle: const Text('For example the downloads/ folder of the sample workspace'),
                    onTap: () => Navigator.of(ctx).pop(_ImportSource.workspace),
                  ),
                ],
              ),
            ),
          ),
        );
  if (choice == null || !context.mounted) return null;
  if (choice == _ImportSource.workspace && ws != null) {
    final downloads = p.join(ws.rootPath, 'downloads');
    return showWorkspaceBrowser(
      context,
      workspace: ws,
      extensions: extensions,
      title: title,
      initialDir: Directory(downloads).existsSync() ? downloads : null,
    );
  }
  try {
    final files = await ref.read(fileAccessProvider).pickFiles(multiple: false, extensions: extensions);
    return files.isEmpty ? null : files.first.path;
  } catch (e) {
    ref.read(activityProvider.notifier).notify(NoticeKind.error, 'Could not open the file picker: $e');
    return null;
  }
}

/// Import flow: validate, show problems, ask before replacing. Returns a
/// short description of the outcome, or null when cancelled.
Future<String?> importPackageFlow(BuildContext context, WidgetRef ref, {String? path}) async {
  final source =
      path ?? await pickPackageSource(context, ref, title: 'Import mod package', extensions: const ['j3mod', 'zip']);
  if (source == null || !context.mounted) return null;
  final ctrl = ref.read(modsProvider.notifier);
  final activity = ref.read(activityProvider.notifier);
  try {
    var outcome = await ctrl.importPackage(source);
    if (!context.mounted) return null;
    if (outcome is ImportNeedsReplace) {
      final ok = await showJ3Confirm(
        context,
        title: 'Replace ${outcome.existing.id}?',
        message:
            'The library already has ${outcome.existing.id} ${outcome.existing.version} (${outcome.direction}). '
            'The library keeps one version per package: replace it with ${outcome.incoming.displayVersion}? '
            'Profiles that use it will use the new version.',
        confirmLabel: 'Replace',
        destructive: true,
      );
      if (!ok || !context.mounted) return null;
      outcome = await ctrl.importPackage(source, replace: true);
    }
    if (!context.mounted) return null;
    switch (outcome) {
      case ImportCompleted(:final entry, :final replaced):
        final text = replaced == null
            ? 'imported ${entry.name} ${entry.version}'
            : 'updated ${entry.name} to ${entry.version}';
        activity.notify(NoticeKind.success, text);
        return text;
      case ImportIdentical(:final existing):
        activity.notify(NoticeKind.info, '${existing.name} ${existing.version} is already in the library');
        return 'already in the library';
      case ImportRejected(:final report):
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('${report.fileName} was not imported'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('The package failed validation. Nothing was copied.', style: J3Type.body),
                    const SizedBox(height: J3Space.sm),
                    for (final i in report.issues.take(40)) IssueLine.of(i),
                  ],
                ),
              ),
            ),
            actions: [NeonButton(label: 'Close', onPressed: () => Navigator.of(ctx).pop())],
          ),
        );
        return 'rejected (${report.errorCount} error(s))';
      case ImportNeedsReplace():
        return null;
    }
  } catch (e) {
    activity.notify(NoticeKind.error, 'Import failed: $e');
    return 'failed: $e';
  }
}

/// Remove a package after confirmation (mentions profiles that use it).
Future<void> removePackageFlow(BuildContext context, WidgetRef ref, LibraryEntry entry) async {
  final users = ref.read(modsProvider).profilesUsing(entry.id);
  final ok = await showJ3Confirm(
    context,
    title: 'Remove ${entry.name}?',
    message:
        'Deletes ${entry.fileName} from this workspace\'s mod library. Files already applied to a target are not '
        'touched; roll back first if you want them gone.',
    details: [for (final u in users) 'Used by profile "${u.name}" (it will report a missing package)'],
    confirmLabel: 'Remove',
    destructive: true,
  );
  if (!ok || !context.mounted) return;
  try {
    await ref.read(modsProvider.notifier).removePackage(entry);
  } catch (e) {
    ref.read(activityProvider.notifier).notify(NoticeKind.error, 'Remove failed: $e');
  }
}

/// Plan -> review dialog -> apply (with LIFO roll-back-first prompt).
Future<void> planAndApplyFlow(BuildContext context, WidgetRef ref, ModProfile profile) async {
  final ctrl = ref.read(modsProvider.notifier);
  final report = ref.read(profileReportProvider(profile.id));
  if (report == null || !report.canApply) return;
  final blocking = ref.read(modsProvider).openOperationOn(profile.target);
  if (blocking != null) {
    final interrupted = blocking.status.isInterrupted;
    final ok = await showJ3Confirm(
      context,
      title: interrupted ? 'Resolve the interrupted operation first' : 'Roll back the applied profile first?',
      message: interrupted
          ? 'An interrupted operation from "${blocking.profileName}" still affects "${blocking.targetRel}". '
                'Roll it back now? (You can also resume it from the banner at the top.)'
          : '"${blocking.profileName}" is applied to "${blocking.targetRel}". Only one operation per target can be '
                'active, so it must be rolled back before "${profile.name}" can be applied. Roll it back now?',
      confirmLabel: 'Roll back',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    final done = await rollbackFlow(context, ref, blocking, confirm: false);
    if (!done || !context.mounted) return;
  }
  try {
    final plan = await ctrl.computePlan(profile);
    if (!context.mounted) return;
    final fresh = ref.read(profileReportProvider(profile.id)) ?? report;
    final ok = await showPlanDialog(context, plan: plan, report: fresh);
    if (!ok || !context.mounted) return;
    await ctrl.apply(plan);
  } on OperationCancelled {
    // Reported inline by the controller.
  } catch (e) {
    ctrl.setResult(profile.id, ResultNote(kind: StatusKind.error, title: 'Could not apply', message: e.toString()));
  }
}

/// Preview -> conflict decisions (or confirmation) -> rollback. Returns true
/// when the rollback ran.
Future<bool> rollbackFlow(BuildContext context, WidgetRef ref, OperationJournal op, {bool confirm = true}) async {
  final ctrl = ref.read(modsProvider.notifier);
  try {
    final preview = await ctrl.previewRollback(op.id);
    if (!context.mounted) return false;
    if (preview.isBlocked) {
      ctrl.setResult(
        'op:${op.id}',
        ResultNote(
          kind: StatusKind.error,
          title: 'Rollback refused',
          message: RollbackBlocked(preview.blockedBy!).toString(),
        ),
      );
      ctrl.setResult(
        op.profileId,
        ResultNote(
          kind: StatusKind.error,
          title: 'Rollback refused',
          message: RollbackBlocked(preview.blockedBy!).toString(),
        ),
      );
      return false;
    }
    var decisions = <String, ConflictDecision>{};
    if (preview.conflicts.isNotEmpty) {
      final chosen = await showConflictDialog(context, preview: preview);
      if (chosen == null || !context.mounted) return false;
      decisions = chosen;
    } else if (confirm) {
      final ok = await showJ3Confirm(
        context,
        title: 'Roll back "${op.profileName}"?',
        message:
            'Restores ${preview.toRestore} original file(s) from verified backups and removes ${preview.toDelete} '
            'created file(s), plus folders the operation created if they are empty. Files the operation did not '
            'record are never touched.',
        details: preview.problems,
        confirmLabel: 'Roll back',
        destructive: true,
      );
      if (!ok || !context.mounted) return false;
    }
    await ctrl.rollback(op.id, decisions: decisions);
    return true;
  } on OperationCancelled {
    return false;
  } catch (e) {
    ctrl.setResult(op.profileId, ResultNote(kind: StatusKind.error, title: 'Rollback failed', message: e.toString()));
    return false;
  }
}

Future<void> resumeFlow(BuildContext context, WidgetRef ref, OperationJournal op) async {
  try {
    await ref.read(modsProvider.notifier).resume(op.id);
  } catch (_) {
    // Shown inline by the controller.
  }
}

/// Packs the target folder and hands it to saveOutput (save/export/share).
Future<void> exportResultFlow(BuildContext context, WidgetRef ref, String targetRel) async {
  try {
    final (name, bytes) = await ref.read(modsProvider.notifier).buildResultZip(targetRel);
    if (!context.mounted) return;
    await saveOutput(
      context,
      ref,
      suggestedName: name,
      bytes: bytes,
      mimeType: 'application/zip',
      toolId: kModsManagerId,
    );
  } on OperationCancelled {
    // Cancelled from the activity panel.
  } catch (e) {
    ref.read(activityProvider.notifier).notify(NoticeKind.error, 'Export failed: $e');
  }
}

/// Imports a `.j3profile.json` (device or workspace) with collision prompt.
Future<void> importProfileFlow(BuildContext context, WidgetRef ref) async {
  final path = await pickPackageSource(context, ref, title: 'Import profile', extensions: const ['json']);
  if (path == null || !context.mounted) return;
  final ctrl = ref.read(modsProvider.notifier);
  final activity = ref.read(activityProvider.notifier);
  try {
    final file = File(path);
    if (await file.length() > 1024 * 1024) throw const FormatException('the file is larger than 1 MiB');
    final text = await file.readAsString();
    var r = await ctrl.importProfile(text);
    if (!context.mounted) return;
    if (r is ProfileImportConflict) {
      final choice = await showDialog<ProfileCollision>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Profile already exists'),
          content: Text(
            'A profile with the id "${r is ProfileImportConflict ? r.existing.id : ''}" exists. Replace it, or keep '
            'both (the import gets a new id)?',
          ),
          actions: [
            NeonButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(ctx).pop()),
            NeonButton.secondary(label: 'Keep both', onPressed: () => Navigator.of(ctx).pop(ProfileCollision.keepBoth)),
            NeonButton.danger(label: 'Replace', onPressed: () => Navigator.of(ctx).pop(ProfileCollision.replace)),
          ],
        ),
      );
      if (choice == null || !context.mounted) return;
      r = await ctrl.importProfile(text, collision: choice);
    }
    if (r is ProfileImportRejected && context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Profile not imported'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [for (final i in (r as ProfileImportRejected).issues.take(30)) IssueLine.of(i)],
              ),
            ),
          ),
          actions: [NeonButton(label: 'Close', onPressed: () => Navigator.of(ctx).pop())],
        ),
      );
    } else if (r is ProfileImported && r.warnings.isNotEmpty) {
      activity.notify(NoticeKind.warning, 'Imported with ${r.warnings.length} warning(s): ${r.warnings.first}');
    }
  } catch (e) {
    activity.notify(NoticeKind.error, 'Profile import failed: $e');
  }
}

/// Validation message for profile names.
String? validateProfileName(String v) {
  final t = v.trim();
  if (t.isEmpty) return 'Enter a name';
  if (t.length > 80) return 'At most 80 characters';
  return null;
}

/// Counts shown for a profile's enabled packages.
String enabledSummary(ModProfile p) => '${p.enabledIds.length}/${p.mods.length} enabled';

/// Summary of manifest issues for badges.
String issueSummary(List<ModIssue> issues) {
  final e = issues.errors.length;
  final w = issues.warnings.length;
  if (e == 0 && w == 0) return 'VALID';
  return [if (e > 0) '$e ERR', if (w > 0) '$w WARN'].join(' ');
}
