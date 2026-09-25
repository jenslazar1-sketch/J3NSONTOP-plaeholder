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
import '../../domain/ini_document.dart';
import '../../domain/json_tools.dart';
import '../document_io.dart';
import '../widgets/conversion_panes.dart';
import '../widgets/lab_widgets.dart';
import '../widgets/workbench.dart';
import 'ini_controller.dart';

class IniPage extends ConsumerStatefulWidget {
  const IniPage({super.key});

  @override
  ConsumerState<IniPage> createState() => _IniPageState();
}

class _IniPageState extends ConsumerState<IniPage> {
  final FocusNode _focus = FocusNode();
  late final TextEditingController _input = ref.read(draftTextProvider(kIniInputKey));
  late final TextEditingController _fromJson = ref.read(draftTextProvider(kIniFromJsonKey));
  late final TextEditingController _filter = ref.read(draftTextProvider(kIniFilterKey));
  bool _wide = false;

  IniLabController get _c => ref.read(iniLabProvider.notifier);

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
    if (!_wide) ref.setDraft(ConfigWorkbench.paneKey(kIniToolId), kEditorPaneId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _input.jumpTo(line, column);
    });
  }

  String get _baseName {
    final s = ref.read(docSourceProvider(kIniDocKey));
    return s.path == null ? 'settings' : p.basenameWithoutExtension(s.displayName);
  }

  Future<void> _open() async {
    final text = await openIntoEditor(
      context,
      ref,
      docKey: kIniDocKey,
      controller: _input,
      extensions: const ['ini', 'cfg', 'conf', 'txt'],
      title: 'Open INI file',
    );
    if (text != null && text.length > kSyncParseLimit) await _c.validate();
  }

  Future<void> _save({bool saveAs = false}) async {
    await saveDocument(
      context,
      ref,
      toolId: kIniToolId,
      docKey: kIniDocKey,
      text: _input.text,
      suggestedName: '$_baseName.ini',
      saveAs: saveAs,
    );
  }

  Future<void> _clear() async {
    if (!await confirmClear(context)) return;
    _input.clear();
    ref.read(docSourceProvider(kIniDocKey).notifier).set(const DocSource());
  }

  Future<void> _validate() async {
    final d = await _c.validate();
    if (!mounted) return;
    if (_input.text.trim().isEmpty) {
      _notify(NoticeKind.info, 'Nothing to validate: the editor is empty.');
    } else if (d.hasErrors) {
      _notify(NoticeKind.error, '${d.errors.length} invalid line(s); first at line ${d.errors.first.line}');
    } else {
      _notify(
        d.warnings.isEmpty ? NoticeKind.success : NoticeKind.warning,
        'Valid INI: ${d.entries.length} keys${d.warnings.isEmpty ? '' : ', ${d.warnings.length} warning(s)'}',
      );
    }
  }

  Future<void> _editValue(IniLine line) async {
    final value = await showJ3TextInput(
      context,
      title: 'Edit ${line.section.isEmpty ? '' : '[${line.section}] '}${line.key}',
      label: 'Value (line ${line.lineNumber})',
      initial: line.value!,
      monospace: true,
      confirmLabel: 'Apply',
      validator: (v) {
        try {
          IniDocument.encodeValue(v, quote: line.quote);
          return null;
        } on IniEditError catch (e) {
          return e.message;
        }
      },
    );
    if (value == null) return;
    try {
      _c.editValue(line.index, value);
      _notify(NoticeKind.success, 'Line ${line.lineNumber} updated; every other line is unchanged.');
    } on IniEditError catch (e) {
      _notify(NoticeKind.error, e.message);
    }
  }

  Future<void> _addKey(String section) async {
    final key = await showJ3TextInput(
      context,
      title: 'Add key to ${section.isEmpty ? 'the global section' : '[$section]'}',
      label: 'Key',
      monospace: true,
      confirmLabel: 'Next',
      validator: (k) {
        final err = IniDocument.validateKey(k);
        if (err != null) return err;
        final doc = ref.read(iniLabProvider).doc;
        if (doc != null && doc.entries.any((e) => e.section == section && e.key == k)) return 'Key already exists';
        return null;
      },
    );
    if (key == null || !mounted) return;
    final value = await showJ3TextInput(
      context,
      title: 'Value for $key',
      label: 'Value',
      monospace: true,
      confirmLabel: 'Add',
      validator: (v) => v.contains('\n') ? 'Values cannot contain line breaks' : null,
    );
    if (value == null) return;
    try {
      _c.addEntry(section, key, value);
      _notify(NoticeKind.success, 'Added $key; existing lines are unchanged.');
    } on IniEditError catch (e) {
      _notify(NoticeKind.error, e.message);
    }
  }

  Future<void> _addSection() async {
    final name = await showJ3TextInput(
      context,
      title: 'Add section',
      label: 'Section name',
      monospace: true,
      confirmLabel: 'Add',
      validator: (n) {
        final err = IniDocument.validateSectionName(n);
        if (err != null) return err;
        final doc = ref.read(iniLabProvider).doc;
        if (doc != null && doc.sectionNames.contains(n)) return 'Section already exists';
        return null;
      },
    );
    if (name == null) return;
    try {
      _c.addSection(name);
    } on IniEditError catch (e) {
      _notify(NoticeKind.error, e.message);
    }
  }

  Future<void> _remove(IniLine line) async {
    final ok = await showJ3Confirm(
      context,
      title: 'Delete ${line.key}?',
      message: 'Line ${line.lineNumber} ("${line.raw.trim()}") is removed; every other line stays as it is.',
      confirmLabel: 'Delete line',
      destructive: true,
    );
    if (!ok) return;
    _c.removeEntry(line.index);
  }

  Future<void> _convertToJson() async {
    ref.setDraft(ConfigWorkbench.paneKey(kIniToolId), 'tojson');
    try {
      await _c.convertToJson();
    } catch (e) {
      _notify(NoticeKind.error, 'Conversion failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(iniLabProvider);
    final doc = s.doc;
    final empty = _input.text.trim().isEmpty;
    final validity = empty
        ? Validity.empty
        : s.analyzing
        ? Validity.checking
        : s.stale
        ? Validity.stale
        : (doc != null && !doc.hasErrors)
        ? Validity.valid
        : Validity.invalid;
    final message = switch (validity) {
      Validity.empty => 'Paste INI text or open a file.',
      Validity.checking => 'Parsing in the background…',
      Validity.stale => 'Large document edited: press Validate to re-check.',
      Validity.valid =>
        '${doc!.entries.length} keys in ${doc.sectionNames.where((n) => n.isNotEmpty).length} sections'
            '${doc.warnings.isEmpty ? '' : ', ${doc.warnings.length} warning(s)'}',
      Validity.invalid => '${doc?.errors.length ?? 0} invalid line(s)',
    };
    final diagnostics = !s.usable || doc == null ? const <IniDiagnostic>[] : doc.diagnostics;
    return ToolScaffold(
      toolId: kIniToolId,
      children: [
        ConfigWorkbench(
          toolId: kIniToolId,
          onLayout: (w) => _wide = w,
          header: [
            DocumentBar(
              docKey: kIniDocKey,
              controller: _input,
              onOpen: _open,
              onSave: _save,
              onSaveAs: () => _save(saveAs: true),
              onClear: _clear,
            ),
            Wrap(
              spacing: J3Space.sm,
              runSpacing: J3Space.sm,
              children: [
                NeonButton(label: 'Validate', icon: Icons.fact_check_outlined, busy: s.analyzing, onPressed: _validate),
                NeonButton.secondary(
                  label: 'Convert to JSON',
                  icon: Icons.swap_horiz,
                  busy: s.converting,
                  onPressed: empty ? null : _convertToJson,
                ),
              ],
            ),
            StatusLine(
              badge: ValidityBadge(validity: validity),
              message: message,
            ),
            if (diagnostics.isNotEmpty)
              IssueList(
                title: 'Problems',
                items: [
                  for (final d in diagnostics)
                    IssueItem(
                      kind: d.severity == IniSeverity.error ? StatusKind.error : StatusKind.warning,
                      message: d.message,
                      line: d.line,
                    ),
                ],
                onJump: _jump,
              ),
          ],
          editor: EditorPanel(
            controller: _input,
            focusNode: _focus,
            kicker: 'INI TEXT',
            label: 'INI',
            hint: '[Display]\nwidth = 1920',
          ),
          panes: [
            PaneSpec(id: 'table', label: 'Table', icon: Icons.table_rows_outlined, builder: (_) => _tablePane(s)),
            PaneSpec(id: 'tojson', label: 'To JSON', icon: Icons.data_object, builder: (_) => _toJsonPane(s)),
            PaneSpec(id: 'fromjson', label: 'From JSON', icon: Icons.input_rounded, builder: (_) => _fromJsonPane(s)),
          ],
        ),
      ],
    );
  }

  Widget _tablePane(IniLabState s) {
    final doc = s.doc;
    if (s.analyzing) return const LoadingState(label: 'Parsing the large document in the background…');
    if (!s.usable || doc == null) {
      return EmptyState(
        title: 'Validate to refresh',
        message: 'The large document changed since it was last parsed.',
        glyph: '[ ..._... ]',
        action: NeonButton(label: 'Validate', onPressed: _validate),
      );
    }
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _filter,
      builder: (context, f, _) {
        final q = f.text.trim().toLowerCase();
        bool match(IniLine l) =>
            q.isEmpty ||
            l.section.toLowerCase().contains(q) ||
            l.key!.toLowerCase().contains(q) ||
            l.value!.toLowerCase().contains(q);
        final rows = <Object>[];
        final sections = doc.sectionNames;
        for (final name in sections) {
          final entries = [
            for (final e in doc.entries)
              if (e.section == name && match(e)) e,
          ];
          if (q.isNotEmpty && entries.isEmpty) continue;
          rows.add(name);
          rows.addAll(entries);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const LabHint(
              'Lossless editing: changing a value rewrites only that line. Comments, blank lines, spacing, '
              'order and line endings elsewhere stay byte-for-byte identical.',
            ),
            const SizedBox(height: J3Space.sm),
            TextField(
              controller: _filter,
              style: J3Type.code,
              decoration: const InputDecoration(
                labelText: 'Filter sections, keys and values',
                prefixIcon: Icon(Icons.filter_list),
              ),
            ),
            const SizedBox(height: J3Space.sm),
            Wrap(
              spacing: J3Space.sm,
              runSpacing: J3Space.sm,
              children: [
                NeonButton.secondary(
                  label: 'Add section',
                  icon: Icons.add_box_outlined,
                  dense: true,
                  onPressed: _addSection,
                ),
                if (!sections.contains(''))
                  NeonButton.ghost(label: 'Add global key', icon: Icons.add, dense: true, onPressed: () => _addKey('')),
              ],
            ),
            const SizedBox(height: J3Space.sm),
            if (rows.isEmpty)
              EmptyState(
                title: q.isEmpty ? 'No keys yet' : 'Nothing matches "${f.text}"',
                message: q.isEmpty ? 'Add a section and keys, or type in the editor.' : null,
              )
            else
              Container(
                height: 480,
                decoration: BoxDecoration(
                  color: J3Colors.inputFill,
                  borderRadius: J3Radius.small,
                  border: Border.all(color: J3Colors.border),
                ),
                child: InkLayer(
                  child: ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final r = rows[i];
                      return r is String ? _sectionRow(doc, r) : _entryRow(r as IniLine);
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _sectionRow(IniDocument doc, String name) {
    final count = doc.entries.where((e) => e.section == name).length;
    return Container(
      color: J3Colors.surfaceRaised,
      padding: const EdgeInsets.only(left: J3Space.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name.isEmpty ? 'GLOBAL (before any section) · $count' : '[$name] · $count',
              style: J3Type.label.copyWith(color: context.effects.accentText),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'Add key to ${name.isEmpty ? 'global section' : '[$name]'}',
            onPressed: () => _addKey(name),
            icon: const Icon(Icons.add, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _entryRow(IniLine l) {
    return Semantics(
      label: '${l.key} equals ${l.value}, line ${l.lineNumber}',
      child: Padding(
        padding: const EdgeInsets.only(left: J3Space.md),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.key!,
                    style: J3Type.code.copyWith(color: J3Colors.text),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${l.quoted
                        ? '${l.quote}${l.value}${l.quote}'
                        : l.value!.isEmpty
                        ? '(empty)'
                        : l.value}  ·  L${l.lineNumber}',
                    style: J3Type.codeSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Edit value of ${l.key}',
              onPressed: () => _editValue(l),
              icon: const Icon(Icons.edit_outlined, size: 18),
            ),
            IconButton(
              tooltip: 'Delete ${l.key}',
              onPressed: () => _remove(l),
              icon: const Icon(Icons.delete_outline, size: 18),
            ),
            IconButton(
              tooltip: 'Show line ${l.lineNumber} in the editor',
              onPressed: () => _jump(l.lineNumber, 1),
              icon: const Icon(Icons.my_location, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toJsonPane(IniLabState s) {
    final r = s.toJson;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeonPanel(
          kicker: 'INI -> JSON',
          title: 'Convert the editor text',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LabSwitch(
                label: 'Infer numbers and booleans (changes representation)',
                description:
                    'Off: every value stays a string (lossless). On: "1920" becomes 1920 and "true" '
                    'becomes true; each inferred value is listed. Quoted values are never inferred.',
                value: s.inferTypes,
                onChanged: _c.setInferTypes,
              ),
              ChoiceRow<JsonIndent>(
                label: 'JSON indent',
                options: JsonIndent.values,
                selected: s.indent,
                labelOf: (i) => i.label,
                onSelected: _c.setIndent,
              ),
              const SizedBox(height: J3Space.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: NeonButton(
                  label: 'Convert to JSON',
                  icon: Icons.swap_horiz,
                  busy: s.converting,
                  onPressed: _input.text.trim().isEmpty ? null : _convertToJson,
                ),
              ),
            ],
          ),
        ),
        if (r != null) ...[
          const SizedBox(height: J3Space.md),
          ConversionOutputView(
            result: r,
            toolId: kIniToolId,
            fileName: '$_baseName.json',
            mimeType: 'application/json',
            stale: s.toJsonSource != _input.text,
            onJumpToLine: (l) => _jump(l, 1),
          ),
        ],
      ],
    );
  }

  Widget _fromJsonPane(IniLabState s) {
    final r = s.fromJson;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        JsonInputPanel(
          controller: _fromJson,
          convertLabel: 'Convert to INI',
          busy: s.converting,
          hint: '{"Display": {"width": 1920}}',
          onConvert: () async {
            try {
              await _c.convertFromJson(_fromJson.text);
            } catch (e) {
              _notify(NoticeKind.error, 'Conversion failed: $e');
            }
          },
          options: const [
            LabHint(
              'Expects an object: top-level scalars become global keys, objects become sections of scalar '
              'values. Deeper nesting, arrays and nulls are listed as errors. Numbers and booleans become text.',
            ),
          ],
        ),
        if (r != null) ...[
          const SizedBox(height: J3Space.md),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _fromJson,
            builder: (context, v, _) => ConversionOutputView(
              result: r,
              toolId: kIniToolId,
              fileName: 'converted.ini',
              mimeType: 'text/plain',
              stale: s.fromJsonSource != v.text,
              onUse: r.output == null
                  ? null
                  : () => useAsEditorText(context, ref, docKey: kIniDocKey, editor: _input, text: r.output!),
            ),
          ),
        ],
      ],
    );
  }
}
