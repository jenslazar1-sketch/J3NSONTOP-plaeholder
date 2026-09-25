import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/text/diff.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../domain/json_parser.dart';
import '../../domain/json_tools.dart';
import '../../domain/merge_patch.dart';
import '../../domain/presets.dart';
import '../../domain/source_location.dart';
import '../document_io.dart';
import '../widgets/lab_widgets.dart';
import 'presets_controller.dart';

enum _PresetAction { duplicate, edit, rename, delete, export }

class PresetsPage extends ConsumerStatefulWidget {
  const PresetsPage({super.key});

  @override
  ConsumerState<PresetsPage> createState() => _PresetsPageState();
}

class _PresetsPageState extends ConsumerState<PresetsPage> {
  late final TextEditingController _target = ref.read(draftTextProvider(kPresetsTargetKey));
  final FocusNode _focus = FocusNode();

  PresetsController get _c => ref.read(presetsProvider.notifier);

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _notify(NoticeKind kind, String message) => ref.read(activityProvider.notifier).notify(kind, message);

  String? get _sampleGraphics {
    final ws = ref.watch(activeWorkspaceProvider);
    if (ws == null) return null;
    final path = p.join(ws.rootPath, 'game', 'config', 'graphics.json');
    return File(path).existsSync() ? path : null;
  }

  Future<void> _openTarget() async {
    await openIntoEditor(
      context,
      ref,
      docKey: kPresetsDocKey,
      controller: _target,
      extensions: const ['json'],
      title: 'Open JSON document',
    );
    _c.clearPreview();
  }

  Future<void> _openSample(String path) async {
    await loadPathIntoEditor(
      ref,
      docKey: kPresetsDocKey,
      controller: _target,
      path: path,
      displayName: kSampleGraphicsPath,
      fromWorkspace: true,
    );
    _c.clearPreview();
  }

  Future<void> _preview() async {
    final r = await _c.preview();
    if (r != null && r.semantic.identical) _notify(NoticeKind.info, 'The preset changes nothing in this document.');
  }

  Future<void> _applyAndSave(PresetPreview preview, {bool saveAs = false}) async {
    _target.value = TextEditingValue(text: preview.afterText);
    final source = ref.read(docSourceProvider(kPresetsDocKey));
    final saved = await saveDocument(
      context,
      ref,
      toolId: kPresetsToolId,
      docKey: kPresetsDocKey,
      text: preview.afterText,
      suggestedName: source.path == null ? 'patched.json' : p.basename(source.displayName),
      mimeType: 'application/json',
      saveAs: saveAs,
    );
    if (saved) _c.clearPreview();
  }

  Future<void> _edit({ConfigPreset? existing}) async {
    final result = await showDialog<_PresetDraft>(
      context: context,
      builder: (_) => _PresetEditorDialog(existing: existing),
    );
    if (result == null) return;
    if (existing == null) {
      await _c.create(name: result.name, description: result.description, target: result.target, patch: result.patch);
      _notify(NoticeKind.success, 'Preset "${result.name}" created');
    } else {
      await _c.update(
        ConfigPreset(
          id: existing.id,
          name: result.name,
          description: result.description,
          target: result.target,
          patch: result.patch,
          createdAt: existing.createdAt,
          updatedAt: DateTime.now(),
        ),
      );
      _notify(NoticeKind.success, 'Preset "${result.name}" saved');
    }
  }

  Future<void> _import() async {
    final r = await readInputFile(context, ref, extensions: const ['json'], title: 'Import presets');
    if (r == null) return;
    final load = await _c.import(r.$1);
    if (load.presets.isNotEmpty) {
      _notify(NoticeKind.success, 'Imported ${load.presets.length} preset(s) from ${r.$2.displayName}');
    }
    if (load.problems.isNotEmpty) {
      _notify(
        load.presets.isEmpty ? NoticeKind.error : NoticeKind.warning,
        'Import: ${load.problems.take(3).join('; ')}${load.problems.length > 3 ? ' …' : ''}',
      );
    }
  }

  Future<void> _export(List<ConfigPreset> presets, String name) => saveOutput(
    context,
    ref,
    suggestedName: name,
    bytes: Uint8List.fromList(utf8.encode(exportPresets(presets))),
    mimeType: 'application/json',
    toolId: kPresetsToolId,
  );

  Future<void> _action(_PresetAction a, ConfigPreset preset) async {
    switch (a) {
      case _PresetAction.duplicate:
        final copy = await _c.duplicate(preset.id);
        _notify(NoticeKind.success, 'Created editable copy "${copy.name}"');
      case _PresetAction.edit:
        await _edit(existing: preset);
      case _PresetAction.rename:
        final name = await showJ3TextInput(
          context,
          title: 'Rename preset',
          label: 'Name',
          initial: preset.name,
          confirmLabel: 'Rename',
          validator: (v) => v.trim().isEmpty ? 'Enter a name' : null,
        );
        if (name != null) await _c.rename(preset.id, name.trim());
      case _PresetAction.delete:
        final ok = await showJ3Confirm(
          context,
          title: 'Delete "${preset.name}"?',
          message: 'The preset is removed from this device. Export it first if you want to keep a copy.',
          confirmLabel: 'Delete',
          destructive: true,
        );
        if (ok) await _c.delete(preset.id);
      case _PresetAction.export:
        await _export([preset], '${preset.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-').toLowerCase()}.preset.json');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(presetsProvider);
    final presets = ref.watch(allPresetsProvider);
    final userLoad = ref.watch(userPresetsProvider);
    return ToolScaffold(toolId: kPresetsToolId, inputs: [_library(s, presets, userLoad)], results: [_applyPanel(s)]);
  }

  Widget _library(PresetsState s, List<ConfigPreset> presets, PresetLoad userLoad) {
    return NeonPanel(
      kicker: 'PRESET LIBRARY',
      title: '${presets.length} presets',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LabHint(
            'Presets are JSON Merge Patches (RFC 7386): objects merge key by key, null removes a key, any other '
            'value replaces. Built-in presets are labelled examples for the sample game.',
          ),
          const SizedBox(height: J3Space.sm),
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              NeonButton.secondary(label: 'New preset', icon: Icons.add, dense: true, onPressed: () => _edit()),
              NeonButton.ghost(label: 'Import', icon: Icons.file_open_outlined, dense: true, onPressed: _import),
              NeonButton.ghost(
                label: 'Export mine',
                icon: Icons.save_alt_rounded,
                dense: true,
                onPressed: userLoad.presets.isEmpty ? null : () => _export(userLoad.presets, 'config-presets.json'),
              ),
            ],
          ),
          for (final problem in userLoad.problems) ...[
            const SizedBox(height: J3Space.xs),
            LabHint('Stored presets: $problem', icon: Icons.warning_amber_rounded),
          ],
          const SizedBox(height: J3Space.sm),
          for (final preset in presets) _tile(preset, preset.id == s.selectedId),
        ],
      ),
    );
  }

  Widget _tile(ConfigPreset preset, bool selected) {
    final fx = context.effects;
    final ops = describeMergePatch(preset.patch);
    return Padding(
      padding: const EdgeInsets.only(bottom: J3Space.sm),
      child: Semantics(
        selected: selected,
        button: true,
        label: 'Preset ${preset.name}',
        child: Material(
          color: selected ? J3Colors.selection : J3Colors.surfaceRaised,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: J3Radius.medium,
            side: BorderSide(color: selected ? fx.accentColor : J3Colors.border),
          ),
          child: InkWell(
            onTap: () => _c.select(preset.id),
            child: Padding(
              padding: const EdgeInsets.all(J3Space.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: J3Space.sm),
                    child: Icon(
                      selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      size: 20,
                      color: selected ? fx.accentText : J3Colors.textMuted,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(preset.name, style: J3Type.label),
                        const SizedBox(height: J3Space.xs),
                        Wrap(
                          spacing: J3Space.xs,
                          runSpacing: J3Space.xs,
                          children: [
                            if (preset.builtIn)
                              const StatusBadge(kind: StatusKind.info, text: 'EXAMPLE · BUILT-IN', dense: true),
                            StatusBadge(kind: StatusKind.neutral, text: '${ops.length} change(s)', dense: true),
                          ],
                        ),
                        if (preset.description.isNotEmpty) ...[
                          const SizedBox(height: J3Space.xs),
                          Text(preset.description, style: J3Type.caption),
                        ],
                        if (preset.target != null) Text('Written for: ${preset.target}', style: J3Type.codeSmall),
                      ],
                    ),
                  ),
                  PopupMenuButton<_PresetAction>(
                    tooltip: 'Actions for ${preset.name}',
                    onSelected: (a) => _action(a, preset),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: _PresetAction.duplicate, child: Text('Duplicate as my preset')),
                      if (!preset.builtIn) ...[
                        const PopupMenuItem(value: _PresetAction.edit, child: Text('Edit…')),
                        const PopupMenuItem(value: _PresetAction.rename, child: Text('Rename…')),
                        const PopupMenuItem(value: _PresetAction.delete, child: Text('Delete…')),
                      ],
                      const PopupMenuItem(value: _PresetAction.export, child: Text('Export…')),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _applyPanel(PresetsState s) {
    final preset = _c.byId(s.selectedId);
    final sample = _sampleGraphics;
    final preview = s.preview;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeonPanel(
          kicker: 'APPLY',
          title: preset == null ? 'Select a preset' : 'Apply "${preset.name}"',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (preset != null) ...[
                Text('Patch', style: J3Type.caption),
                const SizedBox(height: J3Space.xs),
                CodeExcerpt(encodeJson(preset.patch)),
                const SizedBox(height: J3Space.md),
              ],
              _TargetBar(onOpen: _openTarget, onOpenSample: sample == null ? null : () => _openSample(sample)),
              const SizedBox(height: J3Space.sm),
              CodeField(
                controller: _target,
                focusNode: _focus,
                label: 'Target JSON document',
                hint: '{"quality": "high"}',
                minLines: 8,
                maxLines: 16,
                wrap: false,
              ),
              const SizedBox(height: J3Space.sm),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _target,
                builder: (context, v, _) => Align(
                  alignment: Alignment.centerLeft,
                  child: NeonButton(
                    label: 'Preview changes',
                    icon: Icons.preview_outlined,
                    onPressed: preset == null || v.text.trim().isEmpty ? null : _preview,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (s.error != null) ...[
          const SizedBox(height: J3Space.md),
          ParseErrorPanel(
            error: s.error!,
            kicker: 'TARGET IS NOT VALID JSON',
            onJump: (l) {
              _focus.requestFocus();
              _target.jumpTo(l.line, l.column);
            },
          ),
        ],
        if (preview != null) ...[const SizedBox(height: J3Space.md), _previewPanel(preview)],
      ],
    );
  }

  Widget _previewPanel(PresetPreview r) {
    final sem = r.semantic;
    final source = ref.watch(docSourceProvider(kPresetsDocKey));
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _target,
      builder: (context, v, _) {
        final stale = v.text != r.sourceText;
        return NeonPanel(
          kicker: 'PREVIEW',
          title: '"${r.presetName}": ${sem.changes.length} change(s)',
          emphasis: PanelEmphasis.strong,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (stale) const LabHint('The document changed after this preview. Preview again.', icon: Icons.history),
              Wrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                children: [
                  StatusBadge(kind: StatusKind.success, text: '+${sem.added} ADDED'),
                  StatusBadge(kind: StatusKind.error, text: '-${sem.removed} REMOVED'),
                  StatusBadge(kind: StatusKind.warning, text: '~${sem.changed + sem.typeChanged} CHANGED'),
                  StatusBadge(kind: StatusKind.neutral, text: 'TEXT +${r.text.insertions} -${r.text.deletions}'),
                ],
              ),
              const SizedBox(height: J3Space.sm),
              const LabHint('The document is re-serialised with its detected indentation; key order is kept.'),
              const SizedBox(height: J3Space.sm),
              for (final c in sem.changes.take(60))
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '${c.kind.symbol} ${c.describe()}',
                    style: J3Type.codeSmall.copyWith(color: J3Colors.text),
                  ),
                ),
              if (sem.changes.length > 60) Text('… ${sem.changes.length - 60} more', style: J3Type.caption),
              const SizedBox(height: J3Space.sm),
              Container(
                constraints: const BoxConstraints(maxHeight: 280),
                decoration: BoxDecoration(
                  color: J3Colors.inputFill,
                  borderRadius: J3Radius.small,
                  border: Border.all(color: J3Colors.border),
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(J3Space.sm),
                  children: [
                    for (final l in r.text.lines)
                      if (l.op != DiffOp.equal)
                        Text(
                          '${l.op == DiffOp.insert ? '+' : '-'} ${l.text}',
                          style: J3Type.codeSmall.copyWith(
                            color: l.op == DiffOp.insert ? J3Colors.success : J3Colors.error,
                          ),
                        ),
                  ],
                ),
              ),
              const SizedBox(height: J3Space.md),
              Wrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                children: [
                  NeonButton(
                    label: source.fromWorkspace ? 'Apply & save with backup' : 'Apply & save as…',
                    icon: Icons.save_outlined,
                    onPressed: stale || sem.identical ? null : () => _applyAndSave(r),
                  ),
                  NeonButton.secondary(
                    label: 'Apply to editor only',
                    icon: Icons.edit_note,
                    onPressed: stale || sem.identical
                        ? null
                        : () {
                            _target.value = TextEditingValue(text: r.afterText);
                            _c.clearPreview();
                          },
                  ),
                  if (source.fromWorkspace)
                    NeonButton.ghost(
                      label: 'Save as…',
                      icon: Icons.save_as_outlined,
                      onPressed: stale || sem.identical ? null : () => _applyAndSave(r, saveAs: true),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Target document name + open actions.
class _TargetBar extends ConsumerWidget {
  const _TargetBar({required this.onOpen, this.onOpenSample});
  final VoidCallback onOpen;
  final VoidCallback? onOpenSample;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(docSourceProvider(kPresetsDocKey));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: J3Space.sm,
          runSpacing: J3Space.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(source.displayName, style: J3Type.code),
            if (source.fromWorkspace) const StatusBadge(kind: StatusKind.neutral, text: 'WORKSPACE', dense: true),
            NeonButton.secondary(label: 'Open document', icon: Icons.folder_open, dense: true, onPressed: onOpen),
            if (onOpenSample != null)
              NeonButton.ghost(
                label: 'Open sample graphics.json',
                icon: Icons.videogame_asset_outlined,
                dense: true,
                onPressed: onOpenSample,
              ),
          ],
        ),
        if (source.lastSave != null) ...[
          const SizedBox(height: J3Space.xs),
          SaveReceiptLine(receipt: source.lastSave!),
        ],
      ],
    );
  }
}

class _PresetDraft {
  const _PresetDraft(this.name, this.description, this.target, this.patch);
  final String name;
  final String description;
  final String? target;
  final Object? patch;
}

class _PresetEditorDialog extends StatefulWidget {
  const _PresetEditorDialog({this.existing});
  final ConfigPreset? existing;

  @override
  State<_PresetEditorDialog> createState() => _PresetEditorDialogState();
}

class _PresetEditorDialogState extends State<_PresetEditorDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _description = TextEditingController(text: widget.existing?.description ?? '');
  late final TextEditingController _target = TextEditingController(text: widget.existing?.target ?? '');
  late final TextEditingController _patch = TextEditingController(
    text: widget.existing == null ? '{\n  \n}' : encodeJson(widget.existing!.patch),
  );
  String? _nameError;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _target.dispose();
    _patch.dispose();
    super.dispose();
  }

  LocatedError? _patchError(String text) {
    try {
      decodeJsonStrict(text);
      return null;
    } on JsonSyntaxError catch (e) {
      return LocatedError.at(text, e.message, SourceLocation.fromOffset(text, e.offset));
    }
  }

  void _submit() {
    if (_name.text.trim().isEmpty) {
      setState(() => _nameError = 'Enter a name');
      return;
    }
    if (_patchError(_patch.text) != null) return;
    Navigator.of(context).pop(
      _PresetDraft(
        _name.text.trim(),
        _description.text.trim(),
        _target.text.trim().isEmpty ? null : _target.text.trim(),
        decodeJsonStrict(_patch.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New preset' : 'Edit preset'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                decoration: InputDecoration(labelText: 'Name', errorText: _nameError),
              ),
              const SizedBox(height: J3Space.sm),
              TextField(
                controller: _description,
                decoration: const InputDecoration(labelText: 'Description (optional)'),
              ),
              const SizedBox(height: J3Space.sm),
              TextField(
                controller: _target,
                style: J3Type.code,
                decoration: const InputDecoration(labelText: 'Written for file (optional hint)'),
              ),
              const SizedBox(height: J3Space.sm),
              CodeField(controller: _patch, label: 'Merge patch (JSON)', minLines: 6, maxLines: 12),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _patch,
                builder: (context, v, _) {
                  final err = _patchError(v.text);
                  if (err == null) {
                    final ops = describeMergePatch(decodeJsonStrict(v.text));
                    return Padding(
                      padding: const EdgeInsets.only(top: J3Space.xs),
                      child: Text(
                        'Valid patch: ${ops.length} change(s)${ops.isEmpty ? '' : ' - ${ops.take(3).join('; ')}${ops.length > 3 ? '…' : ''}'}',
                        style: J3Type.caption.copyWith(color: J3Colors.success),
                      ),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: J3Space.xs),
                    child: Text('ERROR: ${err.describe()}', style: J3Type.caption.copyWith(color: J3Colors.error)),
                  );
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        NeonButton.secondary(label: 'Cancel', dense: true, onPressed: () => Navigator.of(context).pop()),
        NeonButton(label: 'Save preset', dense: true, onPressed: _submit),
      ],
    );
  }
}
