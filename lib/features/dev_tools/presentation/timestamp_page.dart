import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/drafts/drafts.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/common.dart';
import '../domain/timestamp_tools.dart';
import 'dev_widgets.dart';

class TimestampPage extends ConsumerStatefulWidget {
  const TimestampPage({super.key});
  static const id = 'dev.timestamp';

  @override
  ConsumerState<TimestampPage> createState() => _TimestampPageState();
}

class _TimestampPageState extends ConsumerState<TimestampPage> {
  static const _k = TimestampPage.id;
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final input = ref.watch(draftTextProvider('$_k/input'));
    final kind = ref.draft<TimestampInput>('$_k/kind', TimestampInput.auto);
    final assumeUtc = ref.draft<bool>('$_k/assumeUtc', false);

    final inputs = [
      LiveClock(
        onUse: (now) {
          input.text = (now.millisecondsSinceEpoch ~/ 1000).toString();
          ref.setDraft('$_k/kind', TimestampInput.auto);
        },
      ),
      NeonPanel(
        kicker: 'CONVERT',
        title: 'Timestamp or date',
        icon: Icons.swap_horiz,
        actions: [InputActions(controller: input, what: 'timestamp')],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('dev.timestamp.input'),
              controller: input,
              focusNode: _focus,
              style: J3Type.code,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Value',
                hintText: '1758829267  |  2026-09-25T21:41:07+02:00  |  Fri, 25 Sep 2026 19:41:07 GMT',
                helperText: 'Unix s/ms/us/ns, ISO-8601 or RFC 2822 / HTTP date',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: J3Space.md),
            ChoiceRow<TimestampInput>(
              label: 'Read as',
              options: TimestampInput.values,
              selected: kind,
              labelOf: (k) => k.label,
              onSelected: (k) => ref.setDraft('$_k/kind', k),
            ),
            const HelpText(
              'Auto picks the Unix unit by magnitude: < 1e11 seconds, < 1e14 ms, < 1e17 us, otherwise ns. '
              'Override it when a value is ambiguous (for example ms timestamps before 1973).',
            ),
            OptionSwitch(
              label: 'Times without an offset are UTC',
              description: 'Off: "2026-09-25T10:00" is read as local time on this device.',
              value: assumeUtc,
              onChanged: (v) => ref.setDraft('$_k/assumeUtc', v),
            ),
          ],
        ),
      ),
    ];

    final results = [ListenableBuilder(listenable: input, builder: (context, _) => _result(input, kind, assumeUtc))];
    return ToolScaffold(toolId: _k, inputs: inputs, results: results);
  }

  Widget _result(TextEditingController input, TimestampInput kind, bool assumeUtc) {
    if (input.text.trim().isEmpty) {
      return const EmptyState(
        title: 'Enter a timestamp',
        message: 'Or press "Use now" on the live clock.',
        glyph: '[ --:--:-- ]',
      );
    }
    final ParsedInstant p;
    try {
      p = Timestamps.parse(input.text, kind: kind, assumeUtc: assumeUtc);
    } on InputError catch (e) {
      return InputErrorBanner(error: e, title: 'Cannot read this value', controller: input, focusNode: _focus);
    }
    final now = ref.read(devClockProvider)();
    final rows = Timestamps.describe(p, now);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (p.notes.isNotEmpty) ...[
          StatusBanner(kind: StatusKind.info, title: 'Note', details: p.notes),
          const SizedBox(height: J3Space.lg),
        ],
        NeonPanel(
          kicker: 'RESULT',
          title: 'Read as ${p.interpretation}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final (label, value) in rows) ValueRow(label: label, value: value)],
          ),
        ),
      ],
    );
  }
}

/// Live "now" in UTC and local time. Ticks once per second aligned to the
/// second boundary; the timer is paused while the page is offstage
/// (TickerMode disabled), can be paused by the user, and is cancelled on
/// dispose. No animation: only the numbers change.
class LiveClock extends ConsumerStatefulWidget {
  const LiveClock({super.key, required this.onUse});
  final ValueChanged<DateTime> onUse;

  @override
  ConsumerState<LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends ConsumerState<LiveClock> {
  Timer? _timer;
  ValueListenable<TickerModeData>? _tickerMode;
  bool _paused = false;
  late DateTime _now = ref.read(devClockProvider)();

  bool get _active => !_paused && (_tickerMode?.value.enabled ?? true);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifier = TickerMode.getValuesNotifier(context);
    if (notifier != _tickerMode) {
      _tickerMode?.removeListener(_onTickerMode);
      _tickerMode = notifier..addListener(_onTickerMode);
      _reschedule();
    }
  }

  void _onTickerMode() {
    if (_active) {
      setState(() => _now = ref.read(devClockProvider)());
    }
    _reschedule();
  }

  void _reschedule() {
    _timer?.cancel();
    _timer = null;
    if (!_active) return;
    final now = ref.read(devClockProvider)();
    _timer = Timer(Duration(milliseconds: 1000 - now.millisecond), _tick);
  }

  void _tick() {
    if (!mounted) return;
    setState(() => _now = ref.read(devClockProvider)());
    _reschedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tickerMode?.removeListener(_onTickerMode);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = _now;
    final utc = now.toUtc();
    final offset = now.toLocal().timeZoneOffset;
    return NeonPanel(
      kicker: _paused ? 'NOW (PAUSED)' : 'NOW (LIVE)',
      title: 'Current time',
      icon: Icons.schedule,
      actions: [
        IconButton(
          key: const Key('dev.timestamp.pause'),
          tooltip: _paused ? 'Resume live clock' : 'Pause live clock',
          onPressed: () {
            setState(() {
              _paused = !_paused;
              _now = ref.read(devClockProvider)();
            });
            _reschedule();
          },
          icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 20),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ValueRow(label: 'Unix seconds', value: '${utc.millisecondsSinceEpoch ~/ 1000}'),
          ValueRow(label: 'Unix milliseconds', value: '${utc.millisecondsSinceEpoch}'),
          ValueRow(label: 'ISO-8601 UTC', value: Timestamps.isoUtc(utc)),
          ValueRow(label: 'Local (${now.toLocal().timeZoneName})', value: Timestamps.isoWithOffset(utc, offset)),
          const SizedBox(height: J3Space.sm),
          ActionWrap(
            children: [
              NeonButton.secondary(
                label: 'Use now',
                icon: Icons.south,
                tooltip: 'Convert the current Unix time',
                dense: true,
                onPressed: () => widget.onUse(ref.read(devClockProvider)()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
