import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/drafts/drafts.dart';
import '../../domain/conversion_report.dart';
import '../../domain/csv_codec.dart';
import '../../domain/json_tools.dart';
import '../widgets/conversion_panes.dart';

const String kCsvToolId = 'config.csv';
const String kCsvDocKey = 'config.csv/doc';
const String kCsvInputKey = 'config.csv/input';
const String kCsvFromJsonKey = 'config.csv/fromJson';

/// Parsed table plus the delimiter actually used.
class CsvAnalysis {
  const CsvAnalysis({required this.table, required this.stats, required this.delimiter, required this.detected});
  final CsvTable table;
  final CsvStats stats;
  final String delimiter;

  /// The delimiter was auto-detected (not chosen manually).
  final bool detected;
}

/// Top-level so it can run in `Isolate.run`.
CsvAnalysis analyzeCsv(String text, String? delimiter, String quote) {
  final d = delimiter ?? detectDelimiter(text, quote: quote).char;
  final t = parseCsv(text, delimiter: d, quote: quote);
  return CsvAnalysis(table: t, stats: computeCsvStats(t), delimiter: d, detected: delimiter == null);
}

/// Record indices matching [query] (in [column], or any column when -1).
List<int>? filterRows(CsvTable t, {required String query, required int column, required int firstDataRow}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return null;
  final out = <int>[];
  for (var r = firstDataRow; r < t.rows.length; r++) {
    final row = t.rows[r];
    if (column >= 0) {
      if (column < row.length && row[column].toLowerCase().contains(q)) out.add(r);
    } else if (row.any((c) => c.toLowerCase().contains(q))) {
      out.add(r);
    }
  }
  return out;
}

enum CsvTarget { swap, json }

class CsvLabState {
  const CsvLabState({
    this.analysis,
    this.analyzedKey,
    this.stale = false,
    this.analyzing = false,
    this.delimiter,
    this.quote = '"',
    this.header = true,
    this.filterQuery = '',
    this.filterColumn = -1,
    this.filtered,
    this.target = CsvTarget.json,
    this.shape = CsvJsonShape.objects,
    this.infer = false,
    this.indent = JsonIndent.two,
    this.converted,
    this.convertedKey,
    this.fromJsonDelimiter = CsvDelimiter.comma,
    this.flatten = false,
    this.fromJson,
    this.fromJsonSource,
    this.converting = false,
  });

  final CsvAnalysis? analysis;

  /// Text + options the analysis belongs to.
  final String? analyzedKey;
  final bool stale;
  final bool analyzing;

  /// Manual delimiter, or null for auto-detect.
  final CsvDelimiter? delimiter;
  final String quote;
  final bool header;
  final String filterQuery;
  final int filterColumn;
  final List<int>? filtered;
  final CsvTarget target;
  final CsvJsonShape shape;
  final bool infer;
  final JsonIndent indent;
  final ConversionResult? converted;
  final String? convertedKey;
  final CsvDelimiter fromJsonDelimiter;
  final bool flatten;
  final ConversionResult? fromJson;
  final String? fromJsonSource;
  final bool converting;

  bool get usable => !stale && !analyzing && analysis != null;
  int get firstDataRow => header ? 1 : 0;

  CsvLabState copyWith({
    CsvAnalysis? analysis,
    String? analyzedKey,
    bool? stale,
    bool? analyzing,
    CsvDelimiter? delimiter,
    bool autoDelimiter = false,
    String? quote,
    bool? header,
    String? filterQuery,
    int? filterColumn,
    List<int>? filtered,
    bool clearFiltered = false,
    CsvTarget? target,
    CsvJsonShape? shape,
    bool? infer,
    JsonIndent? indent,
    ConversionResult? converted,
    String? convertedKey,
    CsvDelimiter? fromJsonDelimiter,
    bool? flatten,
    ConversionResult? fromJson,
    String? fromJsonSource,
    bool? converting,
  }) => CsvLabState(
    analysis: analysis ?? this.analysis,
    analyzedKey: analyzedKey ?? this.analyzedKey,
    stale: stale ?? this.stale,
    analyzing: analyzing ?? this.analyzing,
    delimiter: autoDelimiter ? null : (delimiter ?? this.delimiter),
    quote: quote ?? this.quote,
    header: header ?? this.header,
    filterQuery: filterQuery ?? this.filterQuery,
    filterColumn: filterColumn ?? this.filterColumn,
    filtered: clearFiltered ? null : (filtered ?? this.filtered),
    target: target ?? this.target,
    shape: shape ?? this.shape,
    infer: infer ?? this.infer,
    indent: indent ?? this.indent,
    converted: converted ?? this.converted,
    convertedKey: convertedKey ?? this.convertedKey,
    fromJsonDelimiter: fromJsonDelimiter ?? this.fromJsonDelimiter,
    flatten: flatten ?? this.flatten,
    fromJson: fromJson ?? this.fromJson,
    fromJsonSource: fromJsonSource ?? this.fromJsonSource,
    converting: converting ?? this.converting,
  );
}

class CsvLabController extends Notifier<CsvLabState> {
  @override
  CsvLabState build() => const CsvLabState();

  TextEditingController get input => ref.read(draftTextProvider(kCsvInputKey));

  String _key(String text) => '${state.delimiter?.char ?? 'auto'}\u0001${state.quote}\u0001$text';

  void _setAnalysis(CsvAnalysis a, String key) {
    state = state.copyWith(analysis: a, analyzedKey: key, stale: false, analyzing: false);
    _refilter();
  }

  void textChanged(String text) {
    final key = _key(text);
    if (key == state.analyzedKey) {
      if (state.stale) state = state.copyWith(stale: false);
      return;
    }
    if (text.length <= kSyncParseLimit) {
      _setAnalysis(analyzeCsv(text, state.delimiter?.char, state.quote), key);
    } else if (!state.stale) {
      state = state.copyWith(stale: true);
    }
  }

  Future<CsvAnalysis> analyze() async {
    final text = input.text;
    final key = _key(text);
    final d = state.delimiter?.char;
    final q = state.quote;
    if (text.length <= kSyncParseLimit) {
      final a = analyzeCsv(text, d, q);
      _setAnalysis(a, key);
      return a;
    }
    state = state.copyWith(analyzing: true);
    final a = await Isolate.run(() => analyzeCsv(text, d, q));
    if (ref.mounted) {
      if (_key(input.text) == key) {
        _setAnalysis(a, key);
      } else {
        state = state.copyWith(analyzing: false, stale: true);
      }
    }
    return a;
  }

  void setDelimiter(CsvDelimiter? d) {
    state = d == null ? state.copyWith(autoDelimiter: true) : state.copyWith(delimiter: d);
    _reanalyze();
  }

  void setQuote(String q) {
    state = state.copyWith(quote: q);
    _reanalyze();
  }

  void _reanalyze() {
    if (input.text.length <= kSyncParseLimit) {
      textChanged(input.text);
    } else {
      state = state.copyWith(stale: true);
    }
  }

  void setHeader(bool v) {
    state = state.copyWith(header: v);
    _refilter();
  }

  void setFilter({String? query, int? column}) {
    state = state.copyWith(filterQuery: query, filterColumn: column);
    _refilter();
  }

  void _refilter() {
    final a = state.analysis;
    if (a == null) return;
    final f = filterRows(
      a.table,
      query: state.filterQuery,
      column: state.filterColumn,
      firstDataRow: state.firstDataRow,
    );
    state = f == null ? state.copyWith(clearFiltered: true) : state.copyWith(filtered: f);
  }

  void setTarget(CsvTarget t) => state = state.copyWith(target: t);
  void setShape(CsvJsonShape s) => state = state.copyWith(shape: s);
  void setInfer(bool v) => state = state.copyWith(infer: v);
  void setIndent(JsonIndent i) => state = state.copyWith(indent: i);
  void setFromJsonDelimiter(CsvDelimiter d) => state = state.copyWith(fromJsonDelimiter: d);
  void setFlatten(bool v) => state = state.copyWith(flatten: v);

  Future<ConversionResult> convert() async {
    final text = input.text;
    final key = _key(text);
    final delimiter = state.analysis?.delimiter ?? state.delimiter?.char ?? detectDelimiter(text).char;
    final quote = state.quote;
    final target = state.target;
    final shape = state.shape;
    final infer = state.infer;
    final indent = state.indent;
    final header = state.header;
    final toDelimiter = delimiter == '\t' ? ',' : '\t';
    final fromLabel = delimiter == '\t' ? 'TSV' : 'CSV';
    state = state.copyWith(converting: true);
    try {
      final r = await runConversion(
        ref,
        toolId: kCsvToolId,
        title: target == CsvTarget.json ? '$fromLabel -> JSON' : '$fromLabel -> ${toDelimiter == '\t' ? 'TSV' : 'CSV'}',
        inputLength: text.length,
        compute: () {
          final t = parseCsv(text, delimiter: delimiter, quote: quote);
          return target == CsvTarget.json
              ? csvToJson(t, header: header, shape: shape, infer: infer, indent: indent, fromLabel: fromLabel)
              : convertDelimited(t, fromDelimiter: delimiter, toDelimiter: toDelimiter, quote: quote);
        },
      );
      if (ref.mounted) state = state.copyWith(converted: r, convertedKey: key, converting: false);
      return r;
    } catch (_) {
      if (ref.mounted) state = state.copyWith(converting: false);
      rethrow;
    }
  }

  Future<ConversionResult> convertFromJson(String json) async {
    final d = state.fromJsonDelimiter.char;
    final q = state.quote;
    final flatten = state.flatten;
    state = state.copyWith(converting: true);
    try {
      final r = await runConversion(
        ref,
        toolId: kCsvToolId,
        title: 'JSON -> ${d == '\t' ? 'TSV' : 'CSV'}',
        inputLength: json.length,
        compute: () => jsonToCsv(json, delimiter: d, quote: q, flatten: flatten),
      );
      if (ref.mounted) state = state.copyWith(fromJson: r, fromJsonSource: json, converting: false);
      return r;
    } catch (_) {
      if (ref.mounted) state = state.copyWith(converting: false);
      rethrow;
    }
  }
}

final csvLabProvider = NotifierProvider<CsvLabController, CsvLabState>(CsvLabController.new);
