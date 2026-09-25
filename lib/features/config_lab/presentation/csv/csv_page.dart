import 'dart:math' as math;

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
import '../../domain/csv_codec.dart';
import '../../domain/json_tools.dart';
import '../document_io.dart';
import '../widgets/conversion_panes.dart';
import '../widgets/lab_widgets.dart';
import '../widgets/workbench.dart';
import 'csv_controller.dart';

class CsvPage extends ConsumerStatefulWidget {
  const CsvPage({super.key});

  @override
  ConsumerState<CsvPage> createState() => _CsvPageState();
}

class _CsvPageState extends ConsumerState<CsvPage> {
  final FocusNode _focus = FocusNode();
  late final TextEditingController _input = ref.read(draftTextProvider(kCsvInputKey));
  late final TextEditingController _fromJson = ref.read(draftTextProvider(kCsvFromJsonKey));
  final TextEditingController _filter = TextEditingController();
  final ScrollController _hScroll = ScrollController();
  bool _wide = false;

  CsvLabController get _c => ref.read(csvLabProvider.notifier);

  @override
  void initState() {
    super.initState();
    _filter.text = ref.read(csvLabProvider).filterQuery;
    _input.addListener(_onInput);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onInput();
    });
  }

  @override
  void dispose() {
    _input.removeListener(_onInput);
    _focus.dispose();
    _filter.dispose();
    _hScroll.dispose();
    super.dispose();
  }

  void _onInput() => _c.textChanged(_input.text);

  void _notify(NoticeKind kind, String message) => ref.read(activityProvider.notifier).notify(kind, message);

  void _jump(int line, int column) {
    if (!_wide) ref.setDraft(ConfigWorkbench.paneKey(kCsvToolId), kEditorPaneId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _input.jumpTo(line, column);
    });
  }

  String get _baseName {
    final s = ref.read(docSourceProvider(kCsvDocKey));
    return s.path == null ? 'table' : p.basenameWithoutExtension(s.displayName);
  }

  String get _ext => ref.read(csvLabProvider).analysis?.delimiter == '\t' ? 'tsv' : 'csv';

  Future<void> _open() async {
    final text = await openIntoEditor(
      context,
      ref,
      docKey: kCsvDocKey,
      controller: _input,
      extensions: const ['csv', 'tsv', 'tab', 'txt'],
      title: 'Open CSV or TSV file',
    );
    if (text != null && text.length > kSyncParseLimit) await _c.analyze();
  }

  Future<void> _save({bool saveAs = false}) => saveDocument(
    context,
    ref,
    toolId: kCsvToolId,
    docKey: kCsvDocKey,
    text: _input.text,
    suggestedName: '$_baseName.$_ext',
    mimeType: _ext == 'tsv' ? 'text/tab-separated-values' : 'text/csv',
    saveAs: saveAs,
  );

  Future<void> _clear() async {
    if (!await confirmClear(context)) return;
    _input.clear();
    ref.read(docSourceProvider(kCsvDocKey).notifier).set(const DocSource());
  }

  Future<void> _analyze() async {
    final a = await _c.analyze();
    if (!mounted) return;
    if (a.table.hasErrors) {
      _notify(
        NoticeKind.error,
        'Parse error: ${a.table.diagnostics.first.message} (line ${a.table.diagnostics.first.line})',
      );
    } else {
      _notify(NoticeKind.success, '${a.stats.rows} records, ${a.stats.columns} columns');
    }
  }

  Future<void> _convert() async {
    try {
      await _c.convert();
    } catch (e) {
      _notify(NoticeKind.error, 'Conversion failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(csvLabProvider);
    final a = s.analysis;
    final empty = _input.text.trim().isEmpty;
    final validity = empty
        ? Validity.empty
        : s.analyzing
        ? Validity.checking
        : s.stale
        ? Validity.stale
        : (a != null && !a.table.hasErrors)
        ? Validity.valid
        : Validity.invalid;
    final delimName = a == null ? '' : (CsvDelimiter.of(a.delimiter)?.label.toLowerCase() ?? a.delimiter);
    final message = switch (validity) {
      Validity.empty => 'Paste CSV/TSV or open a file.',
      Validity.checking => 'Parsing in the background…',
      Validity.stale => 'Large table edited or options changed: press Parse to refresh.',
      Validity.valid =>
        '${a!.stats.rows} records, ${a.stats.columns} columns, $delimName-separated${a.detected ? ' (detected)' : ''}'
            '${a.stats.raggedRows.isEmpty ? '' : ', ${a.stats.raggedRows.length} ragged'}',
      Validity.invalid => a?.table.diagnostics.firstWhere((d) => d.severity == CsvSeverity.error).message,
    };
    final diags = s.usable && a != null ? a.table.diagnostics : const <CsvDiagnostic>[];
    return ToolScaffold(
      toolId: kCsvToolId,
      children: [
        ConfigWorkbench(
          toolId: kCsvToolId,
          onLayout: (w) => _wide = w,
          header: [
            DocumentBar(
              docKey: kCsvDocKey,
              controller: _input,
              onOpen: _open,
              onSave: _save,
              onSaveAs: () => _save(saveAs: true),
              onClear: _clear,
            ),
            _options(s),
            StatusLine(
              badge: ValidityBadge(validity: validity),
              message: message,
            ),
            if (diags.isNotEmpty)
              IssueList(
                title: 'Parse problems',
                items: [
                  for (final d in diags)
                    IssueItem(
                      kind: d.severity == CsvSeverity.error ? StatusKind.error : StatusKind.warning,
                      message: d.message,
                      line: d.line,
                      column: d.column,
                    ),
                ],
                onJump: _jump,
              ),
          ],
          editor: EditorPanel(
            controller: _input,
            focusNode: _focus,
            kicker: 'CSV / TSV TEXT',
            label: 'Delimited text',
            hint: 'id,name,price\n1,Potion,5',
          ),
          panes: [
            PaneSpec(id: 'table', label: 'Table', icon: Icons.table_chart_outlined, builder: (_) => _tablePane(s)),
            PaneSpec(id: 'stats', label: 'Stats', icon: Icons.query_stats, builder: (_) => _statsPane(s)),
            PaneSpec(id: 'convert', label: 'Convert', icon: Icons.swap_horiz, builder: (_) => _convertPane(s)),
            PaneSpec(id: 'fromjson', label: 'From JSON', icon: Icons.input_rounded, builder: (_) => _fromJsonPane(s)),
          ],
        ),
      ],
    );
  }

  Widget _options(CsvLabState s) {
    final detected = s.analysis?.detected == true ? CsvDelimiter.of(s.analysis!.delimiter)?.label : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChoiceRow<CsvDelimiter?>(
          label: 'Delimiter',
          options: const [null, ...CsvDelimiter.values],
          selected: s.delimiter,
          labelOf: (d) => d == null ? 'Auto${detected == null ? '' : ' ($detected)'}' : d.label,
          onSelected: _c.setDelimiter,
        ),
        const SizedBox(height: J3Space.sm),
        ChoiceRow<String>(
          label: 'Quote character',
          options: const ['"', "'"],
          selected: s.quote,
          labelOf: (q) => q == '"' ? 'Double quote "' : "Single quote '",
          onSelected: _c.setQuote,
        ),
        LabSwitch(
          label: 'First row is header',
          description: 'Used for column names in the table and for JSON object keys',
          value: s.header,
          onChanged: _c.setHeader,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: NeonButton(label: 'Parse', icon: Icons.table_view, busy: s.analyzing, onPressed: _analyze),
        ),
      ],
    );
  }

  List<String> _columnLabels(CsvLabState s) {
    final a = s.analysis!;
    final cols = a.stats.columns;
    final head = s.header && a.table.rows.isNotEmpty ? a.table.rows.first : const <String>[];
    return [
      for (var i = 0; i < cols; i++)
        i < head.length
            ? (head[i].isEmpty ? 'Column ${i + 1}' : head[i])
            : (s.header ? 'Column ${i + 1} (extra)' : 'Column ${i + 1}'),
    ];
  }

  Widget _notReady(CsvLabState s) {
    if (s.analyzing) return const LoadingState(label: 'Parsing the large table in the background…');
    if (_input.text.trim().isEmpty) {
      return const EmptyState(title: 'No table', message: 'Paste CSV/TSV text or open a file.', glyph: '|_|_|');
    }
    return EmptyState(
      title: 'Parse to refresh',
      message: 'The table changed since it was last parsed.',
      glyph: '[ ..._... ]',
      action: NeonButton(label: 'Parse', onPressed: _analyze),
    );
  }

  Widget _tablePane(CsvLabState s) {
    final a = s.analysis;
    if (!s.usable || a == null || _input.text.trim().isEmpty) return _notReady(s);
    final labels = _columnLabels(s);
    final rows = a.table.rows;
    final indices = s.filtered ?? [for (var r = s.firstDataRow; r < rows.length; r++) r];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _filter,
          style: J3Type.code,
          decoration: const InputDecoration(labelText: 'Filter rows', prefixIcon: Icon(Icons.filter_list)),
          onChanged: (v) => _c.setFilter(query: v),
        ),
        const SizedBox(height: J3Space.sm),
        DropdownButtonFormField<int>(
          initialValue: s.filterColumn < labels.length ? s.filterColumn : -1,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Filter in column'),
          items: [
            const DropdownMenuItem(value: -1, child: Text('All columns')),
            for (var i = 0; i < labels.length; i++)
              DropdownMenuItem(
                value: i,
                child: Text(labels[i], overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => _c.setFilter(column: v ?? -1),
        ),
        const SizedBox(height: J3Space.sm),
        Text(
          s.filtered == null
              ? '${indices.length} data rows × ${labels.length} columns'
              : '${indices.length} of ${rows.length - s.firstDataRow} rows match',
          style: J3Type.caption,
        ),
        const SizedBox(height: J3Space.sm),
        if (labels.isEmpty)
          const EmptyState(title: 'No columns')
        else
          _TableView(table: a.table, labels: labels, indices: indices, controller: _hScroll, onJump: _jump),
      ],
    );
  }

  Widget _statsPane(CsvLabState s) {
    final a = s.analysis;
    if (!s.usable || a == null || _input.text.trim().isEmpty) return _notReady(s);
    final st = a.stats;
    final eol = switch (a.table.lineEnding) {
      '\r\n' => 'CRLF',
      '\r' => 'CR',
      _ => 'LF',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeonPanel(
          kicker: 'STATISTICS',
          title: 'Table shape',
          child: KeyValueTable(
            rows: [
              ('Records', '${st.rows}${s.header ? ' (1 header + ${math.max(0, st.rows - 1)} data)' : ''}'),
              ('Columns', '${st.columns} (first record: ${st.expectedColumns})'),
              ('Ragged rows', '${st.raggedRows.length}'),
              ('Empty cells', '${st.emptyCells} of ${st.totalCells}'),
              (
                'Delimiter',
                '${CsvDelimiter.of(a.delimiter)?.label ?? a.delimiter}${a.detected ? ' (auto-detected)' : ' (manual)'}',
              ),
              ('Line endings', '$eol${a.table.endsWithNewline ? ', final newline' : ', no final newline'}'),
              ('Byte order mark', a.table.hadBom ? 'present (skipped)' : 'none'),
              ('Skipped blank lines', a.table.blankLines.isEmpty ? 'none' : a.table.blankLines.join(', ')),
            ],
          ),
        ),
        if (st.raggedRows.isNotEmpty) ...[
          const SizedBox(height: J3Space.md),
          IssueList(
            kicker: 'RAGGED ROWS',
            title: 'Rows with a different field count',
            items: [
              for (final (r, line, n) in st.raggedRows)
                IssueItem(
                  kind: StatusKind.warning,
                  message: 'Record ${r + 1} has $n field(s); the first record has ${st.expectedColumns}',
                  line: line,
                ),
            ],
            onJump: _jump,
          ),
        ],
      ],
    );
  }

  Widget _convertPane(CsvLabState s) {
    final a = s.analysis;
    final fromTab = (a?.delimiter ?? s.delimiter?.char) == '\t';
    final swapLabel = fromTab ? 'CSV (comma)' : 'TSV (tab)';
    final r = s.converted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeonPanel(
          kicker: 'CONVERT',
          title: 'Convert the editor table',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ChoiceRow<CsvTarget>(
                label: 'Target',
                options: CsvTarget.values,
                selected: s.target,
                labelOf: (t) => t == CsvTarget.json ? 'JSON' : swapLabel,
                onSelected: _c.setTarget,
              ),
              const SizedBox(height: J3Space.sm),
              if (s.target == CsvTarget.json) ...[
                ChoiceRow<CsvJsonShape>(
                  label: 'JSON shape',
                  options: CsvJsonShape.values,
                  selected: s.shape,
                  labelOf: (v) => v.label,
                  onSelected: _c.setShape,
                ),
                LabSwitch(
                  label: 'Infer numbers, booleans and null (changes representation)',
                  description:
                      'Off: every cell stays a string. On: "42" becomes 42, "true" becomes true and "null" '
                      'becomes null; every inferred cell is listed.',
                  value: s.infer,
                  onChanged: _c.setInfer,
                ),
                ChoiceRow<JsonIndent>(
                  label: 'JSON indent',
                  options: JsonIndent.values,
                  selected: s.indent,
                  labelOf: (i) => i.label,
                  onSelected: _c.setIndent,
                ),
              ] else
                LabHint(
                  'Lossless unless a cell contains the target delimiter, a quote or a line break: those cells are '
                  'quoted and listed${fromTab ? '' : ' (TSV readers without quote support would misread them)'}.',
                ),
              const SizedBox(height: J3Space.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: NeonButton(
                  label: 'Convert',
                  icon: Icons.swap_horiz,
                  busy: s.converting,
                  onPressed: _input.text.trim().isEmpty ? null : _convert,
                ),
              ),
            ],
          ),
        ),
        if (r != null) ...[
          const SizedBox(height: J3Space.md),
          ConversionOutputView(
            result: r,
            toolId: kCsvToolId,
            fileName: '$_baseName.${r.report.to.toLowerCase()}',
            mimeType: r.report.to == 'JSON'
                ? 'application/json'
                : r.report.to == 'TSV'
                ? 'text/tab-separated-values'
                : 'text/csv',
            stale: !s.usable || s.convertedKey != s.analyzedKey,
            onJumpToLine: (l) => _jump(l, 1),
          ),
        ],
      ],
    );
  }

  Widget _fromJsonPane(CsvLabState s) {
    final r = s.fromJson;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        JsonInputPanel(
          controller: _fromJson,
          convertLabel: 'Convert to ${s.fromJsonDelimiter == CsvDelimiter.tab ? 'TSV' : 'CSV'}',
          busy: s.converting,
          hint: '[{"id": 1, "name": "Potion"}]',
          onConvert: () async {
            try {
              await _c.convertFromJson(_fromJson.text);
            } catch (e) {
              _notify(NoticeKind.error, 'Conversion failed: $e');
            }
          },
          options: [
            ChoiceRow<CsvDelimiter>(
              label: 'Output delimiter',
              options: CsvDelimiter.values,
              selected: s.fromJsonDelimiter,
              labelOf: (d) => d.label,
              onSelected: _c.setFromJsonDelimiter,
            ),
            LabSwitch(
              label: 'Flatten nested values to dotted columns (changes representation)',
              description:
                  'Off: nested objects/arrays are errors listing their paths. On: {"a":{"b":1}} becomes '
                  'column "a.b".',
              value: s.flatten,
              onChanged: _c.setFlatten,
            ),
          ],
        ),
        if (r != null) ...[
          const SizedBox(height: J3Space.md),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _fromJson,
            builder: (context, v, _) => ConversionOutputView(
              result: r,
              toolId: kCsvToolId,
              fileName: 'converted.${r.report.to.toLowerCase()}',
              mimeType: r.report.to == 'TSV' ? 'text/tab-separated-values' : 'text/csv',
              stale: s.fromJsonSource != v.text,
              onUse: r.output == null
                  ? null
                  : () => useAsEditorText(context, ref, docKey: kCsvDocKey, editor: _input, text: r.output!),
            ),
          ),
        ],
      ],
    );
  }
}

/// Virtualised table: sticky header, horizontal scroll, lazily built rows.
class _TableView extends StatelessWidget {
  const _TableView({
    required this.table,
    required this.labels,
    required this.indices,
    required this.controller,
    required this.onJump,
  });

  final CsvTable table;
  final List<String> labels;
  final List<int> indices;
  final ScrollController controller;
  final void Function(int line, int column) onJump;

  static const double _numberWidth = 64;

  List<double> _widths() {
    final sample = [labels, for (final i in indices.take(60)) table.rows[i]];
    return [
      for (var c = 0; c < labels.length; c++)
        (sample.fold<int>(0, (m, r) => c < r.length && r[c].length > m ? r[c].length : m) * 8.0 + 28).clamp(
          72.0,
          320.0,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final scaler = MediaQuery.textScalerOf(context);
    final extent = math.max(36.0, scaler.scale(12 * 1.4) + 16);
    final widths = _widths();
    final total = _numberWidth + widths.fold<double>(0, (a, b) => a + b);

    Widget cell(String text, double width, {TextStyle? style, bool missing = false}) => Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: J3Space.sm),
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: J3Colors.border)),
      ),
      child: Text(
        missing ? '(missing)' : text.replaceAll('\n', r'\n').replaceAll('\r', r'\r'),
        style: missing ? J3Type.codeSmall.copyWith(color: J3Colors.textDisabled) : (style ?? J3Type.codeSmall),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );

    return Container(
      height: 480,
      decoration: BoxDecoration(
        color: J3Colors.inputFill,
        borderRadius: J3Radius.small,
        border: Border.all(color: J3Colors.border),
      ),
      child: InkLayer(
        child: LayoutBuilder(
          builder: (context, c) => Scrollbar(
            controller: controller,
            child: SingleChildScrollView(
              controller: controller,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: math.max(total, c.maxWidth),
                child: Column(
                  children: [
                    Container(
                      height: extent,
                      color: J3Colors.surfaceRaised,
                      child: Row(
                        children: [
                          cell('#', _numberWidth, style: J3Type.codeSmall.copyWith(color: J3Colors.textMuted)),
                          for (var i = 0; i < labels.length; i++)
                            Tooltip(
                              message: labels[i],
                              child: cell(labels[i], widths[i], style: J3Type.label.copyWith(color: fx.accentText)),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: indices.isEmpty
                          ? const Center(child: Text('No rows'))
                          : ListView.builder(
                              itemCount: indices.length,
                              itemExtent: extent,
                              itemBuilder: (context, i) {
                                final r = indices[i];
                                final row = table.rows[r];
                                return InkWell(
                                  onDoubleTap: () => onJump(table.rowLines[r], 1),
                                  child: Container(
                                    color: i.isOdd ? J3Colors.surface.withValues(alpha: 0.5) : null,
                                    child: Row(
                                      children: [
                                        Tooltip(
                                          message:
                                              'Record ${r + 1}, line ${table.rowLines[r]} (double-tap to show in editor)',
                                          child: cell(
                                            '${table.rowLines[r]}',
                                            _numberWidth,
                                            style: J3Type.codeSmall.copyWith(color: J3Colors.textMuted),
                                          ),
                                        ),
                                        for (var col = 0; col < labels.length; col++)
                                          cell(
                                            col < row.length ? row[col] : '',
                                            widths[col],
                                            missing: col >= row.length,
                                            style: J3Type.codeSmall.copyWith(color: J3Colors.text),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
