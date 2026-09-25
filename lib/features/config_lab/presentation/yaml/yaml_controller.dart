import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/drafts/drafts.dart';
import '../../domain/conversion_report.dart';
import '../../domain/json_tools.dart';
import '../../domain/yaml_codec.dart';
import '../widgets/conversion_panes.dart';

const String kYamlToolId = 'config.yaml';
const String kYamlDocKey = 'config.yaml/doc';
const String kYamlInputKey = 'config.yaml/input';
const String kYamlFromJsonKey = 'config.yaml/fromJson';

class YamlLabState {
  const YamlLabState({
    this.check,
    this.analyzedText,
    this.stale = false,
    this.analyzing = false,
    this.docIndex = 0,
    this.expanded = const {''},
    this.multiDoc = YamlMultiDoc.array,
    this.indent = JsonIndent.two,
    this.toJson,
    this.toJsonSource,
    this.fromJson,
    this.fromJsonSource,
    this.converting = false,
  });

  final YamlCheck? check;
  final String? analyzedText;
  final bool stale;
  final bool analyzing;
  final int docIndex;
  final Set<String> expanded;
  final YamlMultiDoc multiDoc;
  final JsonIndent indent;
  final ConversionResult? toJson;

  /// YAML text the [toJson] result was produced from.
  final String? toJsonSource;
  final ConversionResult? fromJson;
  final String? fromJsonSource;
  final bool converting;

  bool get usable => !stale && !analyzing && (check?.valid ?? false);

  YamlLabState copyWith({
    YamlCheck? check,
    String? analyzedText,
    bool? stale,
    bool? analyzing,
    int? docIndex,
    Set<String>? expanded,
    YamlMultiDoc? multiDoc,
    JsonIndent? indent,
    ConversionResult? toJson,
    String? toJsonSource,
    ConversionResult? fromJson,
    String? fromJsonSource,
    bool? converting,
  }) => YamlLabState(
    check: check ?? this.check,
    analyzedText: analyzedText ?? this.analyzedText,
    stale: stale ?? this.stale,
    analyzing: analyzing ?? this.analyzing,
    docIndex: docIndex ?? this.docIndex,
    expanded: expanded ?? this.expanded,
    multiDoc: multiDoc ?? this.multiDoc,
    indent: indent ?? this.indent,
    toJson: toJson ?? this.toJson,
    toJsonSource: toJsonSource ?? this.toJsonSource,
    fromJson: fromJson ?? this.fromJson,
    fromJsonSource: fromJsonSource ?? this.fromJsonSource,
    converting: converting ?? this.converting,
  );
}

class YamlLabController extends Notifier<YamlLabState> {
  @override
  YamlLabState build() => const YamlLabState();

  TextEditingController get input => ref.read(draftTextProvider(kYamlInputKey));

  void textChanged(String text) {
    if (text == state.analyzedText) {
      if (state.stale) state = state.copyWith(stale: false);
      return;
    }
    if (text.length <= kSyncParseLimit) {
      final c = checkYaml(text);
      state = state.copyWith(
        check: c,
        analyzedText: text,
        stale: false,
        docIndex: state.docIndex < c.documents.length ? state.docIndex : 0,
      );
    } else if (!state.stale) {
      state = state.copyWith(stale: true);
    }
  }

  Future<YamlCheck> validate() async {
    final text = input.text;
    if (text.length <= kSyncParseLimit) {
      final c = checkYaml(text);
      state = state.copyWith(
        check: c,
        analyzedText: text,
        stale: false,
        docIndex: state.docIndex < c.documents.length ? state.docIndex : 0,
      );
      return c;
    }
    state = state.copyWith(analyzing: true);
    final c = await Isolate.run(() => checkYaml(text));
    if (ref.mounted) {
      state = state.copyWith(check: c, analyzedText: text, stale: input.text != text, analyzing: false, docIndex: 0);
    }
    return c;
  }

  void setDoc(int i) => state = state.copyWith(docIndex: i, expanded: const {''});
  void setMultiDoc(YamlMultiDoc m) => state = state.copyWith(multiDoc: m);
  void setIndent(JsonIndent i) => state = state.copyWith(indent: i);

  void toggle(String pointer) {
    final next = {...state.expanded};
    if (!next.remove(pointer)) next.add(pointer);
    state = state.copyWith(expanded: next);
  }

  Future<ConversionResult> convertToJson() async {
    final text = input.text;
    final multi = state.multiDoc;
    final indent = state.indent;
    state = state.copyWith(converting: true);
    try {
      final r = await runConversion(
        ref,
        toolId: kYamlToolId,
        title: 'YAML -> JSON',
        inputLength: text.length,
        compute: () => yamlToJson(text, multiDoc: multi, indent: indent),
      );
      if (ref.mounted) state = state.copyWith(toJson: r, toJsonSource: text, converting: false);
      return r;
    } catch (_) {
      if (ref.mounted) state = state.copyWith(converting: false);
      rethrow;
    }
  }

  Future<ConversionResult> convertFromJson(String json) async {
    state = state.copyWith(converting: true);
    try {
      final r = await runConversion(
        ref,
        toolId: kYamlToolId,
        title: 'JSON -> YAML',
        inputLength: json.length,
        compute: () => jsonToYaml(json),
      );
      if (ref.mounted) state = state.copyWith(fromJson: r, fromJsonSource: json, converting: false);
      return r;
    } catch (_) {
      if (ref.mounted) state = state.copyWith(converting: false);
      rethrow;
    }
  }
}

final yamlLabProvider = NotifierProvider<YamlLabController, YamlLabState>(YamlLabController.new);
