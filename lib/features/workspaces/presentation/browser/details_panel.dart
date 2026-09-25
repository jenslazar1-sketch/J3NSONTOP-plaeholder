import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/platform/capabilities.dart';
import '../../../../core/platform/file_access.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../data/fs_listing.dart';
import '../shared/ws_widgets.dart';
import 'browser_actions.dart';

/// Facts and actions for the selected entry (side panel on wide layouts,
/// bottom sheet on phones).
class EntryDetails extends ConsumerStatefulWidget {
  const EntryDetails({super.key, required this.entry, required this.actions, this.onClose, this.inSheet = false});

  final FsEntry entry;
  final BrowserActions actions;
  final VoidCallback? onClose;

  /// Shown in a bottom sheet: the sheet closes before an action runs so it
  /// never shows a stale entry.
  final bool inSheet;

  @override
  ConsumerState<EntryDetails> createState() => _EntryDetailsState();
}

class _EntryDetailsState extends ConsumerState<EntryDetails> {
  Future<FileFacts>? _facts;
  String? _hash;
  String? _hashOpId;

  @override
  void initState() {
    super.initState();
    _inspect();
  }

  @override
  void didUpdateWidget(EntryDetails old) {
    super.didUpdateWidget(old);
    if (old.entry.path != widget.entry.path || old.entry.modified != widget.entry.modified) {
      _hash = null;
      _hashOpId = null;
      _inspect();
    }
  }

  void _inspect() {
    final e = widget.entry;
    _facts = e.isDirectory || e.isLink ? null : FileInspector.inspect(e.path);
  }

  Future<void> _computeHash() async {
    final h = await widget.actions.hash(widget.entry, (id) {
      if (mounted) setState(() => _hashOpId = id);
    });
    if (mounted) {
      setState(() {
        _hash = h;
        _hashOpId = null;
      });
    }
  }

  VoidCallback _act(VoidCallback f) => () {
    if (widget.inSheet) Navigator.of(context).pop();
    f();
  };

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final a = widget.actions;
    final caps = ref.watch(capabilitiesProvider);
    final rel = a.relative(e.path);
    return NeonPanel(
      kicker: e.category.label,
      title: e.name,
      icon: iconForCategory(e.category),
      actions: [
        if (widget.onClose != null)
          NeonIconButton(icon: Icons.close, tooltip: 'Close details', onPressed: widget.onClose),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeyValueTable(
            keyWidth: 96,
            rows: [
              ('Path', rel),
              if (!e.isDirectory) ('Size', '${Fmt.bytes(e.size)} (${e.size} bytes)'),
              ('Modified', e.modified == null ? 'unknown' : Fmt.dateTime(e.modified!)),
              if (!e.isDirectory) ('Extension', e.extension.isEmpty ? '(none)' : '.${e.extension}'),
              if (e.statError != null) ('Problem', e.statError!),
            ],
          ),
          if (_facts != null)
            FutureBuilder<FileFacts>(
              future: _facts,
              builder: (context, snap) {
                if (snap.hasError) return WsErrorBanner(error: snap.error!, action: 'Reading the file');
                final f = snap.data;
                if (f == null) return const Padding(padding: EdgeInsets.all(J3Space.sm), child: NeonProgressBar());
                return KeyValueTable(
                  keyWidth: 96,
                  rows: [
                    (
                      'Content',
                      f.isBinary
                          ? 'Binary data'
                          : 'Text${f.sampled ? ' (first ${Fmt.bytes(FileInspector.sampleBytes)} checked)' : ''}',
                    ),
                    if (!f.isBinary)
                      ('Encoding', '${f.encodingLabel}${f.malformed ? ' - contains invalid bytes' : ''}'),
                    if (!f.isBinary) ('Line endings', f.lineEndings ?? '-'),
                    if (!f.isBinary && f.lineCount != null) ('Lines', '${f.lineCount}${f.sampled ? '+' : ''}'),
                  ],
                );
              },
            ),
          if (!e.isDirectory && !e.isLink) ...[
            const SizedBox(height: J3Space.sm),
            if (_hashOpId != null)
              OperationProgress(operationId: _hashOpId!, label: 'Computing SHA-256')
            else if (_hash != null)
              Row(
                children: [
                  Expanded(
                    child: SelectableText('SHA-256 $_hash', style: J3Type.codeSmall.copyWith(color: J3Colors.text)),
                  ),
                  NeonIconButton(
                    icon: Icons.copy_rounded,
                    tooltip: 'Copy hash',
                    onPressed: () async {
                      await ref.read(fileAccessProvider).copyText(_hash!);
                      ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Hash copied');
                    },
                  ),
                ],
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: FitButton(
                  NeonButton.ghost(label: 'Compute SHA-256', icon: Icons.fingerprint, onPressed: _computeHash),
                ),
              ),
          ],
          const SizedBox(height: J3Space.md),
          ButtonWrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              if (!e.isDirectory && !e.isLink) ...[
                NeonButton(label: 'Edit text', icon: Icons.edit_note, onPressed: _act(() => a.openEditor(e))),
                NeonButton.secondary(label: 'Hex', icon: Icons.memory, onPressed: _act(() => a.openHex(e))),
                NeonButton.secondary(label: 'Export', icon: Icons.save_alt, onPressed: _act(() => a.export(e))),
              ],
              NeonButton.ghost(
                label: 'Rename',
                icon: Icons.drive_file_rename_outline,
                onPressed: _act(() => a.rename(e)),
              ),
              NeonIconButton(icon: Icons.copy_rounded, tooltip: 'Copy full path', onPressed: () => a.copyPath(e)),
              if (caps.supports(Capability.revealInFileManager))
                NeonIconButton(icon: Icons.open_in_new, tooltip: 'Show in file manager', onPressed: () => a.reveal(e)),
              NeonButton.danger(label: 'Delete', icon: Icons.delete_outline, onPressed: _act(() => a.delete(e))),
            ],
          ),
          if (!caps.supports(Capability.revealInFileManager)) ...[
            const SizedBox(height: J3Space.xs),
            Text(caps.alternativeFor(Capability.revealInFileManager) ?? '', style: J3Type.caption),
          ],
        ],
      ),
    );
  }
}
