import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/activity/activity_controller.dart';
import '../../../core/drafts/drafts.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/common.dart';
import '../domain/json_escape.dart';
import 'dev_widgets.dart';

enum JsonEscapeMode {
  escape('Escape text'),
  unescape('Unescape literal');

  const JsonEscapeMode(this.label);
  final String label;
}

class JsonEscapePage extends ConsumerStatefulWidget {
  const JsonEscapePage({super.key});
  static const id = 'dev.json_escape';

  @override
  ConsumerState<JsonEscapePage> createState() => _JsonEscapePageState();
}

class _JsonEscapePageState extends ConsumerState<JsonEscapePage> {
  static const _k = JsonEscapePage.id;
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  JsonEscapeOptions _options() => JsonEscapeOptions(
    quotes: ref.read(draftValueProvider('$_k/quotes')) != false,
    asciiOnly: ref.read(draftValueProvider('$_k/ascii')) == true,
    escapeSlash: ref.read(draftValueProvider('$_k/slash')) == true,
  );

  void _swap(TextEditingController input, JsonEscapeMode mode) {
    try {
      if (mode == JsonEscapeMode.escape) {
        input.text = JsonEscape.escape(input.text, _options());
        ref.setDraft('$_k/mode', JsonEscapeMode.unescape);
      } else {
        input.text = JsonEscape.unescape(input.text).text;
        ref.setDraft('$_k/mode', JsonEscapeMode.escape);
      }
    } on InputError catch (e) {
      ref.read(activityProvider.notifier).notify(NoticeKind.error, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final input = ref.watch(draftTextProvider('$_k/input'));
    final mode = ref.draft<JsonEscapeMode>('$_k/mode', JsonEscapeMode.escape);
    final quotes = ref.draft<bool>('$_k/quotes', true);
    final ascii = ref.draft<bool>('$_k/ascii', false);
    final slash = ref.draft<bool>('$_k/slash', false);
    final options = JsonEscapeOptions(quotes: quotes, asciiOnly: ascii, escapeSlash: slash);

    final inputs = [
      NeonPanel(
        kicker: 'INPUT',
        title: mode == JsonEscapeMode.escape ? 'Raw text' : 'JSON string literal',
        icon: Icons.data_object,
        actions: [InputActions(controller: input)],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ChoiceRow<JsonEscapeMode>(
              label: 'Mode',
              options: JsonEscapeMode.values,
              selected: mode,
              labelOf: (m) => m.label,
              onSelected: (m) => ref.setDraft('$_k/mode', m),
            ),
            const SizedBox(height: J3Space.md),
            CodeField(
              key: const Key('dev.json_escape.input'),
              controller: input,
              focusNode: _focus,
              minLines: 5,
              maxLines: 14,
              hint: mode == JsonEscapeMode.escape ? 'Line 1\n"quoted"\tand a tab' : r'"Line 1\n\"quoted\"\tand a tab"',
            ),
            if (mode == JsonEscapeMode.escape) ...[
              const MiniHeader('Options'),
              OptionSwitch(
                label: 'Surrounding quotes',
                description: 'Output a complete "..." literal.',
                value: quotes,
                onChanged: (v) => ref.setDraft('$_k/quotes', v),
              ),
              OptionSwitch(
                label: 'Escape non-ASCII',
                description: r'Write every non-ASCII character as \uXXXX (surrogate pairs above U+FFFF).',
                value: ascii,
                onChanged: (v) => ref.setDraft('$_k/ascii', v),
              ),
              OptionSwitch(
                label: r'Escape / as \/',
                description: 'Safe inside an HTML <script> block.',
                value: slash,
                onChanged: (v) => ref.setDraft('$_k/slash', v),
              ),
            ] else
              const HelpText(
                'Quotes around the literal are optional. Errors show the exact position of the bad escape.',
              ),
            const SizedBox(height: J3Space.sm),
            ActionWrap(
              children: [
                ListenableBuilder(
                  listenable: input,
                  builder: (context, _) => NeonButton.ghost(
                    label: 'Swap',
                    icon: Icons.swap_vert,
                    tooltip: 'Use the output as input and flip the mode',
                    onPressed: input.text.isEmpty ? null : () => _swap(input, mode),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ];

    final results = [
      ListenableBuilder(
        listenable: input,
        builder: (context, _) {
          if (input.text.isEmpty) {
            return const EmptyState(
              title: 'Waiting for input',
              message: 'Results update as you type.',
              glyph: r'[ \" ]',
            );
          }
          if (mode == JsonEscapeMode.escape) {
            return CappedTextResult(
              text: JsonEscape.escape(input.text, options),
              title: 'JSON string literal',
              fileName: 'escaped.json.txt',
              toolId: _k,
            );
          }
          try {
            final r = JsonEscape.unescape(input.text);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (r.warnings.isNotEmpty) ...[
                  StatusBanner(kind: StatusKind.warning, title: 'Unpaired surrogates', details: r.warnings),
                  const SizedBox(height: J3Space.md),
                ],
                CappedTextResult(
                  text: r.text,
                  title: r.hadQuotes ? 'Unescaped text' : 'Unescaped text (no quotes found)',
                  fileName: 'unescaped.txt',
                  toolId: _k,
                ),
              ],
            );
          } on InputError catch (e) {
            return InputErrorBanner(error: e, title: 'Invalid JSON string', controller: input, focusNode: _focus);
          }
        },
      ),
    ];
    return ToolScaffold(toolId: _k, inputs: inputs, results: results);
  }
}
