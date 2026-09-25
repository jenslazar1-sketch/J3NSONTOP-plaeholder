import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/activity/activity_controller.dart';
import '../../../core/drafts/drafts.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/text_stats.dart';
import 'dev_widgets.dart';

class TextStatsPage extends ConsumerStatefulWidget {
  const TextStatsPage({super.key});
  static const id = 'dev.text_stats';

  @override
  ConsumerState<TextStatsPage> createState() => _TextStatsPageState();
}

class _TextStatsPageState extends ConsumerState<TextStatsPage> {
  static const _k = TextStatsPage.id;
  final _debounce = Debouncer(const Duration(milliseconds: 150));
  final _slowDebounce = Debouncer(const Duration(milliseconds: 400));
  late final TextEditingController _input = ref.read(draftTextProvider('$_k/input'));
  TextStats? _stats;
  String? _statsFor;
  int _generation = 0;
  bool _computing = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _input.addListener(_onChanged);
    _recompute(immediate: true);
  }

  @override
  void dispose() {
    _input.removeListener(_onChanged);
    _debounce.dispose();
    _slowDebounce.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (_input.text == _statsFor) return; // selection-only change
    _recompute();
  }

  void _recompute({bool immediate = false}) {
    final text = _input.text;
    final big = text.length > TextStatsCalculator.isolateThreshold;
    if (!big && (immediate || text.length < 20000)) {
      _debounce.cancel();
      _slowDebounce.cancel();
      _generation++;
      final s = TextStatsCalculator.compute(text);
      if (immediate) {
        _stats = s;
        _statsFor = text;
      } else {
        setState(() {
          _stats = s;
          _statsFor = text;
          _computing = false;
        });
      }
      return;
    }
    (big ? _slowDebounce : _debounce).call(() => _computeAsync(text));
    if (!immediate) setState(() {}); // show the "updating" state while waiting
  }

  Future<void> _computeAsync(String text) async {
    final gen = ++_generation;
    setState(() => _computing = true);
    final s = text.length > TextStatsCalculator.isolateThreshold
        ? await TextStatsCalculator.computeInBackground(text)
        : TextStatsCalculator.compute(text);
    if (!mounted || gen != _generation) return;
    setState(() {
      _stats = s;
      _statsFor = text;
      _computing = false;
    });
  }

  Future<void> _openFile() async {
    setState(() => _loading = true);
    try {
      final f = await pickTextFile(context, ref);
      if (f == null) return;
      _input.text = f.text;
      if (f.lossy) {
        ref
            .read(activityProvider.notifier)
            .notify(NoticeKind.warning, '${f.name} is not valid ${f.encodingLabel}; decoded as Latin-1.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inputs = [
      NeonPanel(
        kicker: 'INPUT',
        title: 'Text',
        icon: Icons.notes,
        actions: [InputActions(controller: _input, what: 'text')],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CodeField(
              key: const Key('dev.text_stats.input'),
              controller: _input,
              hint: 'Paste a README, a dialogue file or a mod description...',
              minLines: 8,
              maxLines: 20,
            ),
            const SizedBox(height: J3Space.md),
            ActionWrap(
              children: [
                NeonButton.secondary(
                  label: 'Open text file',
                  icon: Icons.file_open_outlined,
                  busy: _loading,
                  tooltip: 'Load a text file (up to 16 MB)',
                  onPressed: _openFile,
                ),
              ],
            ),
          ],
        ),
      ),
    ];
    return ToolScaffold(toolId: _k, inputs: inputs, results: [_results()]);
  }

  Widget _results() {
    final s = _stats;
    if (s == null || _input.text.isEmpty) {
      return const EmptyState(title: 'No text yet', message: 'Statistics update live as you type.', glyph: '[ 0 wc ]');
    }
    String n(int v) => v.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeonPanel(
          kicker: _computing || _statsFor != _input.text ? 'STATS (UPDATING...)' : 'STATS',
          title: '${n(s.words)} words, ${n(s.lines)} lines',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              StatGrid(
                tiles: [
                  StatTile(
                    label: 'Characters (UTF-16)',
                    value: n(s.utf16Units),
                    hint: 'String length in UTF-16 code units',
                  ),
                  StatTile(label: 'Code points', value: n(s.codePoints), hint: 'Unicode scalar values (runes)'),
                  StatTile(
                    label: 'Graphemes',
                    value: n(s.graphemes),
                    hint: 'User-perceived characters (emoji, accents)',
                  ),
                  StatTile(label: 'Words', value: n(s.words)),
                  StatTile(label: 'Unique words', value: n(s.uniqueWords)),
                  StatTile(label: 'Lines', value: n(s.lines), hint: 'A trailing line break does not add a line'),
                  StatTile(label: 'Blank lines', value: n(s.blankLines)),
                  StatTile(label: 'Paragraphs', value: n(s.paragraphs)),
                  StatTile(label: 'Sentences (approx.)', value: n(s.sentences)),
                  StatTile(label: 'UTF-8 bytes', value: n(s.utf8Bytes), hint: Fmt.bytes(s.utf8Bytes)),
                  StatTile(label: 'UTF-16 bytes', value: n(s.utf16Bytes), hint: 'Without byte order mark'),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: J3Space.lg),
        NeonPanel(
          kicker: 'DETAILS',
          title: 'Lines, characters and time',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ValueRow(
                label: 'Longest line',
                value: s.lines == 0 ? '-' : '${n(s.longestLine)} code points (line ${s.longestLineNumber})',
                copyable: false,
              ),
              ValueRow(label: 'Line endings', value: s.lineEnding.label, copyable: false),
              ValueRow(label: 'Letters / digits', value: '${n(s.letters)} / ${n(s.digits)}', copyable: false),
              ValueRow(label: 'Whitespace / other', value: '${n(s.whitespace)} / ${n(s.other)}', copyable: false),
              ValueRow(label: 'Non-ASCII', value: n(s.nonAscii), copyable: false),
              ValueRow(
                label: 'Reading time',
                value: '~${TextStats.formatMinutes(s.readingTime)} (238 wpm)',
                copyable: false,
              ),
              ValueRow(
                label: 'Speaking time',
                value: '~${TextStats.formatMinutes(s.speakingTime)} (150 wpm)',
                copyable: false,
              ),
            ],
          ),
        ),
        if (s.topWords.isNotEmpty) ...[
          const SizedBox(height: J3Space.lg),
          NeonPanel(
            kicker: 'FREQUENCY',
            title: 'Top words',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (w, c) in s.topWords)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        SizedBox(width: 56, child: Text('${n(c)}x', style: J3Type.codeSmall)),
                        Expanded(child: SelectableText(w, style: J3Type.code)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
