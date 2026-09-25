import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../domain/json_parser.dart';
import '../document_io.dart';
import '../widgets/lab_widgets.dart';
import '../widgets/workbench.dart';
import 'save_editor_controller.dart';
import 'schema_form.dart';

const String kSupportStatement =
    'Supported: JSON save files described by a JSON schema (subset). Binary or undocumented formats are not '
    'supported and are never guessed.';

class SaveEditorPage extends ConsumerStatefulWidget {
  const SaveEditorPage({super.key});

  @override
  ConsumerState<SaveEditorPage> createState() => _SaveEditorPageState();
}

class _SaveEditorPageState extends ConsumerState<SaveEditorPage> {
  late final TextEditingController _raw = ref.read(draftTextProvider(kSaveRawKey));
  final FocusNode _focus = FocusNode();

  SaveEditorController get _c => ref.read(saveEditorProvider.notifier);
  static const _paneKey = '$kSaveToolId/pane';

  @override
  void initState() {
    super.initState();
    _raw.addListener(_onRaw);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onRaw();
    });
  }

  @override
  void dispose() {
    _raw.removeListener(_onRaw);
    _focus.dispose();
    super.dispose();
  }

  void _onRaw() => _c.rawChanged();

  void _notify(NoticeKind kind, String message) => ref.read(activityProvider.notifier).notify(kind, message);

  /// Paths of the sample game's save + schema in the active workspace.
  (String, String)? get _sample {
    final ws = ref.watch(activeWorkspaceProvider);
    if (ws == null) return null;
    final save = p.join(ws.rootPath, 'game', 'saves', 'slot1.json');
    final schema = p.join(ws.rootPath, 'game', 'saves', 'save.schema.json');
    return File(save).existsSync() && File(schema).existsSync() ? (save, schema) : null;
  }

  Future<void> _detectSchema(String savePath) async {
    try {
      final found = await _c.autoDetectSchema(savePath);
      if (!mounted) return;
      if (found != null) {
        _notify(NoticeKind.success, 'Schema found next to the save: ${p.basename(found)}');
      } else if (ref.read(saveEditorProvider).schema != null) {
        _notify(NoticeKind.info, 'No schema next to this save; keeping ${ref.read(saveEditorProvider).schemaName}.');
      } else {
        _notify(NoticeKind.info, 'No schema found next to the save. Choose one with "Open schema".');
      }
    } catch (e) {
      _notify(NoticeKind.error, 'Schema could not be loaded: $e');
    }
  }

  Future<void> _openSave() async {
    final text = await openIntoEditor(
      context,
      ref,
      docKey: kSaveDocKey,
      controller: _raw,
      extensions: const ['json', 'sav', 'save'],
      title: 'Open save file',
    );
    if (text == null) return;
    final path = ref.read(docSourceProvider(kSaveDocKey)).path;
    if (path != null) await _detectSchema(path);
  }

  Future<void> _openSample((String, String) sample) async {
    final ws = ref.read(activeWorkspaceProvider)!;
    final ok = await loadPathIntoEditor(
      ref,
      docKey: kSaveDocKey,
      controller: _raw,
      path: sample.$1,
      displayName: p.relative(sample.$1, from: ws.rootPath).replaceAll('\\', '/'),
      fromWorkspace: true,
    );
    if (ok) await _detectSchema(sample.$1);
  }

  Future<void> _openSchema() async {
    final r = await readInputFile(context, ref, extensions: const ['json'], title: 'Open JSON schema');
    if (r == null) return;
    try {
      _c.setSchema(decodeJsonStrict(r.$1), r.$2.displayName);
      final s = ref.read(saveEditorProvider).schema!;
      _notify(
        s.ok ? NoticeKind.success : NoticeKind.error,
        s.ok ? 'Schema ${r.$2.displayName} loaded' : 'Schema has ${s.errors.length} error(s)',
      );
    } on JsonSyntaxError catch (e) {
      _notify(NoticeKind.error, '${r.$2.displayName} is not valid JSON: ${e.message}');
    }
  }

  Future<void> _save({bool saveAs = false}) async {
    final s = ref.read(saveEditorProvider);
    if (s.dataError != null || s.violations.isNotEmpty) {
      final ok = await showJ3Confirm(
        context,
        title: s.dataError != null ? 'Save invalid JSON?' : 'Save with ${s.violations.length} schema issue(s)?',
        message: s.dataError != null
            ? 'The raw JSON does not parse. The game may not be able to load it.'
            : 'The save does not match its schema. The game may reject it or behave unexpectedly.',
        confirmLabel: 'Save anyway',
        destructive: true,
        details: [for (final v in s.violations.take(10)) v.describe()],
      );
      if (!ok || !mounted) return;
    }
    final source = ref.read(docSourceProvider(kSaveDocKey));
    await saveDocument(
      context,
      ref,
      toolId: kSaveToolId,
      docKey: kSaveDocKey,
      text: _raw.text,
      suggestedName: source.path == null ? 'save.json' : p.basename(source.displayName),
      mimeType: 'application/json',
      saveAs: saveAs,
    );
  }

  Future<void> _clear() async {
    if (!await confirmClear(context, what: 'the save')) return;
    _raw.clear();
    ref.read(docSourceProvider(kSaveDocKey).notifier).set(const DocSource());
  }

  void _jumpToPointer(String pointer) {
    final loc = _c.locate(pointer);
    ref.setDraft(_paneKey, 'raw');
    if (loc == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _raw.jumpTo(loc.line, loc.column);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(saveEditorProvider);
    final pane = ref.draft<String>(_paneKey, 'form');
    final sample = _sample;
    final panes = [
      PaneSpec(id: 'form', label: 'Form', icon: Icons.dynamic_form_outlined, builder: (_) => _formPane(s)),
      PaneSpec(id: 'raw', label: 'Raw JSON', icon: Icons.data_object, builder: (_) => _rawPane(s)),
      PaneSpec(
        id: 'issues',
        label: 'Issues',
        icon: Icons.rule,
        badge: s.violations.length,
        builder: (_) => _issuesPane(s),
      ),
    ];
    final current = panes.firstWhere((x) => x.id == pane, orElse: () => panes.first);
    return ToolScaffold(
      toolId: kSaveToolId,
      banner: const _SupportPanel(),
      children: [
        DocumentBar(
          docKey: kSaveDocKey,
          controller: _raw,
          onOpen: _openSave,
          onSave: _save,
          onSaveAs: () => _save(saveAs: true),
          onClear: _clear,
          extra: [
            if (sample != null)
              NeonButton.ghost(
                label: 'Open sample save',
                icon: Icons.videogame_asset_outlined,
                dense: true,
                tooltip: 'game/saves/slot1.json with game/saves/save.schema.json',
                onPressed: () => _openSample(sample),
              ),
          ],
        ),
        _schemaBar(s),
        _status(s),
        PaneTabs(panes: panes, selected: current.id, onSelected: (id) => ref.setDraft(_paneKey, id)),
        current.builder(context),
      ],
    );
  }

  Widget _schemaBar(SaveEditorState s) {
    final fx = context.effects;
    return Container(
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
              Icon(Icons.schema_outlined, size: 18, color: fx.accentText),
              const SizedBox(width: J3Space.xs),
              Flexible(
                child: Text(
                  s.schemaName == null ? 'No schema' : 'Schema: ${s.schemaName}',
                  style: J3Type.code.copyWith(color: J3Colors.text),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          NeonButton.secondary(
            label: 'Open schema',
            icon: Icons.file_open_outlined,
            dense: true,
            onPressed: _openSchema,
          ),
          if (s.schema != null)
            NeonButton.ghost(label: 'Remove schema', icon: Icons.link_off, dense: true, onPressed: _c.clearSchema),
        ],
      ),
    );
  }

  Widget _status(SaveEditorState s) {
    final Widget badge;
    final String message;
    if (!s.hasData && s.dataError == null) {
      badge = const ValidityBadge(validity: Validity.empty);
      message = 'Open a JSON save file (or the sample save).';
    } else if (s.dataError != null) {
      badge = const ValidityBadge(validity: Validity.invalid, label: 'INVALID JSON');
      message = s.dataError!.describe();
    } else if (s.schema == null) {
      badge = const StatusBadge(kind: StatusKind.neutral, text: 'NO SCHEMA');
      message = 'Valid JSON. Choose a schema to get the form and validation.';
    } else if (!s.schemaOk) {
      badge = const StatusBadge(kind: StatusKind.error, text: 'SCHEMA ERROR');
      message = 'The schema itself has ${s.schema!.errors.length} error(s).';
    } else if (s.validating) {
      badge = const ValidityBadge(validity: Validity.checking);
      message = 'Validating against the schema…';
    } else if (s.violations.isEmpty && s.validationError == null) {
      badge = const ValidityBadge(validity: Validity.valid, label: 'VALID SAVE');
      message = 'Matches the schema.';
    } else {
      badge = StatusBadge(
        kind: StatusKind.error,
        text: '${s.violations.length} ISSUE${s.violations.length == 1 ? '' : 'S'}',
      );
      message = s.validationError ?? 'Does not match the schema. See the Issues tab.';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatusLine(badge: badge, message: message),
        if (s.schema != null && s.schema!.errors.isNotEmpty) ...[
          const SizedBox(height: J3Space.sm),
          IssueList(
            kicker: 'SCHEMA',
            title: 'Schema errors',
            items: [for (final e in s.schema!.errors) IssueItem(kind: StatusKind.error, message: e)],
          ),
        ],
        if (s.schema != null && s.schema!.warnings.isNotEmpty) ...[
          const SizedBox(height: J3Space.sm),
          for (final w in s.schema!.warnings) LabHint('Schema: $w', icon: Icons.warning_amber_rounded),
        ],
      ],
    );
  }

  Widget _formPane(SaveEditorState s) {
    if (!s.hasData) {
      return EmptyState(
        title: 'No save loaded',
        message:
            'Open a JSON save. A sibling "<name>.schema.json" or "save.schema.json" is picked up automatically '
            'for workspace files.',
        glyph: '[ SAVE ]',
        action: NeonButton(label: 'Open save', icon: Icons.folder_open, onPressed: _openSave),
      );
    }
    if (s.schema == null || !s.schemaOk) {
      return EmptyState(
        title: s.schema == null ? 'Choose a schema' : 'Fix the schema',
        message: 'The form is generated from the schema. Without a usable schema you can still edit the Raw JSON tab.',
        glyph: '{ ? }',
        action: NeonButton.secondary(label: 'Open schema', icon: Icons.file_open_outlined, onPressed: _openSchema),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (s.dataError != null) ...[
          LabHint(
            'The raw JSON has an error, so the form shows the last valid data and is read-only. '
            '${s.dataError!.describe()}',
            icon: Icons.lock_outline,
          ),
          const SizedBox(height: J3Space.sm),
        ],
        SchemaForm(schema: s.schema!.root!),
      ],
    );
  }

  Widget _rawPane(SaveEditorState s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (s.dataError != null) ...[
          ParseErrorPanel(
            error: s.dataError!,
            onJump: (l) {
              _focus.requestFocus();
              _raw.jumpTo(l.line, l.column);
            },
          ),
          const SizedBox(height: J3Space.md),
        ],
        NeonPanel(
          kicker: 'RAW JSON',
          padding: const EdgeInsets.all(J3Space.md),
          child: CodeField(
            controller: _raw,
            focusNode: _focus,
            label: 'Save file JSON',
            minLines: 12,
            maxLines: 28,
            wrap: false,
          ),
        ),
      ],
    );
  }

  Widget _issuesPane(SaveEditorState s) {
    if (s.schema == null) {
      return const EmptyState(title: 'No schema', message: 'Issues are schema violations; choose a schema first.');
    }
    if (s.violations.isEmpty) {
      return EmptyState(
        title: s.validationError ?? 'No issues',
        message: s.validationError == null ? 'The save matches the schema.' : null,
        glyph: s.validationError == null ? '[ OK ]' : '[ !! ]',
      );
    }
    return NeonPanel(
      kicker: 'SCHEMA VIOLATIONS',
      title: '${s.violations.length} issue(s)',
      emphasis: PanelEmphasis.danger,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final v in s.violations.take(300))
            Padding(
              padding: const EdgeInsets.only(bottom: J3Space.xs),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, size: 16, color: J3Colors.error),
                  const SizedBox(width: J3Space.sm),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${v.pointer.isEmpty ? '(root)' : v.pointer}  ',
                            style: J3Type.code.copyWith(color: J3Colors.text),
                          ),
                          TextSpan(text: '[${v.keyword}] ${v.message}', style: J3Type.caption),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Show ${v.pointer.isEmpty ? 'root' : v.pointer} in the raw JSON',
                    onPressed: () => _jumpToPointer(v.pointer),
                    icon: const Icon(Icons.my_location, size: 18),
                  ),
                ],
              ),
            ),
          if (s.violations.length > 300) Text('… ${s.violations.length - 300} more', style: J3Type.caption),
        ],
      ),
    );
  }
}

/// The prominent statement of what this editor supports.
class _SupportPanel extends StatelessWidget {
  const _SupportPanel();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: kSupportStatement,
      child: Container(
        padding: const EdgeInsets.all(J3Space.md),
        decoration: BoxDecoration(
          color: J3Colors.info.withValues(alpha: 0.08),
          borderRadius: J3Radius.medium,
          border: Border.all(color: J3Colors.info.withValues(alpha: 0.6)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.verified_user_outlined, color: J3Colors.info, size: 20),
            const SizedBox(width: J3Space.md),
            Expanded(
              child: ExcludeSemantics(
                child: Text(kSupportStatement, style: J3Type.body.copyWith(color: J3Colors.text)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
