/// Document source tracking and the shared Open / Save / Save as flows of
/// the Config Lab editors.
///
/// * Files opened from the active workspace are saved back in place through
///   [WorkspaceFileWriter.replaceWithBackup] (after confirmation); the
///   backup location is shown afterwards.
/// * Anything else (pasted text, device imports) is saved with [saveOutput]
///   ("Save as"), which never overwrites silently.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/activity/activity_controller.dart';
import '../../../core/platform/file_access.dart';
import '../../../core/text/diff.dart';
import '../../../core/utils/safe_path.dart';
import '../../../core/utils/text_codec.dart';
import '../../../core/widgets/widgets.dart';
import '../../../core/workspace/file_backup.dart';
import '../../../core/workspace/workspace_controller.dart';
import '../data/config_file_io.dart';

/// Result of the last save of a document.
class SaveReceipt {
  const SaveReceipt({required this.at, required this.target, this.backupPath, this.backupDisplay});
  final DateTime at;

  /// Where the text went (workspace-relative path or export location).
  final String target;

  /// Absolute path of the backup of the replaced file (in-place saves).
  final String? backupPath;

  /// Backup path relative to the workspace metadata folder.
  final String? backupDisplay;
}

/// Where the text in an editor came from.
class DocSource {
  const DocSource({
    this.path,
    this.displayName = 'Untitled (pasted text)',
    this.fromWorkspace = false,
    this.encoding = TextEncodingKind.utf8,
    this.malformed = false,
    this.savedText,
    this.lastSave,
  });

  final String? path;
  final String displayName;
  final bool fromWorkspace;
  final TextEncodingKind encoding;
  final bool malformed;

  /// Text as last opened or saved (null for never-saved text).
  final String? savedText;
  final SaveReceipt? lastSave;

  bool isDirty(String text) => savedText == null ? text.isNotEmpty : text != savedText;

  String get encodingLabel => switch (encoding) {
    TextEncodingKind.utf8 => 'UTF-8',
    TextEncodingKind.utf8Bom => 'UTF-8 BOM',
    TextEncodingKind.utf16le => 'UTF-16 LE',
    TextEncodingKind.utf16be => 'UTF-16 BE',
    TextEncodingKind.latin1 => 'Latin-1',
  };

  DocSource copyWith({
    String? savedText,
    SaveReceipt? lastSave,
    String? path,
    String? displayName,
    bool? fromWorkspace,
  }) => DocSource(
    path: path ?? this.path,
    displayName: displayName ?? this.displayName,
    fromWorkspace: fromWorkspace ?? this.fromWorkspace,
    encoding: encoding,
    malformed: malformed,
    savedText: savedText ?? this.savedText,
    lastSave: lastSave ?? this.lastSave,
  );
}

class DocSourceController extends Notifier<DocSource> {
  DocSourceController(this.key);
  final String key;

  @override
  DocSource build() => const DocSource();

  void set(DocSource s) => state = s;
}

/// Source of the editor identified by `'<toolId>/<slot>'`.
final docSourceProvider = NotifierProvider.family<DocSourceController, DocSource, String>(DocSourceController.new);

/// Opens a file into [controller]. Returns the loaded text, or null when
/// cancelled or failed (failures are shown as a notice).
Future<String?> openIntoEditor(
  BuildContext context,
  WidgetRef ref, {
  required String docKey,
  required TextEditingController controller,
  List<String>? extensions,
  String title = 'Open file',
}) async {
  final source = ref.read(docSourceProvider(docKey));
  if (source.isDirty(controller.text) && controller.text.trim().isNotEmpty) {
    final ok = await showJ3Confirm(
      context,
      title: 'Replace the current text?',
      message: 'The editor has unsaved changes. Opening a file replaces them.',
      confirmLabel: 'Open anyway',
      destructive: true,
    );
    if (!ok || !context.mounted) return null;
  }
  final picked = await pickInputFile(context, ref, extensions: extensions, title: title);
  if (picked == null) return null;
  final activity = ref.read(activityProvider.notifier);
  try {
    final loaded = await loadTextFile(picked.path);
    controller.value = TextEditingValue(text: loaded.text, selection: const TextSelection.collapsed(offset: 0));
    ref
        .read(docSourceProvider(docKey).notifier)
        .set(
          DocSource(
            path: picked.path,
            displayName: picked.displayName,
            fromWorkspace: picked.fromWorkspace,
            encoding: loaded.encoding,
            malformed: loaded.malformed,
            savedText: loaded.text,
          ),
        );
    if (loaded.malformed) {
      activity.notify(
        NoticeKind.warning,
        '${picked.displayName} is not valid UTF-8; it was read as Latin-1 and will be saved in that encoding where possible.',
      );
    }
    return loaded.text;
  } catch (e) {
    activity.notify(NoticeKind.error, 'Could not open ${picked.displayName}: $e');
    return null;
  }
}

/// Opens a file and returns its text without binding it to an editor (for
/// secondary inputs such as "From JSON" panes or schemas).
Future<(String text, SelectedInput file)?> readInputFile(
  BuildContext context,
  WidgetRef ref, {
  List<String>? extensions,
  String title = 'Open file',
}) async {
  final picked = await pickInputFile(context, ref, extensions: extensions, title: title);
  if (picked == null) return null;
  try {
    final loaded = await loadTextFile(picked.path);
    return (loaded.text, picked);
  } catch (e) {
    ref.read(activityProvider.notifier).notify(NoticeKind.error, 'Could not open ${picked.displayName}: $e');
    return null;
  }
}

/// Loads [path] (already known, e.g. a sample file) into an editor.
Future<bool> loadPathIntoEditor(
  WidgetRef ref, {
  required String docKey,
  required TextEditingController controller,
  required String path,
  required String displayName,
  required bool fromWorkspace,
}) async {
  try {
    final loaded = await loadTextFile(path);
    controller.value = TextEditingValue(text: loaded.text, selection: const TextSelection.collapsed(offset: 0));
    ref
        .read(docSourceProvider(docKey).notifier)
        .set(
          DocSource(
            path: path,
            displayName: displayName,
            fromWorkspace: fromWorkspace,
            encoding: loaded.encoding,
            malformed: loaded.malformed,
            savedText: loaded.text,
          ),
        );
    return true;
  } catch (e) {
    ref.read(activityProvider.notifier).notify(NoticeKind.error, 'Could not open $displayName: $e');
    return false;
  }
}

/// Saves [text] for the document [docKey].
///
/// In-place when the document came from the active workspace (unless
/// [saveAs]); otherwise through the Save-as flow. Returns true when saved.
Future<bool> saveDocument(
  BuildContext context,
  WidgetRef ref, {
  required String toolId,
  required String docKey,
  required String text,
  required String suggestedName,
  String mimeType = 'text/plain',
  bool saveAs = false,
}) async {
  final source = ref.read(docSourceProvider(docKey));
  final ws = ref.read(activeWorkspaceProvider);
  final activity = ref.read(activityProvider.notifier);
  final bytes = TextCodec.encode(text, source.encoding);
  final inPlace =
      !saveAs &&
      source.fromWorkspace &&
      source.path != null &&
      ws != null &&
      SafePath.isWithin(ws.rootPath, source.path!);

  if (inPlace) {
    final rel = p.relative(source.path!, from: ws.rootPath).replaceAll('\\', '/');
    final diff = source.savedText == null ? null : LineDiff.diffText(source.savedText!, text);
    final ok = await showJ3Confirm(
      context,
      title: 'Replace $rel?',
      message:
          'The file in workspace "${ws.name}" is replaced. Its current content is copied to the workspace backup folder first, so this can be undone.',
      confirmLabel: 'Save with backup',
      details: [
        if (diff != null) '${diff.insertions} line(s) added, ${diff.deletions} line(s) removed',
        'Encoding: ${source.encodingLabel}',
      ],
    );
    if (!ok || !context.mounted) return false;
    final metaDir = ref.read(workspacesProvider.notifier).metaDir(ws);
    final writer = WorkspaceFileWriter(workspace: ws, metaDir: metaDir);
    try {
      final result = await activity.run<BackupWriteResult>(
        toolId: toolId,
        title: 'Save $rel',
        workspaceId: ws.id,
        body: (op) => writer.replaceWithBackup(source.path!, bytes),
        summary: (r) => r.backupPath == null ? 'Saved $rel (new file)' : 'Saved $rel; previous version backed up',
        counts: (r) => {'bytes': bytes.length},
      );
      final backupDisplay = result.backupPath == null
          ? null
          : p.relative(result.backupPath!, from: metaDir).replaceAll('\\', '/');
      ref
          .read(docSourceProvider(docKey).notifier)
          .set(
            source.copyWith(
              savedText: text,
              lastSave: SaveReceipt(
                at: DateTime.now(),
                target: rel,
                backupPath: result.backupPath,
                backupDisplay: backupDisplay,
              ),
            ),
          );
      return true;
    } catch (_) {
      // The failure is recorded and shown by the activity controller.
      return false;
    }
  }

  final where = await saveOutput(
    context,
    ref,
    suggestedName: suggestedName,
    bytes: bytes,
    mimeType: mimeType,
    toolId: toolId,
    defaultWorkspaceSubdir: source.fromWorkspace && source.path != null && ws != null
        ? p.relative(p.dirname(source.path!), from: ws.rootPath)
        : null,
  );
  if (where == null) return false;
  var next = source.copyWith(
    savedText: text,
    lastSave: SaveReceipt(at: DateTime.now(), target: where),
  );
  // A save into the workspace becomes the document's new home, so later
  // saves replace it in place (with backups).
  if (ws != null && !p.isAbsolute(where) && where != 'shared') {
    final candidate = p.join(ws.rootPath, where);
    final f = File(candidate);
    if (SafePath.isWithin(ws.rootPath, candidate) && f.existsSync() && _sameBytes(f.readAsBytesSync(), bytes)) {
      next = next.copyWith(path: candidate, displayName: where, fromWorkspace: true);
    }
  }
  ref.read(docSourceProvider(docKey).notifier).set(next);
  return true;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Copies [text] and confirms with a notice.
Future<void> copyWithNotice(WidgetRef ref, String text, String what) async {
  await ref.read(fileAccessProvider).copyText(text);
  ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Copied $what');
}
