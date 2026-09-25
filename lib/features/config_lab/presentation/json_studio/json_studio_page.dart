import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/field_search.dart';
import '../../domain/json_tools.dart';
import '../../domain/json_tree_ops.dart';
import '../../domain/json_value.dart';
import '../document_io.dart';
import '../widgets/lab_widgets.dart';
import '../widgets/value_editor_dialog.dart';
import '../widgets/value_tree.dart';
import '../widgets/workbench.dart';
import 'json_studio_controller.dart';

class JsonStudioPage extends ConsumerStatefulWidget {
  const JsonStudioPage({super.key});

  @override
  ConsumerState<JsonStudioPage> createState() => _JsonStudioPageState();
}

class _JsonStudioPageState extends ConsumerState<JsonStudioPage> {
  final FocusNode _focus = FocusNode();
  late final TextEditingController _input = ref.read(draftTextProvider(kJsonInputKey));
  late final TextEditingController _query = ref.read(draftTextProvider(kJsonSearchKey));
  bool _wide = false;

  JsonStudioController get _c => ref.read(jsonStudioProvider.notifier);

  @override
  void initState() {
    super.initState();
    _input.addListener(_onInput);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onInput();
    });
  }

  @override
  void dispose() {
    _input.removeListener(_onInput);
    _focus.dispose();
    super.dispose();
  }

  void _onInput() => _c.textChanged(_input.text);

  void _notify(NoticeKind kind, String message) => ref.read(activityProvider.notifier).notify(kind, message);

  void _jump(int line, int column) {
    if (!_wide) ref.setDraft(ConfigWorkbench.paneKey(kJsonToolId), kEditorPaneId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _input.jumpTo(line, column);
    });
  }

  Future<void> _open() async {
    final text = await openIntoEditor(
      context,
      ref,
      docKey: kJsonDocKey,
      controller: _input,
      extensions: const ['json', 'jsonc', 'geojson', 'txt'],
      title: 'Open JSON file',
    );
    if (text != null && text.length > kSyncParseLimit) await _c.validate();
  }

  Future<void> _save({bool saveAs = false}) async {
    final s = ref.read(jsonStudioProvider);
    if (!s.usable) {
      final ok = await showJ3Confirm(
        context,
        title: 'Save invalid JSON?',
        message: 'The text is not valid JSON (or has not been validated). Save it anyway?',
        confirmLabel: 'Save anyway',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    final source = ref.read(docSourceProvider(kJsonDocKey));
    await saveDocument(
      context,
      ref,
      toolId: kJsonToolId,
      docKey: kJsonDocKey,
      text: _input.text,
      suggestedName: source.path == null ? 'document.json' : source.displayName.split('/').last,
      mimeType: 'application/json',
      saveAs: saveAs,
    );
  }

  Future<void> _clear() async {
    if (!await confirmClear(context)) return;
    _input.clear();
    ref.read(docSourceProvider(kJsonDocKey).notifier).set(const DocSource());
  }

  Future<void> _validate() async {
    try {
      final a = await _c.validate();
      if (!mounted) return;
      if (a.empty) {
        _notify(NoticeKind.info, 'Nothing to validate: the editor is empty.');
      } else if (a.valid) {
        _notify(NoticeKind.success, 'Valid JSON${a.warnings.isEmpty ? '' : ' with ${a.warnings.length} warning(s)'}');
      } else {
        _notify(NoticeKind.error, 'Invalid JSON: ${a.error!.describe()}');
      }
    } catch (e) {
      _notify(NoticeKind.error, 'Validation failed: $e');
    }
  }

  Future<void> _edit(Object? Function() op, String label) async {
    try {
      await _c.applyTreeEdit(op(), label);
    } on JsonEditError catch (e) {
      _notify(NoticeKind.error, e.message);
    }
  }

  Future<void> _onTreeAction(TreeAction action, TreeRow row) async {
    final root = ref.read(jsonStudioProvider).analysis?.value;
    final where = formatJsonPath(row.path);
    switch (action) {
      case TreeAction.copyPath:
        await copyWithNotice(ref, where, 'JSONPath $where');
      case TreeAction.copyValue:
        await copyWithNotice(ref, encodeJson(row.value), 'value of $where');
      case TreeAction.editValue:
        final r = await showValueEditor(context, title: 'Edit $where', initial: row.value);
        if (r == null) return;
        await _edit(() => setValueAt(root, row.path, r.$2.value), 'Edit value');
      case TreeAction.renameKey:
        final oldKey = row.path.last as String;
        final parentPath = row.path.sublist(0, row.path.length - 1);
        final parent = lookupPath(root, parentPath).value;
        if (!mounted) return;
        final newKey = await showJ3TextInput(
          context,
          title: 'Rename "$oldKey"',
          label: 'New property name',
          initial: oldKey,
          monospace: true,
          confirmLabel: 'Rename',
          validator: (v) => v != oldKey && parent is Map<String, Object?> && parent.containsKey(v)
              ? 'A property "$v" already exists'
              : null,
        );
        if (newKey == null) return;
        await _edit(() => renameKeyAt(root, parentPath, oldKey, newKey), 'Rename key');
      case TreeAction.addProperty:
        final map = row.value;
        final r = await showValueEditor(
          context,
          title: 'Add property to $where',
          keyLabel: 'Property name',
          keyValidator: (k) =>
              map is Map<String, Object?> && map.containsKey(k) ? 'A property "$k" already exists' : null,
        );
        if (r == null) return;
        await _edit(() => addPropertyAt(root, row.path, r.$1!, r.$2.value), 'Add property');
        if (!ref.read(jsonStudioProvider).expanded.contains(row.pointer)) _c.toggle(row.pointer);
      case TreeAction.addItem:
        final r = await showValueEditor(context, title: 'Add item to $where');
        if (r == null) return;
        await _edit(() => insertItemAt(root, row.path, r.$2.value), 'Add item');
        if (!ref.read(jsonStudioProvider).expanded.contains(row.pointer)) _c.toggle(row.pointer);
      case TreeAction.delete:
        if (isContainer(row.value) && jsonPreview(row.value) != '{}' && jsonPreview(row.value) != '[]') {
          final ok = await showJ3Confirm(
            context,
            title: 'Delete $where?',
            message: 'This removes ${jsonPreview(row.value)}. You can undo it with Undo.',
            confirmLabel: 'Delete',
            destructive: true,
          );
          if (!ok) return;
        }
        await _edit(() => removeAt(root, row.path), 'Delete');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(jsonStudioProvider);
    final a = s.analysis;
    final empty = _input.text.trim().isEmpty;
    final validity = empty
        ? Validity.empty
        : s.analyzing
        ? Validity.checking
        : s.stale
        ? Validity.stale
        : (a?.valid ?? false)
        ? Validity.valid
        : Validity.invalid;
    final stats = a?.stats;
    final message = switch (validity) {
      Validity.empty => 'Paste JSON or open a file.',
      Validity.checking => 'Validating in the background…',
      Validity.stale => 'Large document edited: press Validate to re-check (runs off the UI thread).',
      Validity.valid =>
        '${stats!.objects} objects, ${stats.arrays} arrays, ${stats.keys} keys, depth ${stats.depth}, ${Fmt.bytes(stats.bytes)}',
      Validity.invalid => a?.error?.describe(),
    };
    final showError = validity == Validity.invalid && a?.error != null;

    return ToolScaffold(
      toolId: kJsonToolId,
      children: [
        ConfigWorkbench(
          toolId: kJsonToolId,
          onLayout: (w) => _wide = w,
          header: [
            DocumentBar(
              docKey: kJsonDocKey,
              controller: _input,
              onOpen: _open,
              onSave: _save,
              onSaveAs: () => _save(saveAs: true),
              onClear: _clear,
            ),
            _toolbar(s),
            StatusLine(
              badge: ValidityBadge(validity: validity),
              message: message,
            ),
            if (showError) ParseErrorPanel(error: a!.error!, onJump: (loc) => _jump(loc.line, loc.column)),
            if (validity == Validity.valid && a!.warnings.isNotEmpty)
              IssueList(
                kicker: 'CHECKS',
                title: 'Warnings',
                items: [
                  for (final w in a.warnings)
                    IssueItem(
                      kind: StatusKind.warning,
                      message: w.message,
                      line: w.location.line,
                      column: w.location.column,
                    ),
                ],
                onJump: _jump,
              ),
          ],
          editor: EditorPanel(
            controller: _input,
            focusNode: _focus,
            kicker: 'JSON TEXT',
            label: 'JSON',
            hint: '{"player": {"name": "Kaya", "hp": 10}}',
          ),
          panes: [
            PaneSpec(id: 'tree', label: 'Tree', icon: Icons.account_tree_outlined, builder: (_) => _treePane(s)),
            PaneSpec(
              id: 'search',
              label: 'Search',
              icon: Icons.manage_search,
              badge: s.search?.hits.length,
              builder: (_) => _searchPane(s),
            ),
            PaneSpec(id: 'stats', label: 'Stats', icon: Icons.query_stats, builder: (_) => _statsPane(s)),
          ],
        ),
      ],
    );
  }

  Widget _toolbar(JsonStudioState s) {
    final disabledTip = s.usable ? null : 'Needs valid, validated JSON';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: J3Space.sm,
          runSpacing: J3Space.sm,
          children: [
            NeonButton(label: 'Validate', icon: Icons.fact_check_outlined, busy: s.analyzing, onPressed: _validate),
            NeonButton.secondary(
              label: 'Format',
              icon: Icons.format_align_left,
              tooltip: disabledTip ?? 'Re-indent with ${s.indent.label}',
              onPressed: s.usable ? _c.format : null,
            ),
            NeonButton.secondary(
              label: 'Minify',
              icon: Icons.compress,
              tooltip: disabledTip ?? 'Remove all whitespace',
              onPressed: s.usable ? _c.minify : null,
            ),
            NeonButton.secondary(
              label: 'Sort keys',
              icon: Icons.sort_by_alpha,
              tooltip: disabledTip ?? 'Sort object keys at every level (arrays keep their order)',
              onPressed: s.usable ? _c.sortKeys : null,
            ),
            NeonButton.ghost(
              label: s.undoLabel == null ? 'Undo' : 'Undo ${s.undoLabel!.toLowerCase()}',
              icon: Icons.undo,
              tooltip: 'Restore the text from before the last format/minify/sort/tree edit',
              onPressed: s.undoText == null ? null : _c.undo,
            ),
          ],
        ),
        const SizedBox(height: J3Space.sm),
        ChoiceRow<JsonIndent>(
          label: 'Indent (format, sort and tree edits)',
          options: JsonIndent.values,
          selected: s.indent,
          labelOf: (i) => i.label,
          onSelected: _c.setIndent,
        ),
        LabSwitch(
          label: 'Ensure ASCII',
          description: 'Escape non-ASCII characters as \\uXXXX when formatting, minifying or editing',
          value: s.ensureAscii,
          onChanged: _c.setEnsureAscii,
        ),
      ],
    );
  }

  Widget _notUsable(JsonStudioState s, String what) {
    if (_input.text.trim().isEmpty) {
      return EmptyState(title: 'No document', message: 'Paste JSON or open a file to see its $what.', glyph: '{ }');
    }
    if (s.analyzing) return const LoadingState(label: 'Validating the large document in the background…');
    if (s.stale) {
      return EmptyState(
        title: 'Validate to refresh',
        message: 'The large document changed since it was last checked.',
        glyph: '[ ..._... ]',
        action: NeonButton(label: 'Validate', icon: Icons.fact_check_outlined, busy: s.analyzing, onPressed: _validate),
      );
    }
    return EmptyState(
      title: 'Fix the JSON error first',
      message: 'The $what is available once the document parses. Use "Jump to error" above.',
      glyph: '[ x_x ]',
    );
  }

  Widget _treePane(JsonStudioState s) {
    if (!s.usable) return _notUsable(s, 'tree');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: J3Space.sm,
          runSpacing: J3Space.sm,
          children: [
            NeonButton.ghost(
              label: 'Expand all',
              icon: Icons.unfold_more,
              dense: true,
              onPressed: () {
                if (!_c.expandAll()) {
                  _notify(NoticeKind.info, 'Too many nodes to expand at once; expand branches individually.');
                }
              },
            ),
            NeonButton.ghost(label: 'Collapse all', icon: Icons.unfold_less, dense: true, onPressed: _c.collapseAll),
          ],
        ),
        const SizedBox(height: J3Space.xs),
        LabHint(
          'Tree edits re-serialise the whole document with the chosen indent (${s.indent.label}). Undo restores the previous text.',
        ),
        const SizedBox(height: J3Space.sm),
        ValueTreeView(
          root: s.analysis!.value,
          expanded: s.expanded,
          onToggle: _c.toggle,
          onAction: _onTreeAction,
          editable: true,
          selectedPointer: s.selectedPointer,
          revealToken: s.revealToken,
          rootLabel: r'$',
        ),
      ],
    );
  }

  Widget _searchPane(JsonStudioState s) {
    final hits = s.search?.hits ?? const <FieldSearchHit>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _query,
          style: J3Type.code,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(labelText: 'Find in keys and values', prefixIcon: Icon(Icons.search)),
          onSubmitted: (v) => _c.search(v),
        ),
        const SizedBox(height: J3Space.sm),
        ChoiceRow<SearchScope>(
          label: 'Search in',
          options: SearchScope.values,
          selected: s.scope,
          labelOf: (v) => v.label,
          onSelected: (v) => _c.setSearchOptions(scope: v),
        ),
        LabSwitch(
          label: 'Regular expression',
          description: 'Runs in a background worker with a 3 second limit',
          value: s.regex,
          onChanged: (v) => _c.setSearchOptions(regex: v),
        ),
        LabSwitch(
          label: 'Case sensitive',
          value: s.caseSensitive,
          onChanged: (v) => _c.setSearchOptions(caseSensitive: v),
        ),
        const SizedBox(height: J3Space.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: NeonButton(
            label: 'Search',
            icon: Icons.manage_search,
            busy: s.searching,
            tooltip: s.usable ? null : 'Needs valid, validated JSON',
            onPressed: s.usable ? () => _c.search(_query.text) : null,
          ),
        ),
        if (s.searchError != null) ...[
          const SizedBox(height: J3Space.sm),
          Row(
            children: [
              const Icon(Icons.error_outline, size: 16, color: J3Colors.error),
              const SizedBox(width: J3Space.sm),
              Expanded(child: Text('ERROR: ${s.searchError}', style: J3Type.bodySecondary)),
            ],
          ),
        ],
        if (s.search != null) ...[
          const SizedBox(height: J3Space.md),
          Text(
            hits.isEmpty
                ? 'No matches (${s.search!.visited} nodes searched).'
                : '${hits.length} match${hits.length == 1 ? '' : 'es'}${s.search!.truncated ? ' (showing the first ${hits.length})' : ''}',
            style: J3Type.label,
          ),
          const SizedBox(height: J3Space.sm),
          if (hits.isNotEmpty)
            Container(
              height: 360,
              decoration: BoxDecoration(
                color: J3Colors.inputFill,
                borderRadius: J3Radius.small,
                border: Border.all(color: J3Colors.border),
              ),
              child: InkLayer(
                child: ListView.separated(
                  itemCount: hits.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) => _hitTile(hits[i]),
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _hitTile(FieldSearchHit h) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: J3Space.sm, vertical: J3Space.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  h.jsonPath,
                  style: J3Type.code.copyWith(color: J3Colors.text),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${h.keyMatch ? 'KEY ' : ''}${h.valueMatch ? 'VALUE ' : ''}= ${h.preview}',
                  style: J3Type.codeSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy JSONPath',
            onPressed: () => copyWithNotice(ref, h.jsonPath, 'JSONPath ${h.jsonPath}'),
            icon: const Icon(Icons.copy_rounded, size: 18),
          ),
          IconButton(
            tooltip: 'Show in tree',
            onPressed: () {
              _c.reveal(h.path);
              ref.setDraft(ConfigWorkbench.paneKey(kJsonToolId), 'tree');
            },
            icon: const Icon(Icons.account_tree_outlined, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _statsPane(JsonStudioState s) {
    if (!s.usable) return _notUsable(s, 'statistics');
    final st = s.analysis!.stats!;
    return NeonPanel(
      kicker: 'STATISTICS',
      title: 'Document shape',
      child: KeyValueTable(
        rows: [
          ('Size', '${Fmt.bytes(st.bytes)} (${st.bytes} bytes UTF-8)'),
          ('Lines', '${st.lines}'),
          ('Max depth', '${st.depth}'),
          ('Objects', '${st.objects}'),
          ('Arrays', '${st.arrays}'),
          ('Properties', '${st.keys}'),
          ('Strings', '${st.strings}'),
          ('Numbers', '${st.numbers}'),
          ('Booleans', '${st.booleans}'),
          ('Nulls', '${st.nulls}'),
          ('Longest array', '${st.longestArray}'),
          ('Warnings', '${s.analysis!.warnings.length}'),
          if (s.analysis!.hadBom) ('Byte order mark', 'present (skipped)'),
        ],
      ),
    );
  }
}
