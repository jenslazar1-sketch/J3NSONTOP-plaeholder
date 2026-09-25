/// The consistent editor layout of the Config Lab text tools:
///
/// * a document bar (file, encoding, dirty state, Open / Save / Save as),
/// * toolbar and status rows supplied by the tool,
/// * the editor and the tool's panes side by side on wide screens, or one
///   tab strip (Editor + panes) on phones.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/drafts/drafts.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/widgets/widgets.dart';
import '../document_io.dart';
import 'lab_widgets.dart';

const String kEditorPaneId = 'editor';

class ConfigWorkbench extends ConsumerWidget {
  const ConfigWorkbench({
    super.key,
    required this.toolId,
    required this.editor,
    required this.panes,
    this.header = const [],
    this.onLayout,
  });

  final String toolId;
  final Widget editor;
  final List<PaneSpec> panes;

  /// Rows above the editor (document bar, toolbar, status, errors).
  final List<Widget> header;

  /// Reports whether the side-by-side layout is used.
  final ValueChanged<bool>? onLayout;

  static String paneKey(String toolId) => '$toolId/pane';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stored = ref.watch(draftValueProvider(paneKey(toolId)));
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= J3Breakpoints.medium;
        // Phones start on the editor; wide layouts always show it.
        final selected = stored is String ? stored : (wide ? panes.first.id : kEditorPaneId);
        onLayout?.call(wide);
        void select(String id) => ref.setDraft(paneKey(toolId), id);
        final List<Widget> body;
        if (wide) {
          final pane = panes.firstWhere((p) => p.id == selected, orElse: () => panes.first);
          body = [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 5, child: editor),
                const SizedBox(width: J3Space.lg),
                Expanded(
                  flex: 6,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      PaneTabs(panes: panes, selected: pane.id, onSelected: select),
                      const SizedBox(height: J3Space.md),
                      KeyedSubtree(key: ValueKey('pane-${pane.id}'), child: pane.builder(context)),
                    ],
                  ),
                ),
              ],
            ),
          ];
        } else {
          final all = [
            PaneSpec(id: kEditorPaneId, label: 'Editor', icon: Icons.edit_note, builder: (_) => editor),
            ...panes,
          ];
          final pane = all.firstWhere((p) => p.id == selected, orElse: () => all.first);
          body = [
            PaneTabs(panes: all, selected: pane.id, onSelected: select),
            const SizedBox(height: J3Space.md),
            KeyedSubtree(key: ValueKey('pane-${pane.id}'), child: pane.builder(context)),
          ];
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final h in header) ...[h, const SizedBox(height: J3Space.md)],
            ...body,
          ],
        );
      },
    );
  }
}

/// File name, origin, encoding and dirty state plus Open / Save / Save as.
class DocumentBar extends ConsumerWidget {
  const DocumentBar({
    super.key,
    required this.docKey,
    required this.controller,
    required this.onOpen,
    required this.onSave,
    required this.onSaveAs,
    this.onClear,
    this.extra = const [],
  });

  final String docKey;
  final TextEditingController controller;
  final VoidCallback onOpen;
  final VoidCallback onSave;
  final VoidCallback onSaveAs;
  final VoidCallback? onClear;
  final List<Widget> extra;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(docSourceProvider(docKey));
    final fx = context.effects;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final dirty = source.isDirty(value.text);
        final hasText = value.text.isNotEmpty;
        final origin = source.path == null
            ? 'PASTED'
            : source.fromWorkspace
            ? 'WORKSPACE'
            : 'IMPORTED COPY';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(J3Space.sm),
              decoration: BoxDecoration(
                color: J3Colors.surfaceRaised,
                borderRadius: J3Radius.medium,
                border: Border.all(color: J3Colors.border),
              ),
              child: Wrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.description_outlined, size: 18, color: fx.accentText),
                      const SizedBox(width: J3Space.xs),
                      Flexible(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 260),
                          child: Text(
                            source.displayName,
                            style: J3Type.code.copyWith(color: J3Colors.text),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                  StatusBadge(kind: StatusKind.neutral, text: origin, dense: true),
                  StatusBadge(kind: StatusKind.neutral, text: source.encodingLabel, dense: true),
                  if (dirty)
                    const StatusBadge(kind: StatusKind.warning, text: 'MODIFIED', dense: true)
                  else if (source.savedText != null)
                    const StatusBadge(kind: StatusKind.success, text: 'SAVED', dense: true),
                  NeonButton.secondary(label: 'Open', icon: Icons.folder_open, dense: true, onPressed: onOpen),
                  NeonButton.secondary(
                    label: source.fromWorkspace ? 'Save' : 'Save…',
                    icon: Icons.save_outlined,
                    dense: true,
                    tooltip: source.fromWorkspace
                        ? 'Replace the workspace file (a backup is made first)'
                        : 'Choose where to save',
                    onPressed: hasText ? onSave : null,
                  ),
                  if (source.fromWorkspace)
                    NeonButton.ghost(
                      label: 'Save as…',
                      icon: Icons.save_as_outlined,
                      dense: true,
                      onPressed: hasText ? onSaveAs : null,
                    ),
                  if (onClear != null)
                    NeonButton.ghost(
                      label: 'Clear',
                      icon: Icons.backspace_outlined,
                      dense: true,
                      tooltip: 'Clear the editor',
                      onPressed: hasText ? onClear : null,
                    ),
                  ...extra,
                ],
              ),
            ),
            if (source.lastSave != null) ...[
              const SizedBox(height: J3Space.xs),
              SaveReceiptLine(receipt: source.lastSave!),
            ],
            if (source.malformed) ...[
              const SizedBox(height: J3Space.xs),
              const StatusBanner(
                kind: StatusKind.warning,
                title: 'Read as Latin-1',
                message:
                    'This file is not valid UTF-8, so it was decoded as Latin-1. Saving writes Latin-1 again; if '
                    'the text gains characters outside Latin-1, the whole file is written as UTF-8 instead.',
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Editor panel with a monospace [CodeField].
class EditorPanel extends StatelessWidget {
  const EditorPanel({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.kicker,
    this.hint,
    this.label,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String kicker;
  final String? hint;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return NeonPanel(
      kicker: kicker,
      padding: const EdgeInsets.all(J3Space.md),
      child: CodeField(
        controller: controller,
        focusNode: focusNode,
        label: label,
        hint: hint,
        minLines: 12,
        maxLines: 24,
        wrap: false,
      ),
    );
  }
}

/// Asks before throwing away unsaved text.
Future<bool> confirmClear(BuildContext context, {String what = 'the editor'}) => showJ3Confirm(
  context,
  title: 'Clear $what?',
  message: 'The text is removed from the editor. Files on disk are not touched.',
  confirmLabel: 'Clear',
  destructive: true,
);
