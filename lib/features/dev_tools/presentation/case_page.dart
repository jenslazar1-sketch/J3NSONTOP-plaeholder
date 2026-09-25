import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/drafts/drafts.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/case_tools.dart';
import 'dev_widgets.dart';

class CasePage extends ConsumerWidget {
  const CasePage({super.key});
  static const id = 'dev.case';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const k = id;
    final input = ref.watch(draftTextProvider('$k/input'));
    final splitDigits = ref.draft<bool>('$k/splitDigits', false);
    final keepAcronyms = ref.draft<bool>('$k/keepAcronyms', false);
    final options = CaseOptions(splitDigits: splitDigits, keepAcronyms: keepAcronyms);

    final inputs = [
      NeonPanel(
        kicker: 'INPUT',
        title: 'Identifier or phrase',
        icon: Icons.text_fields,
        actions: [InputActions(controller: input)],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CodeField(
              key: const Key('dev.case.input'),
              controller: input,
              minLines: 3,
              maxLines: 10,
              hint: 'HTTPServerError\nplayer_max_health\nmy-mod-name',
            ),
            const HelpText('Each line is converted separately, so you can paste a list of names.'),
            const MiniHeader('Word splitting'),
            OptionSwitch(
              label: 'Split numbers',
              description: 'utf8Decoder -> utf, 8, Decoder (off: utf8, Decoder).',
              value: splitDigits,
              onChanged: (v) => ref.setDraft('$k/splitDigits', v),
            ),
            OptionSwitch(
              label: 'Keep acronyms',
              description: 'XML http -> XMLHttp in Pascal/camel/Title instead of XmlHttp.',
              value: keepAcronyms,
              onChanged: (v) => ref.setDraft('$k/keepAcronyms', v),
            ),
          ],
        ),
      ),
    ];

    final results = [
      ListenableBuilder(
        listenable: input,
        builder: (context, _) {
          if (input.text.trim().isEmpty) {
            return const EmptyState(title: 'Type a name', message: 'All 11 styles update live.', glyph: '[ aA_- ]');
          }
          final words = CaseTools.words(input.text.split('\n').first, options);
          return NeonPanel(
            kicker: 'CONVERTED',
            title: 'All styles',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Words (first line): ${words.isEmpty ? '(none)' : words.join(' | ')}', style: J3Type.caption),
                const SizedBox(height: J3Space.sm),
                for (final style in CaseStyle.values)
                  ValueRow(
                    key: Key('dev.case.${style.name}'),
                    label: style.label,
                    value: CaseTools.convert(input.text, style, options),
                  ),
              ],
            ),
          );
        },
      ),
    ];
    return ToolScaffold(toolId: id, inputs: inputs, results: results);
  }
}
