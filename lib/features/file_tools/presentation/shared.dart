import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/activity/activity_controller.dart';
import '../../../core/activity/operation.dart';
import '../../../core/platform/app_paths.dart';
import '../../../core/platform/file_access.dart';
import '../../../core/tasks/cancellation.dart';
import '../../../core/theme/effects.dart';
import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/text_codec.dart';
import '../../../core/widgets/widgets.dart';
import '../../../core/workspace/workspace.dart';
import '../../../core/workspace/workspace_controller.dart';
import '../domain/file_walker.dart';
import '../domain/glob.dart';

/// Whether a text tool works on pasted text or on files.
enum TextOrFiles {
  text('Text'),
  files('Files');

  const TextOrFiles(this.label);
  final String label;
}

String lineEndingChoiceLabel(LineEnding e) => switch (e) {
  LineEnding.lf => 'LF (Linux, macOS)',
  LineEnding.crlf => 'CRLF (Windows)',
  LineEnding.cr => 'CR (classic Mac)',
  _ => e.label,
};

/// A file chosen as input for a File Tools operation.
@immutable
class FileItem {
  const FileItem({required this.path, required this.label, required this.inWorkspace, required this.size});

  final String path;

  /// Workspace-relative path (forward slashes) or the device file name.
  final String label;

  /// True for files inside the active workspace (can be changed in place
  /// with a backup). False for device imports, which are app-owned copies.
  final bool inWorkspace;
  final int size;

  @override
  bool operator ==(Object other) => other is FileItem && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// Adds [more] to [current] without duplicates (by path), keeping order.
List<FileItem> mergeFileItems(List<FileItem> current, Iterable<FileItem> more) {
  final seen = {for (final f in current) f.path};
  return [
    ...current,
    for (final m in more)
      if (seen.add(m.path)) m,
  ];
}

String workspaceLabel(Workspace ws, String path) => p.relative(path, from: ws.rootPath).replaceAll('\\', '/');

/// Lets the user browse the active workspace for one file.
Future<FileItem?> pickWorkspaceFile(
  BuildContext context,
  WidgetRef ref, {
  List<String>? extensions,
  String title = 'Choose a file',
}) async {
  final ws = ref.read(activeWorkspaceProvider);
  if (ws == null) return null;
  final path = await showWorkspaceBrowser(context, workspace: ws, extensions: extensions, title: title);
  if (path == null) return null;
  return FileItem(path: path, label: workspaceLabel(ws, path), inWorkspace: true, size: await File(path).length());
}

/// Lets the user choose a folder in the active workspace. Returns the
/// absolute path, or null.
Future<String?> pickWorkspaceFolder(BuildContext context, WidgetRef ref, {String title = 'Choose a folder'}) async {
  final ws = ref.read(activeWorkspaceProvider);
  if (ws == null) return null;
  return showWorkspaceBrowser(context, workspace: ws, mode: BrowseMode.pickFolder, title: title);
}

/// Imports files from the device via the system picker (copied into the
/// app's picked-files folder under [toolKey]).
Future<List<FileItem>> pickDeviceFiles(
  WidgetRef ref, {
  required String toolKey,
  bool multiple = true,
  List<String>? extensions,
}) async {
  try {
    final dest = p.join(ref.read(appPathsProvider).pickedDir, toolKey.replaceAll('.', '_'));
    final picked = await ref
        .read(fileAccessProvider)
        .pickFiles(multiple: multiple, extensions: extensions, destinationDir: dest);
    return [for (final f in picked) FileItem(path: f.path, label: f.name, inWorkspace: false, size: f.size)];
  } catch (e) {
    ref.read(activityProvider.notifier).notify(NoticeKind.error, 'Could not open the file picker: $e');
    return const [];
  }
}

/// Lists every file below [folder] as workspace items (symbolic links are
/// skipped). Capped at [maxFiles]; the returned flag tells when it was hit.
Future<(List<FileItem>, WalkResult)> filesInFolder(
  Workspace ws,
  String folder, {
  GlobFilter filter = GlobFilter.all,
  int maxFiles = 5000,
  CancellationToken? token,
}) async {
  final walk = await walkFolder(folder, filter: filter, maxFiles: maxFiles, token: token);
  return (
    [
      for (final f in walk.files)
        FileItem(path: f.path, label: workspaceLabel(ws, f.path), inWorkspace: true, size: f.size),
    ],
    walk,
  );
}

/// Calls [OperationHandle.progress] at most every ~100 ms or 1 % so busy
/// loops do not flood the activity list with rebuilds.
class ProgressThrottle {
  ProgressThrottle(this.op);
  final OperationHandle op;
  final Stopwatch _sw = Stopwatch()..start();
  double? _last;

  void report(double? fraction, [String? message]) {
    final elapsed = _sw.elapsedMilliseconds;
    final bigStep = fraction != null && _last != null && (fraction - _last!).abs() >= 0.01;
    if (elapsed < 100 && !(bigStep && elapsed >= 16)) return;
    _sw.reset();
    _last = fraction;
    op.progress(fraction, message);
  }
}

/// Live progress for a running activity operation, with a working Cancel.
class OperationProgressPanel extends ConsumerWidget {
  const OperationProgressPanel({super.key, required this.operationId, required this.label, this.detail});

  final String? operationId;
  final String label;

  /// Extra line under the bar (e.g. per-file progress).
  final Widget? detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = operationId;
    if (id == null) return const SizedBox.shrink();
    final op = ref.watch(activityProvider.select((s) => s.operations.firstWhereOrNull((o) => o.id == id)));
    if (op == null || op.status != OperationStatus.running) return const SizedBox.shrink();
    return NeonPanel(
      kicker: 'RUNNING',
      title: op.title,
      icon: Icons.sync,
      padding: const EdgeInsets.fromLTRB(J3Space.lg, J3Space.lg, J3Space.lg, J3Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LoadingState(
            label: op.progressMessage ?? label,
            progress: op.progress,
            onCancel: op.cancellable ? () => ref.read(activityProvider.notifier).cancel(op.id) : null,
          ),
          ?detail,
        ],
      ),
    );
  }
}

/// Shown when a tool needs the active workspace.
class NoWorkspaceNotice extends StatelessWidget {
  const NoWorkspaceNotice({super.key, required this.what});
  final String what;

  @override
  Widget build(BuildContext context) {
    return NeonPanel(
      emphasis: PanelEmphasis.subtle,
      child: EmptyState(
        glyph: '[ ?_? ]',
        title: 'No active workspace',
        message:
            '$what needs a workspace. Create or open one in the Workspaces section - the "Neon Dungeon" '
            'sample workspace has logs, duplicates and config files to try this on.',
      ),
    );
  }
}

/// Include / exclude glob inputs with inline validation.
class GlobFields extends StatelessWidget {
  const GlobFields({super.key, required this.include, required this.exclude});

  final TextEditingController include;
  final TextEditingController exclude;

  @override
  Widget build(BuildContext context) {
    Widget field(TextEditingController c, String label, String hint) => ValueListenableBuilder<TextEditingValue>(
      valueListenable: c,
      builder: (context, v, _) => TextField(
        controller: c,
        style: J3Type.code,
        decoration: InputDecoration(labelText: label, hintText: hint, errorText: GlobFilter.validate(v.text)),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field(include, 'Include (globs, comma separated)', '*.txt, config/**/*.{ini,json}'),
        const SizedBox(height: J3Space.sm),
        field(exclude, 'Exclude', '.git, node_modules, *.bak'),
        const SizedBox(height: J3Space.xs),
        Text(
          'Patterns without "/" match names at any depth; "**" spans folders. Empty include = all files.',
          style: J3Type.caption,
        ),
      ],
    );
  }
}

/// Compact metric: icon + label + value (never colour alone).
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.icon, this.color});
  final String label;
  final String value;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? J3Colors.textSecondary;
    return Container(
      constraints: const BoxConstraints(minWidth: 96),
      padding: const EdgeInsets.symmetric(horizontal: J3Space.md, vertical: J3Space.sm),
      decoration: BoxDecoration(
        color: J3Colors.surfaceRaised,
        borderRadius: J3Radius.small,
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 14, color: c), const SizedBox(width: 4)],
              Flexible(
                child: Text(
                  label,
                  style: J3Type.caption.copyWith(color: c),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Text(value, style: J3Type.subtitle.copyWith(fontFamily: J3Type.mono)),
        ],
      ),
    );
  }
}

/// A list that renders inline when short and virtualises when long.
class BoundedList extends StatelessWidget {
  const BoundedList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.maxHeight = 420,
    this.inlineUpTo = 40,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double maxHeight;
  final int inlineUpTo;

  @override
  Widget build(BuildContext context) {
    if (itemCount <= inlineUpTo) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (var i = 0; i < itemCount; i++) itemBuilder(context, i)],
      );
    }
    return SizedBox(
      height: maxHeight,
      child: Scrollbar(
        child: ListView.builder(itemCount: itemCount, itemBuilder: itemBuilder),
      ),
    );
  }
}

/// Selected input files with per-row remove buttons.
class FileItemList extends StatelessWidget {
  const FileItemList({super.key, required this.items, required this.onRemove, this.trailing});

  final List<FileItem> items;
  final ValueChanged<FileItem>? onRemove;
  final Widget Function(FileItem item)? trailing;

  @override
  Widget build(BuildContext context) {
    final total = items.fold<int>(0, (s, f) => s + f.size);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${Fmt.count(items.length, 'file')} · ${Fmt.bytes(total)}', style: J3Type.caption),
        const SizedBox(height: J3Space.xs),
        BoundedList(
          itemCount: items.length,
          maxHeight: 280,
          inlineUpTo: 12,
          itemBuilder: (context, i) {
            final f = items[i];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    f.inWorkspace ? Icons.folder_special_outlined : Icons.phone_android_outlined,
                    size: 16,
                    color: J3Colors.textMuted,
                    semanticLabel: f.inWorkspace ? 'workspace file' : 'device copy',
                  ),
                  const SizedBox(width: J3Space.sm),
                  Expanded(
                    child: Text(f.label, style: J3Type.codeSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                  Text(Fmt.bytes(f.size), style: J3Type.caption),
                  ?trailing?.call(f),
                  if (onRemove != null)
                    IconButton(
                      tooltip: 'Remove ${f.label}',
                      onPressed: () => onRemove!(f),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// A wrapping row of controls at their natural width. `NeonButton` fills
/// all available width under loose constraints, so inside a plain [Wrap]
/// every button would take a whole line; [IntrinsicWidth] keeps them
/// compact (and still shrinks them, with ellipsis, on narrow screens).
class ButtonWrap extends StatelessWidget {
  const ButtonWrap({
    super.key,
    required this.children,
    this.spacing = J3Space.sm,
    this.runSpacing = J3Space.sm,
    this.crossAxisAlignment = WrapCrossAlignment.center,
  });

  final List<Widget> children;
  final double spacing;
  final double runSpacing;
  final WrapCrossAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: spacing,
      runSpacing: runSpacing,
      crossAxisAlignment: crossAxisAlignment,
      children: [for (final c in children) IntrinsicWidth(child: c)],
    );
  }
}

/// Transparent Material so ListTile-based controls (OptionSwitch,
/// ExpansionTile) paint their ink above a NeonPanel's background instead of
/// underneath it.
class InkSurface extends StatelessWidget {
  const InkSurface({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(type: MaterialType.transparency, child: child);
}

/// Short "Paths relative to X" style caption with an icon.
class InfoLine extends StatelessWidget {
  const InfoLine(this.text, {super.key, this.icon = Icons.info_outline});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 14, color: context.effects.accentText),
        ),
        const SizedBox(width: J3Space.xs),
        Expanded(child: Text(text, style: J3Type.caption)),
      ],
    );
  }
}

/// Human message for an error thrown by an operation.
String describeError(Object e) {
  if (e is FileSystemException) {
    final os = e.osError?.message;
    return '${e.message}${e.path == null ? '' : ': ${e.path}'}${os == null ? '' : ' ($os)'}';
  }
  if (e is FormatException) return e.message;
  return e.toString();
}
