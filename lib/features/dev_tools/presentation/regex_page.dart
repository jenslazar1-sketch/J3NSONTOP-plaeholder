import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/drafts/drafts.dart';
import '../../../core/theme/effects.dart';
import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/regex_tools.dart';
import 'dev_widgets.dart';
import 'regex_controller.dart';

class RegexPage extends ConsumerStatefulWidget {
  const RegexPage({super.key});
  static const id = 'dev.regex';

  /// Visible markers around highlighted matches (not colour-only).
  static const String open = '«';
  static const String close = '»';
  static const String empty = '¦';

  @override
  ConsumerState<RegexPage> createState() => _RegexPageState();
}

class _RegexPageState extends ConsumerState<RegexPage> {
  static const _k = RegexPage.id;
  static const int _highlightLimit = 2000;
  static const int _previewChars = 100000;

  final _debounce = Debouncer(const Duration(milliseconds: 300));
  late final TextEditingController _pattern = ref.read(draftTextProvider('$_k/pattern'));
  late final TextEditingController _text = ref.read(draftTextProvider('$_k/text'));
  late final TextEditingController _replacement = ref.read(draftTextProvider('$_k/replacement'));
  Object? _lastSignature;

  @override
  void initState() {
    super.initState();
    for (final c in [_pattern, _text, _replacement]) {
      c.addListener(_onInputChanged);
    }
    _lastSignature = _signature();
  }

  @override
  void dispose() {
    for (final c in [_pattern, _text, _replacement]) {
      c.removeListener(_onInputChanged);
    }
    _debounce.dispose();
    super.dispose();
  }

  RegexFlags get _flags => ref.read(draftValueProvider('$_k/flags')) as RegexFlags? ?? const RegexFlags();
  bool get _live => ref.read(draftValueProvider('$_k/live')) != false;
  bool get _replaceOn => ref.read(draftValueProvider('$_k/replaceOn')) == true;

  /// Everything that affects the result; caret moves do not change it.
  Object _signature() => (_pattern.text, _text.text, _replacement.text, _flags, _replaceOn);

  void _onInputChanged() {
    final sig = _signature();
    if (sig == _lastSignature) return; // caret/selection only
    _lastSignature = sig;
    if (_live) _debounce(_run);
  }

  void _optionsChanged() {
    _lastSignature = _signature();
    if (_live) _debounce(_run);
  }

  void _run() {
    _debounce.cancel();
    ref
        .read(regexToolProvider.notifier)
        .run(
          RegexJob(
            pattern: _pattern.text,
            flags: _flags,
            input: _text.text,
            replacement: _replaceOn ? _replacement.text : null,
          ),
        );
  }

  void _setFlags(RegexFlags f) {
    ref.setDraft('$_k/flags', f);
    _optionsChanged();
  }

  void _loadExample(RegexExample e) {
    ref.setDraft('$_k/flags', e.flags);
    _pattern.text = e.pattern;
    if (_text.text.trim().isEmpty) _text.text = e.sample;
    _optionsChanged();
    _run();
  }

  @override
  Widget build(BuildContext context) {
    final flags = ref.draft<RegexFlags>('$_k/flags', const RegexFlags());
    final live = ref.draft<bool>('$_k/live', true);
    final replaceOn = ref.draft<bool>('$_k/replaceOn', false);
    final state = ref.watch(regexToolProvider);

    Widget flagChip(String letter, String label, String tip, bool value, RegexFlags Function(bool) next) => Tooltip(
      message: tip,
      child: FilterChip(label: Text('$letter  $label'), selected: value, onSelected: (v) => _setFlags(next(v))),
    );

    final inputs = [
      CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): _run},
        child: NeonPanel(
          kicker: 'PATTERN',
          title: 'Regular expression',
          icon: Icons.pattern,
          actions: [
            PopupMenuButton<RegexExample>(
              tooltip: 'Example patterns',
              icon: const Icon(Icons.library_books_outlined, size: 20),
              onSelected: _loadExample,
              itemBuilder: (context) => [
                for (final e in regexExamples)
                  PopupMenuItem(
                    value: e,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(e.name),
                      subtitle: Text(e.description),
                    ),
                  ),
              ],
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('dev.regex.pattern'),
                controller: _pattern,
                style: J3Type.code,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Pattern',
                  hintText: r'(?<key>\w+)=(\d+)',
                  prefixText: '/ ',
                  suffixText: ' /${flags.letters}',
                ),
              ),
              const SizedBox(height: J3Space.md),
              Wrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                children: [
                  flagChip(
                    'i',
                    'Ignore case',
                    'caseSensitive: false',
                    !flags.caseSensitive,
                    (v) => flags.copyWith(caseSensitive: !v),
                  ),
                  flagChip(
                    'm',
                    'Multi-line',
                    '^ and \$ match at every line',
                    flags.multiLine,
                    (v) => flags.copyWith(multiLine: v),
                  ),
                  flagChip(
                    's',
                    'Dot all',
                    '. also matches line breaks',
                    flags.dotAll,
                    (v) => flags.copyWith(dotAll: v),
                  ),
                  flagChip(
                    'u',
                    'Unicode',
                    r'Unicode mode: \p{...} classes, code-point matching',
                    flags.unicode,
                    (v) => flags.copyWith(unicode: v),
                  ),
                ],
              ),
              const SizedBox(height: J3Space.md),
              CodeField(
                key: const Key('dev.regex.text'),
                controller: _text,
                label: 'Test text',
                hint: 'key=1, other=22',
                minLines: 5,
                maxLines: 14,
              ),
              DevSwitch(
                label: 'Replace preview',
                description: r'$1 or ${1} group, ${name} named group, $& or $0 whole match, $$ literal $',
                value: replaceOn,
                onChanged: (v) {
                  ref.setDraft('$_k/replaceOn', v);
                  _optionsChanged();
                },
              ),
              if (replaceOn)
                TextField(
                  key: const Key('dev.regex.replacement'),
                  controller: _replacement,
                  style: J3Type.code,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Replacement', hintText: r'${key}: $2'),
                ),
              DevSwitch(
                label: 'Live matching',
                description: 'Runs 300 ms after you stop typing. Every run is time-limited (1.5 s).',
                value: live,
                onChanged: (v) {
                  ref.setDraft('$_k/live', v);
                  if (v) _run();
                },
              ),
              const SizedBox(height: J3Space.sm),
              ActionWrap(
                children: [
                  NeonButton(
                    key: const Key('dev.regex.run'),
                    label: 'Run',
                    icon: Icons.play_arrow_rounded,
                    tooltip: 'Run now (Ctrl+Enter)',
                    busy: state.running,
                    onPressed: _run,
                  ),
                  if (state.running)
                    NeonButton.danger(
                      key: const Key('dev.regex.cancel'),
                      label: 'Cancel',
                      icon: Icons.stop_circle_outlined,
                      onPressed: () => ref.read(regexToolProvider.notifier).cancel(),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    ];

    return ToolScaffold(toolId: _k, inputs: inputs, results: _results(state));
  }

  List<Widget> _results(RegexToolState state) {
    final job = state.job;
    final r = state.result;
    final out = <Widget>[];
    if (state.running) {
      out.add(const StatusLine(kind: StatusKind.running, text: 'Running in a background worker (limit 1.5 s)...'));
    }
    if (state.patternError != null) {
      out.add(InputErrorBanner(error: state.patternError!, title: 'Invalid pattern'));
      return out;
    }
    if (state.stopped != null) {
      out.add(
        StatusBanner(
          kind: StatusKind.warning,
          title: state.stopped == RegexToolController.timeLimitMessage ? 'Time limit' : 'Stopped',
          message: state.stopped,
          details: const [
            'Nested quantifiers such as (a+)+ or (.*)* can take exponential time on non-matching input.',
            'Make groups atomic by being more specific, e.g. [^,]* instead of .*',
          ],
        ),
      );
      return out;
    }
    if (job == null || r == null) {
      if (!state.running) {
        out.add(
          const EmptyState(
            title: 'Enter a pattern',
            message: 'Or pick one from the example library (book icon).',
            glyph: '[ /.*/ ]',
          ),
        );
      }
      return out;
    }
    final ms = state.elapsed?.inMilliseconds ?? 0;
    out.add(
      StatusLine(
        kind: r.matches.isEmpty ? StatusKind.neutral : StatusKind.success,
        text: r.matches.isEmpty
            ? 'No match ($ms ms)'
            : '${r.matches.length}${r.capped ? '+ (capped at ${job.maxMatches})' : ''} '
                  'match${r.matches.length == 1 ? '' : 'es'} in $ms ms  |  ${r.groupCount} group'
                  '${r.groupCount == 1 ? '' : 's'}',
      ),
    );
    out.add(_highlighted(job, r));
    if (r.matches.isNotEmpty) {
      out.add(_matchList(r, state.selected));
      out.add(_groups(r, state.selected.clamp(0, r.matches.length - 1)));
    }
    if (job.replacement != null) {
      if (r.replaceError != null) {
        out.add(InputErrorBanner(error: r.replaceError!, title: 'Invalid replacement', controller: _replacement));
      } else if (r.replaced != null) {
        out.add(
          CappedTextResult(
            text: r.replaced!,
            kicker: 'REPLACE',
            title: 'Replace preview',
            fileName: 'replaced.txt',
            toolId: _k,
          ),
        );
      }
    }
    return out;
  }

  Widget _highlighted(RegexJob job, RegexRunResult r) {
    final fx = context.effects;
    final text = job.input;
    final limit = text.length > _previewChars ? _previewChars : text.length;
    final markStyle = J3Type.code.copyWith(color: fx.accentText, fontWeight: FontWeight.w700);
    final hitStyle = J3Type.code.copyWith(
      backgroundColor: fx.accentColor.withValues(alpha: 0.28),
      decoration: TextDecoration.underline,
      decorationColor: fx.accentColor,
    );
    final spans = <InlineSpan>[];
    var pos = 0;
    var shown = 0;
    for (final m in r.matches) {
      if (shown >= _highlightLimit || m.start >= limit) break;
      if (m.start > pos) spans.add(TextSpan(text: text.substring(pos, m.start)));
      final end = m.end > limit ? limit : m.end;
      if (m.start == m.end) {
        spans.add(TextSpan(text: RegexPage.empty, style: markStyle));
      } else {
        spans.add(TextSpan(text: RegexPage.open, style: markStyle));
        spans.add(TextSpan(text: text.substring(m.start, end), style: hitStyle));
        spans.add(TextSpan(text: RegexPage.close, style: markStyle));
      }
      pos = end;
      shown++;
    }
    if (pos < limit) spans.add(TextSpan(text: text.substring(pos, limit)));
    final notes = [
      if (shown < r.matches.length) 'Highlighting the first $shown of ${r.matches.length} matches.',
      if (limit < text.length) 'Showing the first $limit of ${text.length} characters.',
    ];
    return NeonPanel(
      kicker: 'MATCHES',
      title: 'Highlighted text',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${RegexPage.open}match${RegexPage.close} marks a match, ${RegexPage.empty} an empty match.',
            style: J3Type.caption,
          ),
          const SizedBox(height: J3Space.xs),
          Container(
            constraints: const BoxConstraints(maxHeight: 320),
            padding: const EdgeInsets.all(J3Space.md),
            decoration: BoxDecoration(
              color: J3Colors.inputFill,
              borderRadius: J3Radius.small,
              border: Border.all(color: J3Colors.border),
            ),
            child: Scrollbar(
              child: SingleChildScrollView(
                child: SelectableText.rich(TextSpan(style: J3Type.code, children: spans)),
              ),
            ),
          ),
          for (final n in notes) HelpText(n),
        ],
      ),
    );
  }

  Widget _matchList(RegexRunResult r, int selected) {
    final height = (r.matches.length * 48.0).clamp(48.0, 288.0);
    return NeonPanel(
      kicker: 'LIST',
      title: '${r.matches.length} match${r.matches.length == 1 ? '' : 'es'}',
      padding: const EdgeInsets.fromLTRB(J3Space.lg, J3Space.lg, J3Space.lg, J3Space.sm),
      child: SizedBox(
        height: height,
        // Own Material so row ink is painted above the panel background.
        child: Material(type: MaterialType.transparency, child: _scrollList(r, selected)),
      ),
    );
  }

  Widget _scrollList(RegexRunResult r, int selected) {
    return Scrollbar(
      child: ListView.builder(
        itemCount: r.matches.length,
        itemExtent: 48,
        itemBuilder: (context, i) {
          final m = r.matches[i];
          final isSel = i == selected;
          final preview = m.text.length > 80 ? '${m.text.substring(0, 80)}...' : m.text;
          return Semantics(
            selected: isSel,
            button: true,
            child: InkWell(
              onTap: () => ref.read(regexToolProvider.notifier).select(i),
              borderRadius: J3Radius.small,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: J3Space.sm),
                decoration: BoxDecoration(color: isSel ? J3Colors.selection : null, borderRadius: J3Radius.small),
                child: Row(
                  children: [
                    SizedBox(
                      width: 18,
                      child: isSel ? Icon(Icons.chevron_right, size: 16, color: context.effects.accentText) : null,
                    ),
                    Text('#${i + 1}', style: J3Type.codeSmall),
                    const SizedBox(width: J3Space.sm),
                    Text('[${m.start}, ${m.end})', style: J3Type.codeSmall),
                    const SizedBox(width: J3Space.sm),
                    Expanded(
                      child: Text(
                        preview.isEmpty ? '(empty match)' : preview.replaceAll('\n', r'\n'),
                        style: J3Type.code,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _groups(RegexRunResult r, int index) {
    final m = r.matches[index];
    final names = namedGroupNumbers(ref.read(regexToolProvider).job?.pattern ?? '').map((k, v) => MapEntry(v, k));
    return NeonPanel(
      kicker: 'GROUPS',
      title: 'Match #${index + 1} at ${m.start}-${m.end}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ValueRow(label: r'$0 (whole match)', value: m.text),
          if (m.groups.isEmpty) const HelpText('The pattern has no capture groups.'),
          for (var g = 0; g < m.groups.length; g++)
            ValueRow(
              label: '\$${g + 1}${names[g + 1] == null ? '' : ' <${names[g + 1]}>'}',
              value: m.groups[g] ?? '(did not participate)',
              copyable: m.groups[g] != null,
            ),
          if (r.groupNames.isNotEmpty) ...[
            const MiniHeader('Named groups'),
            for (final n in r.groupNames)
              ValueRow(label: '\${$n}', value: m.named[n] ?? '(did not participate)', copyable: m.named[n] != null),
          ],
        ],
      ),
    );
  }
}
