import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/drafts/drafts.dart';
import '../../domain/conversion_report.dart';
import '../../domain/json_tools.dart';
import '../../domain/toml_codec.dart';
import '../widgets/conversion_panes.dart';

const String kTomlToolId = 'config.toml';
const String kTomlDocKey = 'config.toml/doc';
const String kTomlInputKey = 'config.toml/input';
const String kTomlFromJsonKey = 'config.toml/fromJson';

class TomlLabState {
  const TomlLabState({
    this.check,
    this.analyzedText,
    this.stale = false,
    this.analyzing = false,
    this.expanded = const {''},
    this.indent = JsonIndent.two,
    this.dropNulls = false,
    this.toJson,
    this.toJsonSource,
    this.fromJson,
    this.fromJsonSource,
    this.converting = false,
  });

  final TomlCheck? check;
  final String? analyzedText;
  final bool stale;
  final bool analyzing;
  final Set<String> expanded;
  final JsonIndent indent;
  final bool dropNulls;
  final ConversionResult? toJson;
  final String? toJsonSource;
  final ConversionResult? fromJson;
  final String? fromJsonSource;
  final bool converting;

  bool get usable => !stale && !analyzing && (check?.valid ?? false);

  TomlLabState copyWith({
    TomlCheck? check,
    String? analyzedText,
    bool? stale,
    bool? analyzing,
    Set<String>? expanded,
    JsonIndent? indent,
    bool? dropNulls,
    ConversionResult? toJson,
    String? toJsonSource,
    ConversionResult? fromJson,
    String? fromJsonSource,
    bool? converting,
  }) => TomlLabState(
    check: check ?? this.check,
    analyzedText: analyzedText ?? this.analyzedText,
    stale: stale ?? this.stale,
    analyzing: analyzing ?? this.analyzing,
    expanded: expanded ?? this.expanded,
    indent: indent ?? this.indent,
    dropNulls: dropNulls ?? this.dropNulls,
    toJson: toJson ?? this.toJson,
    toJsonSource: toJsonSource ?? this.toJsonSource,
    fromJson: fromJson ?? this.fromJson,
    fromJsonSource: fromJsonSource ?? this.fromJsonSource,
    converting: converting ?? this.converting,
  );
}

class TomlLabController extends Notifier<TomlLabState> {
  @override
  TomlLabState build() => const TomlLabState();

  TextEditingController get input => ref.read(draftTextProvider(kTomlInputKey));

  void textChanged(String text) {
    if (text == state.analyzedText) {
      if (state.stale) state = state.copyWith(stale: false);
      return;
    }
    if (text.length <= kSyncParseLimit) {
      state = state.copyWith(check: checkToml(text), analyzedText: text, stale: false);
    } else if (!state.stale) {
      state = state.copyWith(stale: true);
    }
  }

  Future<TomlCheck> validate() async {
    final text = input.text;
    if (text.length <= kSyncParseLimit) {
      final c = checkToml(text);
      state = state.copyWith(check: c, analyzedText: text, stale: false);
      return c;
    }
    state = state.copyWith(analyzing: true);
    final c = await Isolate.run(() => checkToml(text));
    if (ref.mounted) {
      state = state.copyWith(check: c, analyzedText: text, stale: input.text != text, analyzing: false);
    }
    return c;
  }

  void setIndent(JsonIndent i) => state = state.copyWith(indent: i);
  void setDropNulls(bool v) => state = state.copyWith(dropNulls: v);

  void toggle(String pointer) {
    final next = {...state.expanded};
    if (!next.remove(pointer)) next.add(pointer);
    state = state.copyWith(expanded: next);
  }

  Future<ConversionResult> convertToJson() async {
    final text = input.text;
    final indent = state.indent;
    state = state.copyWith(converting: true);
    try {
      final r = await runConversion(
        ref,
        toolId: kTomlToolId,
        title: 'TOML -> JSON',
        inputLength: text.length,
        compute: () => tomlToJson(text, indent: indent),
      );
      if (ref.mounted) state = state.copyWith(toJson: r, toJsonSource: text, converting: false);
      return r;
    } catch (_) {
      if (ref.mounted) state = state.copyWith(converting: false);
      rethrow;
    }
  }

  Future<ConversionResult> convertFromJson(String json) async {
    final drop = state.dropNulls;
    state = state.copyWith(converting: true);
    try {
      final r = await runConversion(
        ref,
        toolId: kTomlToolId,
        title: 'JSON -> TOML',
        inputLength: json.length,
        compute: () => jsonToToml(json, dropNulls: drop),
      );
      if (ref.mounted) state = state.copyWith(fromJson: r, fromJsonSource: json, converting: false);
      return r;
    } catch (_) {
      if (ref.mounted) state = state.copyWith(converting: false);
      rethrow;
    }
  }
}

final tomlLabProvider = NotifierProvider<TomlLabController, TomlLabState>(TomlLabController.new);
