import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/drafts/drafts.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/common.dart';
import '../domain/timestamp_tools.dart';
import '../domain/uuid_tools.dart';
import 'dev_widgets.dart';

class UuidPage extends ConsumerStatefulWidget {
  const UuidPage({super.key});
  static const id = 'dev.uuid';

  @override
  ConsumerState<UuidPage> createState() => _UuidPageState();
}

class _UuidPageState extends ConsumerState<UuidPage> {
  static const _k = UuidPage.id;
  final _inspectFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    final count = ref.read(draftTextProvider('$_k/count'));
    if (count.text.isEmpty) count.text = '5';
  }

  @override
  void dispose() {
    _inspectFocus.dispose();
    super.dispose();
  }

  void _generate() {
    final kind = ref.read(draftValueProvider('$_k/kind')) as UuidKind? ?? UuidKind.v4;
    final n = int.tryParse(ref.read(draftTextProvider('$_k/count')).text.trim());
    if (n == null || n < 1 || n > UuidTools.maxCount) {
      ref.setDraft('$_k/error', 'Count must be a whole number from 1 to ${UuidTools.maxCount}.');
      return;
    }
    // Stored canonical so format toggles apply without regenerating.
    final ids = UuidTools.generate(kind, n, clock: ref.read(devClockProvider));
    ref.setDraft('$_k/error', null);
    ref.setDraft('$_k/generatedKind', kind);
    ref.setDraft('$_k/generated', ids);
  }

  @override
  Widget build(BuildContext context) {
    final kind = ref.draft<UuidKind>('$_k/kind', UuidKind.v4);
    final count = ref.watch(draftTextProvider('$_k/count'));
    final upper = ref.draft<bool>('$_k/upper', false);
    final noHyphens = ref.draft<bool>('$_k/noHyphens', false);
    final braces = ref.draft<bool>('$_k/braces', false);
    final generated = ref.draft<List<String>>('$_k/generated', const []);
    final error = ref.draft<String?>('$_k/error', null);
    final inspect = ref.watch(draftTextProvider('$_k/inspect'));
    final format = UuidFormat(uppercase: upper, hyphens: !noHyphens, braces: braces);
    final text = generated.map(format.apply).join('\n');

    final inputs = [
      CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): _generate},
        child: NeonPanel(
          kicker: 'GENERATE',
          title: 'New UUIDs',
          icon: Icons.fingerprint,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ChoiceRow<UuidKind>(
                label: 'Version',
                options: UuidKind.values,
                selected: kind,
                labelOf: (k) => k.label,
                onSelected: (k) => ref.setDraft('$_k/kind', k),
              ),
              HelpText(
                kind == UuidKind.v4
                    ? '122 random bits from a cryptographically secure generator.'
                    : 'Unix time in ms + counter: sorts by creation time (RFC 9562). Reveals when it was made.',
              ),
              const SizedBox(height: J3Space.md),
              NumberField(
                key: const Key('dev.uuid.count'),
                controller: count,
                label: 'Count (1-${UuidTools.maxCount})',
                min: 1,
                max: UuidTools.maxCount,
                width: 180,
              ),
              OptionSwitch(label: 'Uppercase', value: upper, onChanged: (v) => ref.setDraft('$_k/upper', v)),
              OptionSwitch(label: 'No hyphens', value: noHyphens, onChanged: (v) => ref.setDraft('$_k/noHyphens', v)),
              OptionSwitch(
                label: 'Braces {...}',
                description: 'Microsoft GUID style',
                value: braces,
                onChanged: (v) => ref.setDraft('$_k/braces', v),
              ),
              const SizedBox(height: J3Space.sm),
              ActionWrap(
                children: [
                  NeonButton(
                    key: const Key('dev.uuid.generate'),
                    label: 'Generate',
                    icon: Icons.auto_awesome,
                    tooltip: 'Generate (Ctrl+Enter)',
                    onPressed: _generate,
                  ),
                ],
              ),
              if (error != null) ...[
                const SizedBox(height: J3Space.sm),
                StatusLine(kind: StatusKind.error, text: error),
              ],
            ],
          ),
        ),
      ),
      NeonPanel(
        kicker: 'INSPECT',
        title: 'Validate and explain a UUID',
        icon: Icons.manage_search,
        actions: [InputActions(controller: inspect, what: 'UUID')],
        child: TextField(
          key: const Key('dev.uuid.inspect'),
          controller: inspect,
          focusNode: _inspectFocus,
          style: J3Type.code,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'UUID',
            hintText: '0190163d-8694-739b-aea5-966c26f8ad91',
            helperText: 'Accepts upper case, no hyphens, {braces} and urn:uuid:',
          ),
        ),
      ),
    ];

    final results = [
      if (generated.isEmpty)
        const EmptyState(title: 'No UUIDs yet', message: 'Choose a version and press Generate.', glyph: '[ ???? ]')
      else
        ResultPanel(
          text: text,
          title: '${generated.length} x ${ref.draft<UuidKind>('$_k/generatedKind', UuidKind.v4).label}',
          kicker: 'GENERATED',
          fileName: 'uuids.txt',
          toolId: _k,
          lineNumbers: generated.length > 1,
          maxHeight: 320,
          extraActions: [
            IconButton(
              tooltip: 'Inspect the first UUID',
              onPressed: () => inspect.text = format.apply(generated.first),
              icon: const Icon(Icons.manage_search, size: 18),
            ),
          ],
        ),
      ListenableBuilder(listenable: inspect, builder: (context, _) => _inspection(inspect)),
    ];
    return ToolScaffold(toolId: _k, inputs: inputs, results: results);
  }

  Widget _inspection(TextEditingController c) {
    if (c.text.trim().isEmpty) return const SizedBox.shrink();
    final UuidInfo info;
    try {
      info = UuidTools.inspect(c.text);
    } on InputError catch (e) {
      return InputErrorBanner(error: e, title: 'Not a valid UUID', controller: c, focusNode: _inspectFocus);
    }
    final now = ref.read(devClockProvider)();
    final ts = info.timestamp;
    return NeonPanel(
      kicker: 'INSPECTION',
      title: info.versionName,
      emphasis: info.isStandard ? PanelEmphasis.success : PanelEmphasis.normal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ActionWrap(
            children: [
              StatusBadge(
                kind: info.isStandard ? StatusKind.success : StatusKind.warning,
                text: info.isStandard ? 'VALID' : 'NON-STANDARD',
              ),
              if (info.isNil) const StatusBadge(kind: StatusKind.info, text: 'NIL'),
              if (info.isMax) const StatusBadge(kind: StatusKind.info, text: 'MAX'),
            ],
          ),
          const SizedBox(height: J3Space.sm),
          ValueRow(label: 'Canonical', value: info.canonical),
          ValueRow(label: 'Version', value: info.isNil || info.isMax ? 'n/a' : '${info.version}', copyable: false),
          ValueRow(label: 'Variant', value: info.variant.label, copyable: false),
          ValueRow(
            label: 'Hex',
            value: hexBytes(info.bytes, separator: ''),
          ),
          if (ts != null) ...[
            ValueRow(label: 'Created (UTC)', value: Timestamps.isoUtc(ts)),
            ValueRow(label: 'Created (local)', value: Timestamps.isoWithOffset(ts, ts.toLocal().timeZoneOffset)),
            ValueRow(label: 'Age', value: Timestamps.relative(ts, now), copyable: false),
            if (info.timestampNote != null) HelpText('Timestamp: ${info.timestampNote}.'),
          ],
          for (final n in info.notes) HelpText(n),
        ],
      ),
    );
  }
}
