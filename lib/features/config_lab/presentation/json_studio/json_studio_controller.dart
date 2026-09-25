import 'dart:async';
import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/tasks/isolate_runner.dart';
import '../../../../core/utils/format.dart';
import '../../domain/field_search.dart';
import '../../domain/json_tools.dart';
import '../../domain/json_value.dart';
import '../widgets/value_tree.dart';

const String kJsonToolId = 'config.json';
const String kJsonDocKey = 'config.json/doc';
const String kJsonInputKey = 'config.json/input';
const String kJsonSearchKey = 'config.json/search';

class JsonStudioState {
  const JsonStudioState({
    this.analysis,
    this.analyzedText,
    this.analyzing = false,
    this.stale = false,
    this.indent = JsonIndent.two,
    this.ensureAscii = false,
    this.expanded = const {''},
    this.undoText,
    this.undoLabel,
    this.selectedPointer,
    this.revealToken = 0,
    this.search,
    this.searchError,
    this.searching = false,
    this.scope = SearchScope.both,
    this.regex = false,
    this.caseSensitive = false,
  });

  final JsonAnalysis? analysis;
  final String? analyzedText;
  final bool analyzing;

  /// The text changed after the last analysis (large documents only).
  final bool stale;
  final JsonIndent indent;
  final bool ensureAscii;
  final Set<String> expanded;
  final String? undoText;
  final String? undoLabel;
  final String? selectedPointer;
  final int revealToken;
  final FieldSearchResult? search;
  final String? searchError;
  final bool searching;
  final SearchScope scope;
  final bool regex;
  final bool caseSensitive;

  bool get usable => !stale && !analyzing && (analysis?.valid ?? false);

  JsonStudioState copyWith({
    JsonAnalysis? analysis,
    String? analyzedText,
    bool? analyzing,
    bool? stale,
    JsonIndent? indent,
    bool? ensureAscii,
    Set<String>? expanded,
    String? undoText,
    String? undoLabel,
    bool clearUndo = false,
    String? selectedPointer,
    int? revealToken,
    FieldSearchResult? search,
    String? searchError,
    bool clearSearch = false,
    bool? searching,
    SearchScope? scope,
    bool? regex,
    bool? caseSensitive,
  }) => JsonStudioState(
    analysis: analysis ?? this.analysis,
    analyzedText: analyzedText ?? this.analyzedText,
    analyzing: analyzing ?? this.analyzing,
    stale: stale ?? this.stale,
    indent: indent ?? this.indent,
    ensureAscii: ensureAscii ?? this.ensureAscii,
    expanded: expanded ?? this.expanded,
    undoText: clearUndo ? null : (undoText ?? this.undoText),
    undoLabel: clearUndo ? null : (undoLabel ?? this.undoLabel),
    selectedPointer: selectedPointer ?? this.selectedPointer,
    revealToken: revealToken ?? this.revealToken,
    search: clearSearch ? null : (search ?? this.search),
    searchError: clearSearch ? null : (searchError ?? this.searchError),
    searching: searching ?? this.searching,
    scope: scope ?? this.scope,
    regex: regex ?? this.regex,
    caseSensitive: caseSensitive ?? this.caseSensitive,
  );
}

class JsonStudioController extends Notifier<JsonStudioState> {
  @override
  JsonStudioState build() => const JsonStudioState();

  TextEditingController get input => ref.read(draftTextProvider(kJsonInputKey));

  /// Called for every edit. Small documents are validated immediately;
  /// large ones are marked stale until [validate] runs off the UI thread.
  void textChanged(String text) {
    if (text == state.analyzedText) {
      if (state.stale) state = state.copyWith(stale: false);
      return;
    }
    if (text.length <= kSyncParseLimit) {
      state = state.copyWith(analysis: analyzeJson(text), analyzedText: text, stale: false, analyzing: false);
    } else if (!state.stale) {
      state = state.copyWith(stale: true);
    }
  }

  /// Validates the current text (in an isolate for large documents).
  Future<JsonAnalysis> validate() async {
    final text = input.text;
    if (text.length <= kSyncParseLimit) {
      final a = analyzeJson(text);
      state = state.copyWith(analysis: a, analyzedText: text, stale: false);
      return a;
    }
    state = state.copyWith(analyzing: true);
    try {
      final a = await ref
          .read(activityProvider.notifier)
          .run<JsonAnalysis>(
            toolId: kJsonToolId,
            title: 'Validate JSON (${Fmt.bytes(text.length)})',
            notify: false,
            body: (op) => Isolate.run(() => analyzeJson(text)),
            summary: (a) => a.valid ? 'Valid JSON' : 'Invalid JSON: ${a.error?.describe()}',
          );
      if (!ref.mounted) return a;
      if (input.text == text) {
        state = state.copyWith(analysis: a, analyzedText: text, stale: false, analyzing: false);
      } else {
        state = state.copyWith(analyzing: false);
      }
      return a;
    } catch (_) {
      if (ref.mounted) state = state.copyWith(analyzing: false);
      rethrow;
    }
  }

  void setIndent(JsonIndent indent) => state = state.copyWith(indent: indent);
  void setEnsureAscii(bool v) => state = state.copyWith(ensureAscii: v);

  void _replaceText(String next, String label) {
    final before = input.text;
    if (next == before) return;
    state = state.copyWith(undoText: before, undoLabel: label);
    input.value = TextEditingValue(text: next, selection: const TextSelection.collapsed(offset: 0));
    textChanged(next);
    if (next.length > kSyncParseLimit) unawaited(_validateQuietly());
  }

  /// Validation whose failure is already recorded by the activity log.
  Future<void> _validateQuietly() async {
    try {
      await validate();
    } catch (_) {
      // Recorded as a failed operation.
    }
  }

  Future<String> _encode(Object? value, {JsonIndent? indent}) async {
    final ascii = state.ensureAscii;
    if (input.text.length <= kSyncParseLimit) return encodeJson(value, indent: indent, ensureAscii: ascii);
    return Isolate.run(() => encodeJson(value, indent: indent, ensureAscii: ascii));
  }

  /// Re-serialises with the chosen indent. Returns false when the text is
  /// not valid JSON (the error is shown by the page).
  Future<bool> format() async {
    if (!state.usable) return false;
    _replaceText(await _encode(state.analysis!.value, indent: state.indent), 'Format');
    return true;
  }

  Future<bool> minify() async {
    if (!state.usable) return false;
    _replaceText(await _encode(state.analysis!.value, indent: null), 'Minify');
    return true;
  }

  Future<bool> sortKeys() async {
    if (!state.usable) return false;
    final sorted = sortKeysDeep(state.analysis!.value);
    _replaceText(await _encode(sorted, indent: state.indent), 'Sort keys');
    return true;
  }

  void undo() {
    final text = state.undoText;
    if (text == null) return;
    state = state.copyWith(clearUndo: true);
    input.value = TextEditingValue(text: text, selection: const TextSelection.collapsed(offset: 0));
    textChanged(text);
    if (text.length > kSyncParseLimit) unawaited(_validateQuietly());
  }

  /// Applies a tree edit: the new root is re-serialised with the indent.
  Future<void> applyTreeEdit(Object? newRoot, String label) async {
    _replaceText(await _encode(newRoot, indent: state.indent), label);
  }

  void toggle(String pointer) {
    final next = {...state.expanded};
    if (!next.remove(pointer)) next.add(pointer);
    state = state.copyWith(expanded: next);
  }

  /// Expands everything (returns false when the document is too large).
  bool expandAll() {
    final all = allContainerPointers(state.analysis?.value);
    if (all == null) return false;
    state = state.copyWith(expanded: all);
    return true;
  }

  void collapseAll() => state = state.copyWith(expanded: const {''});

  void reveal(List<Object> path) {
    state = state.copyWith(
      expanded: {...state.expanded, ...ancestorPointers(path)},
      selectedPointer: formatJsonPointer(path),
      revealToken: state.revealToken + 1,
    );
  }

  void setSearchOptions({SearchScope? scope, bool? regex, bool? caseSensitive}) =>
      state = state.copyWith(scope: scope, regex: regex, caseSensitive: caseSensitive);

  /// Field search. Regex searches (and large documents) run in a bounded
  /// isolate so a pathological pattern cannot freeze the app.
  Future<void> search(String pattern) async {
    final value = state.analysis?.value;
    if (!state.usable || pattern.isEmpty) {
      state = state.copyWith(clearSearch: true);
      return;
    }
    final q = FieldSearchQuery(
      pattern: pattern,
      scope: state.scope,
      regex: state.regex,
      caseSensitive: state.caseSensitive,
    );
    if (!q.regex && input.text.length <= kSyncParseLimit) {
      try {
        final r = searchJson(value, q);
        state = state.copyWith(clearSearch: true);
        state = state.copyWith(search: r, searching: false);
      } on FormatException catch (e) {
        state = state.copyWith(clearSearch: true);
        state = state.copyWith(searchError: e.message);
      }
      return;
    }
    state = state.copyWith(searching: true, clearSearch: true);
    try {
      final r = await runBounded(() => searchJson(value, q), timeout: const Duration(seconds: 3));
      if (ref.mounted) state = state.copyWith(search: r, searching: false);
    } on OperationTimedOut catch (e) {
      if (ref.mounted) state = state.copyWith(searching: false, searchError: 'Search stopped: $e');
    } catch (e) {
      if (ref.mounted) {
        final msg = '$e'.replaceFirst('FormatException: ', '');
        state = state.copyWith(searching: false, searchError: 'Invalid pattern: $msg');
      }
    }
  }
}

final jsonStudioProvider = NotifierProvider<JsonStudioController, JsonStudioState>(JsonStudioController.new);
