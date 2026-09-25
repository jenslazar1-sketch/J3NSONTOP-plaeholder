import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../domain/compare.dart';
import '../../domain/config_format.dart';
import '../../domain/json_tools.dart' show kSyncParseLimit;

const String kCompareToolId = 'config.compare';
const String kCompareAKey = 'config.compare/a';
const String kCompareBKey = 'config.compare/b';

enum DiffView { unified, sideBySide }

class CompareState {
  const CompareState({
    this.formatA,
    this.formatB,
    this.nameA = 'A',
    this.nameB = 'B',
    this.ignoreWhitespace = false,
    this.view = DiffView.unified,
    this.result,
    this.resultNameA = 'A',
    this.resultNameB = 'B',
    this.comparedA,
    this.comparedB,
    this.busy = false,
  });

  /// Manual formats (null = auto-detect).
  final ConfigFormat? formatA;
  final ConfigFormat? formatB;
  final String nameA;
  final String nameB;
  final bool ignoreWhitespace;
  final DiffView view;
  final CompareResult? result;
  final String resultNameA;
  final String resultNameB;
  final String? comparedA;
  final String? comparedB;
  final bool busy;

  CompareState copyWith({
    ConfigFormat? formatA,
    bool autoA = false,
    ConfigFormat? formatB,
    bool autoB = false,
    String? nameA,
    String? nameB,
    bool? ignoreWhitespace,
    DiffView? view,
    CompareResult? result,
    String? resultNameA,
    String? resultNameB,
    String? comparedA,
    String? comparedB,
    bool? busy,
  }) => CompareState(
    formatA: autoA ? null : (formatA ?? this.formatA),
    formatB: autoB ? null : (formatB ?? this.formatB),
    nameA: nameA ?? this.nameA,
    nameB: nameB ?? this.nameB,
    ignoreWhitespace: ignoreWhitespace ?? this.ignoreWhitespace,
    view: view ?? this.view,
    result: result ?? this.result,
    resultNameA: resultNameA ?? this.resultNameA,
    resultNameB: resultNameB ?? this.resultNameB,
    comparedA: comparedA ?? this.comparedA,
    comparedB: comparedB ?? this.comparedB,
    busy: busy ?? this.busy,
  );
}

class CompareController extends Notifier<CompareState> {
  @override
  CompareState build() => const CompareState();

  void setFormat(bool sideA, ConfigFormat? f) => state = sideA
      ? (f == null ? state.copyWith(autoA: true) : state.copyWith(formatA: f))
      : (f == null ? state.copyWith(autoB: true) : state.copyWith(formatB: f));

  void setName(bool sideA, String name) => state = sideA ? state.copyWith(nameA: name) : state.copyWith(nameB: name);
  void setIgnoreWhitespace(bool v) => state = state.copyWith(ignoreWhitespace: v);
  void setView(DiffView v) => state = state.copyWith(view: v);

  String? _fileName(bool sideA) {
    final name = sideA ? state.nameA : state.nameB;
    return name == 'A' || name == 'B' ? null : name;
  }

  /// Format used for [text]: the manual choice or the detected one.
  ConfigFormat resolved(bool sideA, String text) =>
      (sideA ? state.formatA : state.formatB) ?? detectConfigFormat(text, fileName: _fileName(sideA));

  /// Swaps both inputs (text, names and formats).
  void swap() {
    final a = ref.read(draftTextProvider(kCompareAKey));
    final b = ref.read(draftTextProvider(kCompareBKey));
    final t = a.text;
    a.text = b.text;
    b.text = t;
    state = CompareState(
      formatA: state.formatB,
      formatB: state.formatA,
      nameA: state.nameB,
      nameB: state.nameA,
      ignoreWhitespace: state.ignoreWhitespace,
      view: state.view,
    );
  }

  Future<CompareResult> compare() async {
    final textA = ref.read(draftTextProvider(kCompareAKey)).text;
    final textB = ref.read(draftTextProvider(kCompareBKey)).text;
    final fa = state.formatA, fb = state.formatB;
    final fileA = _fileName(true), fileB = _fileName(false);
    final ws = state.ignoreWhitespace;
    final na = state.nameA, nb = state.nameB;
    state = state.copyWith(busy: true);
    try {
      final big = textA.length + textB.length > kSyncParseLimit;
      final r = await ref
          .read(activityProvider.notifier)
          .run<CompareResult>(
            toolId: kCompareToolId,
            title: 'Compare $na vs $nb',
            notify: false,
            body: (op) async {
              CompareResult run() => compareConfigs(
                textA,
                textB,
                formatA: fa,
                formatB: fb,
                fileNameA: fileA,
                fileNameB: fileB,
                ignoreWhitespace: ws,
                nameA: na,
                nameB: nb,
              );
              return big ? Isolate.run(run) : run();
            },
            summary: (r) => r.semantic == null
                ? 'Text only: +${r.text.insertions} -${r.text.deletions} lines (a side does not parse)'
                : '${r.semantic!.changes.length} semantic change(s), +${r.text.insertions} -${r.text.deletions} lines',
          );
      if (ref.mounted) {
        state = state.copyWith(
          result: r,
          resultNameA: na,
          resultNameB: nb,
          comparedA: textA,
          comparedB: textB,
          busy: false,
        );
      }
      return r;
    } catch (_) {
      if (ref.mounted) state = state.copyWith(busy: false);
      rethrow;
    }
  }
}

final compareProvider = NotifierProvider<CompareController, CompareState>(CompareController.new);
