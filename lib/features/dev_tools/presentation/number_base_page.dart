import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/drafts/drafts.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/common.dart';
import '../domain/number_base.dart';
import 'dev_widgets.dart';

class NumberBasePage extends ConsumerStatefulWidget {
  const NumberBasePage({super.key});
  static const id = 'dev.number_base';

  @override
  ConsumerState<NumberBasePage> createState() => _NumberBasePageState();
}

class _NumberBasePageState extends ConsumerState<NumberBasePage> {
  static const _k = NumberBasePage.id;

  /// Input base choices; -1 = auto (prefix detection), 0 = custom.
  static const _bases = [-1, 2, 8, 10, 16, 0];
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    for (final key in ['customIn', 'customOut']) {
      final c = ref.read(draftTextProvider('$_k/$key'));
      if (c.text.isEmpty) c.text = '36';
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final input = ref.watch(draftTextProvider('$_k/input'));
    final customIn = ref.watch(draftTextProvider('$_k/customIn'));
    final customOut = ref.watch(draftTextProvider('$_k/customOut'));
    final base = ref.draft<int>('$_k/base', -1);
    final width = ref.draft<int>('$_k/width', 32);
    final group = ref.draft<bool>('$_k/group', true);

    final inputs = [
      NeonPanel(
        kicker: 'INPUT',
        title: 'Integer',
        icon: Icons.calculate_outlined,
        actions: [InputActions(controller: input, what: 'number')],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('dev.number_base.input'),
              controller: input,
              focusNode: _focus,
              style: J3Type.code,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Value',
                hintText: '0xDEADBEEF  |  -42  |  0b1010_1010',
                helperText: 'Optional sign; _ and spaces separate digits',
              ),
            ),
            const SizedBox(height: J3Space.md),
            ChoiceRow<int>(
              label: 'Input base',
              options: _bases,
              selected: base,
              labelOf: (b) => switch (b) {
                -1 => 'Auto (0x/0b/0o)',
                0 => 'Custom',
                2 => 'Bin',
                8 => 'Oct',
                10 => 'Dec',
                _ => 'Hex',
              },
              onSelected: (b) => ref.setDraft('$_k/base', b),
            ),
            if (base == 0) ...[
              const SizedBox(height: J3Space.md),
              NumberField(
                key: const Key('dev.number_base.customIn'),
                controller: customIn,
                label: 'Input base (2-36)',
                min: 2,
                max: 36,
              ),
            ],
            const MiniHeader('Output'),
            NumberField(
              key: const Key('dev.number_base.customOut'),
              controller: customOut,
              label: 'Extra base (2-36)',
              min: 2,
              max: 36,
            ),
            DevSwitch(
              label: 'Group digits',
              description: 'Binary in 4s, hex in 2s, decimal in 3s.',
              value: group,
              onChanged: (v) => ref.setDraft('$_k/group', v),
            ),
            ChoiceRow<int>(
              label: "Two's complement width",
              options: NumberBase.widths,
              selected: width,
              labelOf: (w) => '$w-bit',
              onSelected: (w) => ref.setDraft('$_k/width', w),
            ),
          ],
        ),
      ),
    ];

    final results = [
      ListenableBuilder(
        listenable: Listenable.merge([input, customIn, customOut]),
        builder: (context, _) => _results(input, base, customIn.text, customOut.text, width, group),
      ),
    ];
    return ToolScaffold(toolId: _k, inputs: inputs, results: results);
  }

  Widget _results(TextEditingController input, int base, String customIn, String customOut, int width, bool group) {
    if (input.text.trim().isEmpty) {
      return const EmptyState(title: 'Enter a number', message: 'Any size: BigInt arithmetic.', glyph: '[ 0x2A ]');
    }
    int? inBase = base == -1 ? null : base;
    if (base == 0) {
      inBase = int.tryParse(customIn.trim());
      if (inBase == null || inBase < 2 || inBase > 36) {
        return const StatusBanner(kind: StatusKind.error, title: 'Invalid base', message: 'Input base must be 2-36.');
      }
    }
    final ParsedNumber p;
    try {
      p = NumberBase.parse(input.text, inBase);
    } on InputError catch (e) {
      return InputErrorBanner(error: e, title: 'Not a valid number', controller: input, focusNode: _focus);
    }
    final v = p.value;
    final outBase = int.tryParse(customOut.trim());
    final validOut = outBase != null && outBase >= 2 && outBase <= 36;
    final view = NumberBase.view(v, width);
    final smallest = NumberBase.smallestWidth(v);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeonPanel(
          kicker: 'VALUE',
          title: 'Read as base ${p.base}${p.prefix == null ? '' : ' (prefix ${p.prefix})'}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ValueRow(
                key: const Key('dev.number_base.bin'),
                label: 'Binary (2)',
                value: NumberBase.format(v, 2, group: group ? 4 : 0),
              ),
              ValueRow(
                label: 'Octal (8)',
                value: NumberBase.format(v, 8, group: group ? 3 : 0),
              ),
              ValueRow(
                key: const Key('dev.number_base.dec'),
                label: 'Decimal (10)',
                value: NumberBase.format(v, 10, group: group ? 3 : 0),
              ),
              ValueRow(
                key: const Key('dev.number_base.hex'),
                label: 'Hex (16)',
                value: NumberBase.format(v, 16, group: group ? 2 : 0),
              ),
              if (validOut)
                ValueRow(
                  label: 'Base $outBase',
                  value: NumberBase.format(v, outBase, upper: outBase > 16 ? false : true),
                )
              else
                const StatusLine(kind: StatusKind.error, text: 'Extra base must be a whole number from 2 to 36.'),
              ValueRow(
                label: 'Bit length',
                value:
                    '${v.isNegative ? (-v - BigInt.one).bitLength + 1 : v.bitLength} bits'
                    '${smallest == null ? ' (wider than 128-bit)' : ', fits in $smallest-bit'}',
                copyable: false,
              ),
            ],
          ),
        ),
        const SizedBox(height: J3Space.lg),
        NeonPanel(
          kicker: 'FIXED WIDTH',
          title: "$width-bit two's complement",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (view.overflows) ...[
                StatusBanner(
                  kind: StatusKind.warning,
                  title: 'Overflow',
                  message:
                      'The value does not fit in $width bits (signed or unsigned). The rows below show only the low '
                      '$width bits, which is what a $width-bit register or file field would store.',
                ),
                const SizedBox(height: J3Space.sm),
              ],
              ActionWrap(
                children: [
                  StatusBadge(
                    kind: view.fitsUnsigned ? StatusKind.success : StatusKind.error,
                    text: view.fitsUnsigned ? 'FITS UNSIGNED' : 'NOT UNSIGNED',
                  ),
                  StatusBadge(
                    kind: view.fitsSigned ? StatusKind.success : StatusKind.error,
                    text: view.fitsSigned ? 'FITS SIGNED' : 'NOT SIGNED',
                  ),
                ],
              ),
              const SizedBox(height: J3Space.sm),
              ValueRow(label: 'Hex pattern', value: NumberBase.format(view.pattern, 16).padLeft(width ~/ 4, '0')),
              ValueRow(label: 'Bit pattern', value: _groupBits(view.pattern.toRadixString(2).padLeft(width, '0'))),
              ValueRow(label: 'As unsigned', value: view.pattern.toString()),
              ValueRow(label: 'As signed', value: view.signed.toString()),
              ValueRow(label: 'Bytes (big-endian)', value: hexBytes(view.bytesBigEndian)),
              ValueRow(label: 'Bytes (little-endian)', value: hexBytes(view.bytesLittleEndian)),
              if (view.asFloat != null) ValueRow(label: 'Bits as float$width', value: _float(view.asFloat!)),
            ],
          ),
        ),
      ],
    );
  }

  static String _groupBits(String bits) {
    final b = StringBuffer();
    for (var i = 0; i < bits.length; i += 4) {
      if (i > 0) b.write(i % 8 == 0 ? '  ' : ' ');
      b.write(bits.substring(i, i + 4));
    }
    return b.toString();
  }

  static String _float(double d) {
    if (d.isNaN) return 'NaN';
    if (d.isInfinite) return d.isNegative ? '-Infinity' : 'Infinity';
    return d.toString();
  }
}
