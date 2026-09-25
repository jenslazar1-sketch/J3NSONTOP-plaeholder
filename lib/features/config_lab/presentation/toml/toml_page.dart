import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart' show TomlDateTime;

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/json_tools.dart';
import '../../domain/json_value.dart';
import '../../domain/toml_codec.dart';
import '../document_io.dart';
import '../widgets/conversion_panes.dart';
import '../widgets/lab_widgets.dart';
import '../widgets/value_tree.dart';
import '../widgets/workbench.dart';
import 'toml_controller.dart';

/// Tree describer that labels TOML date/time values.
TreeTypeInfo describeTomlNode(Object? v, EffectsConfig fx) {
  if (v is TomlDateTime) {
    return TreeTypeInfo(
      label: 'date',
      fullName: tomlDateTimeKind(v),
      color: J3Colors.info,
      preview: tomlDateTimeToIso(v),
    );
  }
  if (v is double && !v.isFinite) {
    return TreeTypeInfo(
      label: 'num',
      fullName: 'float',
      color: J3Colors.warning,
      preview: v.isNaN ? 'nan' : (v > 0 ? 'inf' : '-inf'),
    );
  }
  return describeJsonNode(v, fx);
}

class TomlPage extends ConsumerStatefulWidget {
  const TomlPage({super.key});

  @override
  ConsumerState<TomlPage> createState() => _TomlPageState();
}

class _TomlPageState extends ConsumerState<TomlPage> {
  final FocusNode _focus = FocusNode();
  late final TextEditingController _input = ref.read(draftTextProvider(kTomlInputKey));
  late final TextEditingController _fromJson = ref.read(draftTextProvider(kTomlFromJsonKey));
  bool _wide = false;

  TomlLabController get _c => ref.read(tomlLabProvider.notifier);

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
    if (!_wide) ref.setDraft(ConfigWorkbench.paneKey(kTomlToolId), kEditorPaneId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _input.jumpTo(line, column);
    });
  }

  String get _baseName {
    final s = ref.read(docSourceProvider(kTomlDocKey));
    return s.path == null ? 'document' : p.basenameWithoutExtension(s.displayName);
  }

  Future<void> _open() async {
    final text = await openIntoEditor(
      context,
      ref,
      docKey: kTomlDocKey,
      controller: _input,
      extensions: const ['toml', 'txt'],
      title: 'Open TOML file',
    );
    if (text != null && text.length > kSyncParseLimit) await _validate();
  }

  Future<void> _save({bool saveAs = false}) async {
    if (!ref.read(tomlLabProvider).usable && _input.text.trim().isNotEmpty) {
      final ok = await showJ3Confirm(
        context,
        title: 'Save invalid TOML?',
        message: 'The text does not parse as TOML (or has not been validated). Save it anyway?',
        confirmLabel: 'Save anyway',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    await saveDocument(
      context,
      ref,
      toolId: kTomlToolId,
      docKey: kTomlDocKey,
      text: _input.text,
      suggestedName: '$_baseName.toml',
      mimeType: 'application/toml',
      saveAs: saveAs,
    );
  }

  Future<void> _clear() async {
    if (!await confirmClear(context)) return;
    _input.clear();
    ref.read(docSourceProvider(kTomlDocKey).notifier).set(const DocSource());
  }

  Future<void> _validate() async {
    final c = await _c.validate();
    if (!mounted) return;
    if (c.empty) {
      _notify(NoticeKind.info, 'Nothing to validate: the editor is empty.');
    } else if (c.valid) {
      _notify(NoticeKind.success, 'Valid TOML (${c.value!.length} top-level keys)');
    } else {
      _notify(NoticeKind.error, 'Invalid TOML: ${c.error!.describe()}');
    }
  }

  Future<void> _convertToJson() async {
    ref.setDraft(ConfigWorkbench.paneKey(kTomlToolId), 'tojson');
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
        await copyWithNotice(ref, encodeJson(tomlValueToJsonLike(row.value)), 'value of $where');
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(tomlLabProvider);
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
      Validity.empty => 'Paste TOML or open a file.',
      Validity.checking => 'Validating in the background…',
      Validity.stale => 'Large document edited: press Validate to re-check.',
      Validity.valid => '${check!.value!.length} top-level key(s)',
      Validity.invalid => check?.error?.describe(),
    };
    return ToolScaffold(
      toolId: kTomlToolId,
      children: [
        ConfigWorkbench(
          toolId: kTomlToolId,
          onLayout: (w) => _wide = w,
          header: [
            DocumentBar(
              docKey: kTomlDocKey,
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
            kicker: 'TOML TEXT',
            label: 'TOML',
            hint: '[player]\nhp = 100',
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

  Widget _treePane(TomlLabState s) {
    if (_input.text.trim().isEmpty) {
      return const EmptyState(title: 'No document', message: 'Paste TOML or open a file to browse it.', glyph: '[ ]');
    }
    if (s.analyzing) return const LoadingState(label: 'Parsing the large document in the background…');
    if (!s.usable) {
      return EmptyState(
        title: s.stale ? 'Validate to refresh' : 'Fix the TOML error first',
        message: s.stale ? 'The large document changed since it was last checked.' : 'The tree appears once it parses.',
        glyph: '[ x_x ]',
        action: s.stale ? NeonButton(label: 'Validate', onPressed: _validate) : null,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const LabHint('Read-only view of the parsed tables. Date/time values are labelled "date".'),
        const SizedBox(height: J3Space.sm),
        ValueTreeView(
          root: s.check!.value,
          expanded: s.expanded,
          onToggle: _c.toggle,
          onAction: _treeAction,
          describe: describeTomlNode,
          rootLabel: 'document',
        ),
      ],
    );
  }

  Widget _toJsonPane(TomlLabState s) {
    final r = s.toJson;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeonPanel(
          kicker: 'TOML -> JSON',
          title: 'Convert the editor text',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ChoiceRow<JsonIndent>(
                label: 'JSON indent',
                options: JsonIndent.values,
                selected: s.indent,
                labelOf: (i) => i.label,
                onSelected: _c.setIndent,
              ),
              const SizedBox(height: J3Space.sm),
              const LabHint(
                'Date-times become ISO-8601 strings, inf/nan become strings, comments are dropped: each case is listed.',
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
            toolId: kTomlToolId,
            fileName: '$_baseName.json',
            mimeType: 'application/json',
            stale: s.toJsonSource != _input.text,
            onJumpToLine: (l) => _jump(l, 1),
          ),
        ],
      ],
    );
  }

  Widget _fromJsonPane(TomlLabState s) {
    final r = s.fromJson;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        JsonInputPanel(
          controller: _fromJson,
          convertLabel: 'Convert to TOML',
          busy: s.converting,
          onConvert: _convertFromJson,
          options: [
            LabSwitch(
              label: 'Drop null properties',
              description:
                  'TOML has no null. When on, null object properties are removed (each one reported); '
                  'otherwise they are errors.',
              value: s.dropNulls,
              onChanged: _c.setDropNulls,
            ),
            const LabHint(
              'The top level must be an object. Nulls, key-order changes and mixed-type arrays are reported. '
              'The TOML is re-parsed and compared with the JSON before it is shown.',
            ),
          ],
        ),
        if (r != null) ...[
          const SizedBox(height: J3Space.md),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _fromJson,
            builder: (context, v, _) => ConversionOutputView(
              result: r,
              toolId: kTomlToolId,
              fileName: 'converted.toml',
              mimeType: 'application/toml',
              stale: s.fromJsonSource != v.text,
              onUse: r.output == null
                  ? null
                  : () => useAsEditorText(context, ref, docKey: kTomlDocKey, editor: _input, text: r.output!),
            ),
          ),
        ],
      ],
    );
  }
}
