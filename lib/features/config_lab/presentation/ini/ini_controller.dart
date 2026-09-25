import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/drafts/drafts.dart';
import '../../domain/conversion_report.dart';
import '../../domain/ini_document.dart';
import '../../domain/json_tools.dart';
import '../widgets/conversion_panes.dart';

const String kIniToolId = 'config.ini';
const String kIniDocKey = 'config.ini/doc';
const String kIniInputKey = 'config.ini/input';
const String kIniFromJsonKey = 'config.ini/fromJson';
const String kIniFilterKey = 'config.ini/filter';

class IniLabState {
  const IniLabState({
    this.doc,
    this.analyzedText,
    this.stale = false,
    this.analyzing = false,
    this.inferTypes = false,
    this.indent = JsonIndent.two,
    this.toJson,
    this.toJsonSource,
    this.fromJson,
    this.fromJsonSource,
    this.converting = false,
  });

  final IniDocument? doc;
  final String? analyzedText;
  final bool stale;
  final bool analyzing;
  final bool inferTypes;
  final JsonIndent indent;
  final ConversionResult? toJson;
  final String? toJsonSource;
  final ConversionResult? fromJson;
  final String? fromJsonSource;
  final bool converting;

  bool get usable => !stale && !analyzing && doc != null;

  IniLabState copyWith({
    IniDocument? doc,
    String? analyzedText,
    bool? stale,
    bool? analyzing,
    bool? inferTypes,
    JsonIndent? indent,
    ConversionResult? toJson,
    String? toJsonSource,
    ConversionResult? fromJson,
    String? fromJsonSource,
    bool? converting,
  }) => IniLabState(
    doc: doc ?? this.doc,
    analyzedText: analyzedText ?? this.analyzedText,
    stale: stale ?? this.stale,
    analyzing: analyzing ?? this.analyzing,
    inferTypes: inferTypes ?? this.inferTypes,
    indent: indent ?? this.indent,
    toJson: toJson ?? this.toJson,
    toJsonSource: toJsonSource ?? this.toJsonSource,
    fromJson: fromJson ?? this.fromJson,
    fromJsonSource: fromJsonSource ?? this.fromJsonSource,
    converting: converting ?? this.converting,
  );
}

class IniLabController extends Notifier<IniLabState> {
  @override
  IniLabState build() => const IniLabState();

  TextEditingController get input => ref.read(draftTextProvider(kIniInputKey));

  void textChanged(String text) {
    if (text == state.analyzedText) {
      if (state.stale) state = state.copyWith(stale: false);
      return;
    }
    if (text.length <= kSyncParseLimit) {
      state = state.copyWith(doc: IniDocument.parse(text), analyzedText: text, stale: false);
    } else if (!state.stale) {
      state = state.copyWith(stale: true);
    }
  }

  Future<IniDocument> validate() async {
    final text = input.text;
    if (text.length <= kSyncParseLimit) {
      final d = IniDocument.parse(text);
      state = state.copyWith(doc: d, analyzedText: text, stale: false);
      return d;
    }
    state = state.copyWith(analyzing: true);
    final d = await Isolate.run(() => IniDocument.parse(text));
    if (ref.mounted) state = state.copyWith(doc: d, analyzedText: text, stale: input.text != text, analyzing: false);
    return d;
  }

  void setInferTypes(bool v) => state = state.copyWith(inferTypes: v);
  void setIndent(JsonIndent i) => state = state.copyWith(indent: i);

  /// Applies a lossless edit; only the affected line(s) change in the text.
  void _apply(IniDocument next, int caretLine) {
    final text = next.toText();
    var offset = 0;
    for (var i = 0; i < caretLine && i < next.lines.length; i++) {
      offset += next.lines[i].raw.length + next.lines[i].eol.length;
    }
    input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset.clamp(0, text.length)),
    );
    state = state.copyWith(doc: next, analyzedText: text, stale: false);
  }

  /// Throws [IniEditError] when the value cannot be written.
  void editValue(int lineIndex, String value) => _apply(state.doc!.setValue(lineIndex, value), lineIndex);

  void addEntry(String section, String key, String value) {
    final next = state.doc!.addEntry(section, key, value);
    final line = next.entries.lastWhere((e) => e.section == section && e.key == key).index;
    _apply(next, line);
  }

  void removeEntry(int lineIndex) => _apply(state.doc!.removeEntry(lineIndex), lineIndex);

  void addSection(String name) {
    final next = state.doc!.addSection(name);
    _apply(next, next.lines.length - 1);
  }

  Future<ConversionResult> convertToJson() async {
    final text = input.text;
    final infer = state.inferTypes;
    final indent = state.indent;
    state = state.copyWith(converting: true);
    try {
      final r = await runConversion(
        ref,
        toolId: kIniToolId,
        title: 'INI -> JSON',
        inputLength: text.length,
        compute: () => iniToJson(IniDocument.parse(text), inferTypes: infer, indent: indent),
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
        toolId: kIniToolId,
        title: 'JSON -> INI',
        inputLength: json.length,
        compute: () => jsonToIni(json),
      );
      if (ref.mounted) state = state.copyWith(fromJson: r, fromJsonSource: json, converting: false);
      return r;
    } catch (_) {
      if (ref.mounted) state = state.copyWith(converting: false);
      rethrow;
    }
  }
}

final iniLabProvider = NotifierProvider<IniLabController, IniLabState>(IniLabController.new);
