import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/json_tools.dart';
import '../../domain/json_value.dart';
import '../../domain/yaml_codec.dart';
import '../document_io.dart';
import '../widgets/conversion_panes.dart';
import '../widgets/lab_widgets.dart';
import '../widgets/value_tree.dart';
import '../widgets/workbench.dart';
import 'yaml_controller.dart';

class YamlPage extends ConsumerStatefulWidget {
  const YamlPage({super.key});

  @override
  ConsumerState<YamlPage> createState() => _YamlPageState();
}

class _YamlPageState extends ConsumerState<YamlPage> {
  final FocusNode _focus = FocusNode();
  late final TextEditingController _input = ref.read(draftTextProvider(kYamlInputKey));
  late final TextEditingController _fromJson = ref.read(draftTextProvider(kYamlFromJsonKey));
  bool _wide = false;

  YamlLabController get _c => ref.read(yamlLabProvider.notifier);

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
    if (!_wide) ref.setDraft(ConfigWorkbench.paneKey(kYamlToolId), kEditorPaneId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _input.jumpTo(line, column);
    });
  }

  String get _baseName {
    final s = ref.read(docSourceProvider(kYamlDocKey));
    return s.path == null ? 'document' : p.basenameWithoutExtension(s.displayName);
  }

  Future<void> _open() async {
    final text = await openIntoEditor(
      context,
      ref,
      docKey: kYamlDocKey,
      controller: _input,
      extensions: const ['yaml', 'yml', 'txt'],
      title: 'Open YAML file',
    );
    if (text != null && text.length > kSyncParseLimit) await _validate();
  }

  Future<void> _save({bool saveAs = false}) async {
    if (!ref.read(yamlLabProvider).usable && _input.text.trim().isNotEmpty) {
      final ok = await showJ3Confirm(
        context,
        title: 'Save invalid YAML?',
        message: 'The text does not parse as YAML (or has not been validated). Save it anyway?',
        confirmLabel: 'Save anyway',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    await saveDocument(
      context,
      ref,
      toolId: kYamlToolId,
      docKey: kYamlDocKey,
      text: _input.text,
      suggestedName: '$_baseName.yaml',
      mimeType: 'application/yaml',
      saveAs: saveAs,
    );
  }

  Future<void> _clear() async {
    if (!await confirmClear(context)) return;
    _input.clear();
    ref.read(docSourceProvider(kYamlDocKey).notifier).set(const DocSource());
  }

  Future<void> _validate() async {
    final c = await _c.validate();
    if (!mounted) return;
    if (c.empty) {
      _notify(NoticeKind.info, 'Nothing to validate: the editor is empty.');
    } else if (c.valid) {
      _notify(NoticeKind.success, 'Valid YAML (${_docs(c.documents.length)})');
    } else {
      _notify(NoticeKind.error, 'Invalid YAML: ${c.error!.describe()}');
    }
  }

  Future<void> _convertToJson() async {
    ref.setDraft(ConfigWorkbench.paneKey(kYamlToolId), 'tojson');
    try {
      await _c.convertToJson();
    } catch (e) {
      _notify(NoticeKind.error, 'Conversion failed: $e');
    }
  }

  Future<void> _convertFromJson() async {
    try {
      await _c.convertFromJson(_fromJson.text);
    } catch (e) {
      _notify(NoticeKind.error, 'Conversion failed: $e');
    }
  }

  Future<void> _treeAction(TreeAction a, TreeRow row) async {
    final where = formatJsonPath(row.path);
    switch (a) {
      case TreeAction.copyPath:
        await copyWithNotice(ref, where, 'JSONPath $where');
      case TreeAction.copyValue:
        await copyWithNotice(ref, encodeJson(yamlDisplayToJsonLike(row.value)), 'value of $where');
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(yamlLabProvider);
    final check = s.check;
    final empty = _input.text.trim().isEmpty;
    final validity = empty
        ? Validity.empty
        : s.analyzing
        ? Validity.checking
        : s.stale
        ? Validity.stale
        : (check?.valid ?? false)
        ? Validity.valid
        : Validity.invalid;
    final message = switch (validity) {
      Validity.empty => 'Paste YAML or open a file.',
      Validity.checking => 'Validating in the background…',
      Validity.stale => 'Large document edited: press Validate to re-check.',
      Validity.valid => _docs(check!.documents.length),
      Validity.invalid => check?.error?.describe(),
    };
    return ToolScaffold(
      toolId: kYamlToolId,
      children: [
        ConfigWorkbench(
          toolId: kYamlToolId,
          onLayout: (w) => _wide = w,
          header: [
            DocumentBar(
              docKey: kYamlDocKey,
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
            if (validity == Validity.invalid && check?.error != null)
              ParseErrorPanel(error: check!.error!, onJump: (l) => _jump(l.line, l.column)),
          ],
          editor: EditorPanel(
            controller: _input,
            focusNode: _focus,
            kicker: 'YAML TEXT',
            label: 'YAML',
            hint: 'player:\n  name: Kaya\n  hp: 10',
          ),
          panes: [
            PaneSpec(id: 'tree', label: 'Tree', icon: Icons.account_tree_outlined, builder: (_) => _treePane(s)),
            PaneSpec(id: 'tojson', label: 'To JSON', icon: Icons.data_object, builder: (_) => _toJsonPane(s)),
            PaneSpec(id: 'fromjson', label: 'From JSON', icon: Icons.input_rounded, builder: (_) => _fromJsonPane(s)),
          ],
        ),
      ],
    );
  }

  Widget _treePane(YamlLabState s) {
    if (_input.text.trim().isEmpty) {
      return const EmptyState(title: 'No document', message: 'Paste YAML or open a file to browse it.', glyph: '- -');
    }
    if (s.analyzing) return const LoadingState(label: 'Parsing the large document in the background…');
    if (!s.usable) {
      return EmptyState(
        title: s.stale ? 'Validate to refresh' : 'Fix the YAML error first',
        message: s.stale ? 'The large document changed since it was last checked.' : 'The tree appears once it parses.',
        glyph: '[ x_x ]',
        action: s.stale ? NeonButton(label: 'Validate', onPressed: _validate) : null,
      );
    }
    final docs = s.check!.documents;
    if (docs.isEmpty) {
      return const EmptyState(title: 'No documents', message: 'The stream only contains comments or markers.');
    }
    final index = s.docIndex.clamp(0, docs.length - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (docs.length > 1) ...[
          ChoiceRow<int>(
            label: 'Document (${docs.length} in this stream)',
            options: [for (var i = 0; i < docs.length && i < 30; i++) i],
            selected: index,
            labelOf: (i) => '${i + 1}',
            onSelected: _c.setDoc,
          ),
          if (docs.length > 30) const LabHint('Only the first 30 documents can be selected here.'),
          const SizedBox(height: J3Space.sm),
        ],
        const LabHint(
          'Read-only view of the parsed data: aliases appear expanded and tags are applied. Edit the YAML text to change it.',
        ),
        const SizedBox(height: J3Space.sm),
        ValueTreeView(
          root: docs[index],
          expanded: s.expanded,
          onToggle: _c.toggle,
          onAction: _treeAction,
          rootLabel: docs.length > 1 ? 'document ${index + 1}' : 'document',
        ),
      ],
    );
  }

  Widget _toJsonPane(YamlLabState s) {
    final r = s.toJson;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeonPanel(
          kicker: 'YAML -> JSON',
          title: 'Convert the editor text',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ChoiceRow<YamlMultiDoc>(
                label: 'Several documents (---)',
                options: YamlMultiDoc.values,
                selected: s.multiDoc,
                labelOf: (m) => m.label,
                onSelected: _c.setMultiDoc,
              ),
              const SizedBox(height: J3Space.sm),
              ChoiceRow<JsonIndent>(
                label: 'JSON indent',
                options: JsonIndent.values,
                selected: s.indent,
                labelOf: (i) => i.label,
                onSelected: _c.setIndent,
              ),
              const SizedBox(height: J3Space.sm),
              const LabHint(
                'Every difference is itemised: comments, anchors/aliases, tags, directives, non-string keys, '
                'special floats, merge keys and multiple documents.',
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
            toolId: kYamlToolId,
            fileName: '$_baseName.json',
            mimeType: 'application/json',
            stale: s.toJsonSource != _input.text,
            onJumpToLine: (l) => _jump(l, 1),
          ),
        ],
      ],
    );
  }

  Widget _fromJsonPane(YamlLabState s) {
    final r = s.fromJson;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        JsonInputPanel(
          controller: _fromJson,
          convertLabel: 'Convert to YAML',
          busy: s.converting,
          onConvert: _convertFromJson,
          options: const [
            LabHint(
              'Block-style output. Strings that YAML readers could misread (yes/no/on/off/null/~, numbers, dates) '
              'are quoted; multi-line strings become literal blocks. The YAML is re-parsed and compared with the '
              'JSON before it is shown.',
            ),
          ],
        ),
        if (r != null) ...[
          const SizedBox(height: J3Space.md),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _fromJson,
            builder: (context, v, _) => ConversionOutputView(
              result: r,
              toolId: kYamlToolId,
              fileName: 'converted.yaml',
              mimeType: 'application/yaml',
              stale: s.fromJsonSource != v.text,
              useLabel: 'Use as editor text',
              onUse: r.output == null
                  ? null
                  : () => useAsEditorText(context, ref, docKey: kYamlDocKey, editor: _input, text: r.output!),
            ),
          ),
        ],
      ],
    );
  }
}

String _docs(int n) => n == 1 ? '1 document' : '$n documents';
