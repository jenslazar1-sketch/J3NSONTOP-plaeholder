import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/utils/text_codec.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/file_backup.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../domain/fs_errors.dart';
import '../../domain/line_endings.dart';
import '../shared/requests.dart';
import '../shared/ws_widgets.dart';
import 'editor_state.dart';

class TextEditorPage extends ConsumerStatefulWidget {
  const TextEditorPage({super.key});

  @override
  ConsumerState<TextEditorPage> createState() => _TextEditorPageState();
}

class _TextEditorPageState extends ConsumerState<TextEditorPage> {
  final GlobalKey _editorKey = GlobalKey();
  final FocusNode _editorFocus = FocusNode(debugLabel: 'editor');
  final FocusNode _findFocus = FocusNode(debugLabel: 'editor-find');
  final ScrollController _largeScroll = ScrollController();
  Timer? _findDebounce;
  bool _saving = false;

  // Resolved once: flows continue after awaits (saves) and must not depend
  // on the widget still being mounted.
  late final TextEditingController _find = ref.read(draftTextProvider('${WsTools.editor}/find'));
  late final EditorController _ctrl = ref.read(editorProvider.notifier);

  /// Cached: `ref` may not be used in dispose().
  late final HighlightController _text = ref.read(editorTextProvider);

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _findDebounce?.cancel();
    _text.removeListener(_onTextChanged);
    _editorFocus.dispose();
    _findFocus.dispose();
    _largeScroll.dispose();
    super.dispose();
  }

  String _lastText = '';

  void _onTextChanged() {
    final t = _text.text;
    if (identical(t, _lastText) || t == _lastText) return;
    _lastText = t;
    if (ref.read(editorProvider).findOpen) _scheduleFind();
  }

  void _scheduleFind() {
    _findDebounce?.cancel();
    _findDebounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) _ctrl.updateMatches(_find.text);
    });
  }

  // ---- opening ----------------------------------------------------------

  Future<bool> _confirmDiscard() async {
    if (!_ctrl.isDirty) return true;
    return showJ3Confirm(
      context,
      title: 'Discard unsaved changes?',
      message: 'The open file has changes that are not saved.',
      confirmLabel: 'Discard',
      destructive: true,
    );
  }

  Future<void> _pick() async {
    if (!await _confirmDiscard() || !mounted) return;
    final input = await pickInputFile(context, ref, title: 'Open in Text Editor');
    if (input == null) return;
    await _ctrl.open(input.path);
  }

  void _maybeHandleRequest() {
    if (!ref.read(editorRequestProvider.notifier).hasPending) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final req = ref.read(editorRequestProvider.notifier).claim();
      if (req == null) return;
      final doc = ref.read(editorProvider).doc;
      if (doc != null && doc.path == req.path && !_ctrl.isDirty) {
        // Same file already open: just jump.
        if (req.line != null) _revealLine(req.line!, req.column ?? 1);
        return;
      }
      if (!await _confirmDiscard()) return;
      await _ctrl.open(req.path, line: req.line);
    });
  }

  // ---- navigation inside the text --------------------------------------

  EditableTextState? _editable() {
    EditableTextState? found;
    void visit(Element e) {
      if (found != null) return;
      if (e is StatefulElement && e.state is EditableTextState) {
        found = e.state as EditableTextState;
        return;
      }
      e.visitChildren(visit);
    }

    final ctx = _editorKey.currentContext;
    if (ctx is Element) ctx.visitChildren(visit);
    return found;
  }

  /// Whole pixels: fractional extents lose precision with 100k+ rows.
  double _lineExtent(BuildContext context) =>
      (MediaQuery.textScalerOf(context).scale(J3Type.code.fontSize!) * 1.45 + 2).ceilToDouble();

  void _revealLine(int line, int column) {
    final doc = ref.read(editorProvider).doc;
    if (doc == null) return;
    if (doc.lines != null) {
      final idx = (line - 1).clamp(0, doc.lines!.length - 1);
      if (_largeScroll.hasClients) {
        _largeScroll.jumpTo((idx * _lineExtent(context)).clamp(0, _largeScroll.position.maxScrollExtent));
      }
      return;
    }
    _text.jumpTo(line, column);
    final pos = _text.selection.base;
    WidgetsBinding.instance.addPostFrameCallback((_) => _editable()?.bringIntoView(pos));
  }

  void _revealCurrentMatch() {
    final s = ref.read(editorProvider);
    if (s.current < 0 || s.matches.isEmpty) return;
    final doc = s.doc;
    if (doc == null) return;
    if (doc.lines != null) {
      _revealLine(s.matches[s.current] + 1, 1);
    } else {
      final pos = TextPosition(offset: s.matches[s.current]);
      WidgetsBinding.instance.addPostFrameCallback((_) => _editable()?.bringIntoView(pos));
    }
  }

  void _openFind() {
    final sel = _text.selection;
    if (sel.isValid && !sel.isCollapsed && sel.end - sel.start < 200) {
      final t = sel.textInside(_text.text);
      if (!t.contains('\n')) _find.text = t;
    }
    _ctrl.setFindOpen(true);
    _ctrl.updateMatches(_find.text);
    _findFocus.requestFocus();
    _find.selection = TextSelection(baseOffset: 0, extentOffset: _find.text.length);
  }

  void _step(int delta) {
    _ctrl.step(delta, _find.text);
    _revealCurrentMatch();
  }

  Future<void> _goToLine() async {
    final doc = ref.read(editorProvider).doc;
    if (doc == null) return;
    final count = doc.lines?.length ?? TextCodec.splitLines(_text.text).length;
    final v = await showJ3TextInput(
      context,
      title: 'Go to line',
      label: 'Line (1-$count)',
      monospace: true,
      validator: (v) {
        final n = int.tryParse(v.trim());
        if (n == null || n < 1 || n > count) return 'Enter a line between 1 and $count';
        return null;
      },
    );
    if (v == null) return;
    _revealLine(int.parse(v.trim()), 1);
    if (doc.lines == null) _editorFocus.requestFocus();
  }

  // ---- saving ------------------------------------------------------------

  Future<void> _save() async {
    final s = ref.read(editorProvider);
    final doc = s.doc;
    if (doc == null || doc.readOnly || _saving) return;
    final ws = _ctrl.workspaceOf(doc.path);
    if (ws == null) {
      final saveAs = await showJ3Confirm(
        context,
        title: 'This is a copy',
        message:
            'This file was imported from your device, so the editor only has a copy in app storage. '
            'Saving here cannot change the original. Use "Save as" to export the edited file.',
        confirmLabel: 'Save as...',
      );
      if (saveAs) await _saveAs();
      return;
    }
    final activity = ref.read(activityProvider.notifier);
    try {
      final f = File(doc.path);
      final stat = await f.stat();
      if (!mounted) return;
      if (stat.type == FileSystemEntityType.file &&
          (stat.size != doc.sizeOnDisk || stat.modified != doc.modifiedOnDisk)) {
        final ok = await showJ3Confirm(
          context,
          title: 'File changed on disk',
          message:
              'Another program changed "${p.basename(doc.path)}" after you opened it. Overwrite it with '
              'your version? The version on disk is backed up first.',
          confirmLabel: 'Overwrite',
          destructive: true,
        );
        if (!ok) return;
      }
      final normalized = LineEndings.normalize(_text.text);
      final out = LineEndings.apply(normalized, s.saveEnding);
      if (doc.encoding == TextEncodingKind.latin1 && out.codeUnits.any((c) => c > 255)) {
        if (!mounted) return;
        final ok = await showJ3Confirm(
          context,
          title: 'Encoding changes',
          message:
              'The text now contains characters that Latin-1 cannot store, so the file will be saved as UTF-8. '
              'Other programs may read it differently.',
          confirmLabel: 'Save as UTF-8',
        );
        if (!ok) return;
      }
      final bytes = TextCodec.encode(out, doc.encoding);
      setState(() => _saving = true);
      final writer = WorkspaceFileWriter(workspace: ws, metaDir: ref.read(workspacesProvider.notifier).metaDir(ws));
      final result = await activity.run<BackupWriteResult>(
        toolId: WsTools.editor,
        title: 'Save ${p.basename(doc.path)}',
        workspaceId: ws.id,
        body: (_) => writer.replaceWithBackup(doc.path, bytes),
        summary: (r) => r.backupPath == null
            ? 'Saved ${Fmt.bytes(bytes.length)}'
            : 'Saved ${Fmt.bytes(bytes.length)}; previous version backed up',
      );
      final after = await File(doc.path).stat();
      _ctrl.markSaved(normalized, after.size, after.modified);
      if (_text.text != normalized) _text.text = normalized;
      if (result.backupPath != null) {
        activity.notify(NoticeKind.info, 'Backup: ${p.relative(result.backupPath!, from: writer.backupsRoot)}');
      }
    } catch (e) {
      await _cleanupTemp(doc.path);
      final f = describeError(e, action: 'Saving');
      activity.notify(NoticeKind.error, 'Save failed: ${f.message}${f.hint == null ? '' : ' ${f.hint}'}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _cleanupTemp(String path) async {
    try {
      final t = File('$path.tmp');
      if (await t.exists()) await t.delete();
    } catch (_) {
      // Best effort.
    }
  }

  Future<void> _saveAs() async {
    final s = ref.read(editorProvider);
    final doc = s.doc;
    if (doc == null) return;
    final text = doc.readOnly ? (doc.lines ?? const []).join('\n') : LineEndings.normalize(_text.text);
    final bytes = TextCodec.encode(LineEndings.apply(text, s.saveEnding), doc.encoding);
    await saveOutput(context, ref, suggestedName: p.basename(doc.path), bytes: bytes, toolId: WsTools.editor);
  }

  Future<void> _revert() async {
    final doc = ref.read(editorProvider).doc;
    if (doc == null) return;
    if (_ctrl.isDirty) {
      final ok = await showJ3Confirm(
        context,
        title: 'Revert to the saved file?',
        message: 'Your unsaved changes are discarded and the file is reloaded from disk.',
        confirmLabel: 'Revert',
        destructive: true,
      );
      if (!ok) return;
    }
    await _ctrl.open(doc.path);
  }

  // ---- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(editorProvider);
    ref.watch(editorRequestProvider);
    _maybeHandleRequest();
    if (s.pendingLine != null && s.doc != null) {
      final line = s.pendingLine!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _ctrl.consumePendingLine();
        _revealLine(line, 1);
      });
    }
    final doc = s.doc;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _openFind,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyG, control: true): _goToLine,
        const SingleActivator(LogicalKeyboardKey.f3): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.f3, shift: true): () => _step(-1),
      },
      child: ToolScaffold(
        toolId: WsTools.editor,
        headerActions: [NeonIconButton(icon: Icons.file_open_outlined, tooltip: 'Open file', onPressed: _pick)],
        children: [
          if (s.error != null) WsErrorBanner(error: s.error!, action: 'Opening the file', onDismiss: _ctrl.clearError),
          if (s.binaryPath != null)
            WsBanner(
              kind: StatusKind.warning,
              title: 'This looks like a binary file',
              message: '${p.basename(s.binaryPath!)} contains binary data. Editing it as text would corrupt it.',
              actions: [
                NeonButton(
                  label: 'Open in Hex Viewer',
                  icon: Icons.memory,
                  onPressed: () {
                    final path = s.binaryPath!;
                    _ctrl.dismissBinary();
                    ref.openInHex(context, path);
                  },
                ),
                NeonButton.secondary(
                  label: 'View as text (read-only)',
                  onPressed: () => _ctrl.open(s.binaryPath!, forceText: true),
                ),
              ],
              onDismiss: _ctrl.dismissBinary,
            ),
          if (s.loading) const LoadingState(label: 'Reading file...'),
          if (doc == null && !s.loading)
            NeonPanel(
              emphasis: PanelEmphasis.subtle,
              child: EmptyState(
                glyph: '[ _ ]',
                title: 'No file open',
                message:
                    'Open a text, config or log file from the active workspace or from your device. '
                    'Files up to ${kEditableLimit ~/ (1024 * 1024)} MiB are editable; larger ones open read-only.',
                action: FitButton(NeonButton(label: 'Open file', icon: Icons.file_open_outlined, onPressed: _pick)),
              ),
            ),
          if (doc != null) ...[
            _DocHeader(
              doc: doc,
              state: s,
              saving: _saving,
              onSave: _save,
              onSaveAs: _saveAs,
              onRevert: _revert,
              onFind: _openFind,
              onGoTo: _goToLine,
              onClose: () async {
                if (await _confirmDiscard()) _ctrl.close();
              },
            ),
            ..._warnings(doc),
            if (s.findOpen) _findBar(s),
            SizedBox(
              height: listViewportHeight(context, fraction: 0.7, min: 260, max: 1000),
              child: doc.lines != null
                  ? _LargeView(
                      lines: doc.lines!,
                      controller: _largeScroll,
                      extent: _lineExtent(context),
                      currentLine: s.findOpen && s.current >= 0 && s.matches.isNotEmpty ? s.matches[s.current] : null,
                    )
                  : KeyedSubtree(
                      key: _editorKey,
                      child: CodeField(controller: _text, focusNode: _editorFocus, expands: true, hint: 'Empty file'),
                    ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _warnings(EditorDoc doc) {
    final ws = _ctrl.workspaceOf(doc.path);
    return [
      if (ws == null)
        const WsBanner(
          kind: StatusKind.info,
          title: 'Device copy',
          message:
              'This file was imported from your device; the editor works on a copy in app storage. '
              'Use "Save as" to export your edits.',
        ),
      if (doc.readOnly) WsBanner(kind: StatusKind.info, title: 'Read-only', message: doc.readOnlyReason),
      if (doc.malformed)
        WsBanner(
          kind: StatusKind.warning,
          title: 'Invalid bytes for ${doc.encodingLabel.replaceAll(' (fallback)', '')}',
          message: doc.encoding == TextEncodingKind.latin1
              ? 'The file is not valid UTF-8, so it was decoded as Latin-1. Saving keeps Latin-1, but if you add '
                    'characters Latin-1 cannot store the file is re-encoded as UTF-8, which changes bytes.'
              : 'The file has an incomplete trailing byte. Saving re-encodes it and will change bytes you did not edit.',
        ),
      if (doc.endings.kind == LineEnding.mixed)
        WsBanner(
          kind: StatusKind.warning,
          title: 'Mixed line endings',
          message:
              '${doc.endings.describe()}. Saving writes one style for every line '
              '(currently ${ref.read(editorProvider).saveEnding.label}).',
        ),
    ];
  }

  Widget _findBar(EditorState s) {
    final count = s.matches.isEmpty
        ? 'No matches'
        : '${s.current + 1} / ${s.matches.length}${s.matches.length >= 10000 ? '+' : ''}';
    return NeonPanel(
      padding: const EdgeInsets.all(J3Space.sm),
      child: ButtonWrap(
        spacing: J3Space.sm,
        runSpacing: J3Space.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 240,
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter, shift: true): () => _step(-1),
                const SingleActivator(LogicalKeyboardKey.escape): () => _ctrl.setFindOpen(false),
              },
              child: TextField(
                controller: _find,
                focusNode: _findFocus,
                style: J3Type.code,
                decoration: const InputDecoration(labelText: 'Find', prefixIcon: Icon(Icons.search, size: 18)),
                onChanged: (_) => _scheduleFind(),
                onSubmitted: (_) {
                  _step(1);
                  _findFocus.requestFocus();
                },
                onEditingComplete: () {},
              ),
            ),
          ),
          FilterChip(
            label: const Text('Aa'),
            tooltip: 'Match case',
            selected: s.caseSensitive,
            onSelected: (v) {
              _ctrl.setCaseSensitive(v);
              _ctrl.updateMatches(_find.text);
            },
          ),
          Semantics(liveRegion: true, child: Text(count, style: J3Type.codeSmall)),
          NeonIconButton(
            icon: Icons.keyboard_arrow_up,
            tooltip: 'Previous match (Shift+Enter)',
            onPressed: () => _step(-1),
          ),
          NeonIconButton(icon: Icons.keyboard_arrow_down, tooltip: 'Next match (Enter)', onPressed: () => _step(1)),
          NeonIconButton(icon: Icons.close, tooltip: 'Close find (Esc)', onPressed: () => _ctrl.setFindOpen(false)),
        ],
      ),
    );
  }
}

class _DocHeader extends ConsumerWidget {
  const _DocHeader({
    required this.doc,
    required this.state,
    required this.saving,
    required this.onSave,
    required this.onSaveAs,
    required this.onRevert,
    required this.onFind,
    required this.onGoTo,
    required this.onClose,
  });

  final EditorDoc doc;
  final EditorState state;
  final bool saving;
  final VoidCallback onSave;
  final VoidCallback onSaveAs;
  final VoidCallback onRevert;
  final VoidCallback onFind;
  final VoidCallback onGoTo;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = ref.watch(editorTextProvider);
    final fx = context.effects;
    return NeonPanel(
      padding: const EdgeInsets.all(J3Space.md),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: text,
        builder: (context, value, _) {
          final dirty = !doc.readOnly && value.text != doc.originalText;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.description_outlined, color: fx.accentText, size: 20),
                  const SizedBox(width: J3Space.sm),
                  Expanded(
                    child: PathText(doc.displayName, style: J3Type.code.copyWith(color: J3Colors.text)),
                  ),
                  NeonIconButton(icon: Icons.close, tooltip: 'Close file', onPressed: onClose),
                ],
              ),
              const SizedBox(height: J3Space.xs),
              ButtonWrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.xs,
                children: [
                  if (dirty)
                    const StatusBadge(kind: StatusKind.warning, text: 'MODIFIED', dense: true)
                  else
                    StatusBadge(kind: StatusKind.success, text: doc.readOnly ? 'READ-ONLY' : 'SAVED', dense: true),
                  StatusBadge(kind: StatusKind.neutral, text: doc.encodingLabel, dense: true),
                  StatusBadge(kind: StatusKind.neutral, text: 'Endings: ${doc.endings.kind.label}', dense: true),
                  StatusBadge(kind: StatusKind.neutral, text: Fmt.bytes(doc.sizeOnDisk), dense: true),
                ],
              ),
              const SizedBox(height: J3Space.sm),
              ButtonWrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  NeonButton(
                    label: 'Save',
                    icon: Icons.save_outlined,
                    busy: saving,
                    tooltip: 'Save (Ctrl+S) - backs up the previous version',
                    onPressed: dirty ? onSave : null,
                  ),
                  NeonButton.secondary(label: 'Save as', icon: Icons.save_as_outlined, onPressed: onSaveAs),
                  NeonButton.ghost(label: 'Revert', icon: Icons.undo, onPressed: dirty ? onRevert : null),
                  NeonIconButton(icon: Icons.search, tooltip: 'Find (Ctrl+F)', onPressed: onFind),
                  NeonIconButton(icon: Icons.format_list_numbered, tooltip: 'Go to line (Ctrl+G)', onPressed: onGoTo),
                  if (!doc.readOnly)
                    PopupMenuButton<LineEnding>(
                      tooltip: 'Line endings used when saving',
                      onSelected: ref.read(editorProvider.notifier).setSaveEnding,
                      itemBuilder: (_) => [
                        for (final e in [LineEnding.lf, LineEnding.crlf, LineEnding.cr])
                          CheckedPopupMenuItem(
                            value: e,
                            checked: state.saveEnding == e,
                            child: Text('Save with ${e.label}'),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: J3Space.sm, vertical: J3Space.md),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.keyboard_return, size: 18),
                            const SizedBox(width: J3Space.xs),
                            Flexible(child: Text('Line endings: ${state.saveEnding.label}', style: J3Type.label)),
                            const Icon(Icons.arrow_drop_down, size: 18),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Virtualised read-only view with line numbers for large files.
class _LargeView extends StatelessWidget {
  const _LargeView({required this.lines, required this.controller, required this.extent, this.currentLine});

  final List<String> lines;
  final ScrollController controller;
  final double extent;
  final int? currentLine;

  static const int _maxChars = 2000;

  @override
  Widget build(BuildContext context) {
    final gutter = lines.length.toString().length;
    final digitWidth = MediaQuery.textScalerOf(context).scale(J3Type.codeSmall.fontSize!) * 0.62;
    return Container(
      decoration: BoxDecoration(
        color: J3Colors.inputFill,
        borderRadius: J3Radius.small,
        border: Border.all(color: J3Colors.border),
      ),
      child: SelectionArea(
        child: Scrollbar(
          controller: controller,
          child: ListView.builder(
            controller: controller,
            itemCount: lines.length,
            itemExtent: extent,
            itemBuilder: (context, i) {
              final line = lines[i];
              final shown = line.length > _maxChars ? '${line.substring(0, _maxChars)} ...' : line;
              return Container(
                color: i == currentLine ? J3Colors.selection : null,
                padding: const EdgeInsets.symmetric(horizontal: J3Space.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: gutter * digitWidth + 14,
                      child: Text(
                        '${i + 1}'.padLeft(gutter),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.clip,
                        style: J3Type.codeSmall.copyWith(color: i == currentLine ? J3Colors.text : J3Colors.textMuted),
                      ),
                    ),
                    Expanded(
                      child: Text(shown, style: J3Type.code, softWrap: false, maxLines: 1, overflow: TextOverflow.clip),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
