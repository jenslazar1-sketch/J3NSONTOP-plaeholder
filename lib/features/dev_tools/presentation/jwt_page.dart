import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/drafts/drafts.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/common.dart';
import '../domain/jwt_tools.dart';
import '../domain/timestamp_tools.dart';
import 'dev_widgets.dart';

class JwtPage extends ConsumerStatefulWidget {
  const JwtPage({super.key});
  static const id = 'dev.jwt';

  @override
  ConsumerState<JwtPage> createState() => _JwtPageState();
}

class _JwtPageState extends ConsumerState<JwtPage> {
  static const _k = JwtPage.id;
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final input = ref.watch(draftTextProvider('$_k/input'));
    final inputs = [
      const StatusBanner(
        kind: StatusKind.warning,
        title: 'Decode only - the signature is NOT verified',
        message:
            'Anyone can write a token with any claims. Only a server holding the key can verify it. '
            'Decoding happens on this device; nothing is sent anywhere.',
      ),
      NeonPanel(
        kicker: 'INPUT',
        title: 'JSON Web Token',
        icon: Icons.key_outlined,
        actions: [InputActions(controller: input, what: 'token')],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CodeField(
              key: const Key('dev.jwt.input'),
              controller: input,
              focusNode: _focus,
              minLines: 4,
              maxLines: 10,
              hint: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiJ9.signature',
            ),
            const HelpText('A leading "Bearer " is ignored. Tokens are not stored anywhere except this draft.'),
          ],
        ),
      ),
    ];
    final results = [ListenableBuilder(listenable: input, builder: (context, _) => _results(input))];
    return ToolScaffold(toolId: _k, inputs: inputs, results: results);
  }

  Widget _results(TextEditingController input) {
    if (input.text.trim().isEmpty) {
      return const EmptyState(
        title: 'Paste a token',
        message: 'Header, payload and dates decode instantly.',
        glyph: '[ x.y.z ]',
      );
    }
    final JwtDecoded d;
    try {
      d = JwtTools.decode(input.text);
    } on InputError catch (e) {
      return InputErrorBanner(error: e, title: 'Cannot decode token', controller: input, focusNode: _focus);
    }
    final now = ref.read(devClockProvider)();
    final status = d.statusAt(now);
    final (kind, label) = switch (status) {
      JwtTimeStatus.expired => (StatusKind.error, 'EXPIRED'),
      JwtTimeStatus.notYetValid => (StatusKind.warning, 'NOT YET VALID'),
      JwtTimeStatus.valid => (StatusKind.success, 'WITHIN VALIDITY WINDOW'),
      JwtTimeStatus.noTimeClaims => (StatusKind.neutral, 'NO exp/nbf CLAIMS'),
    };
    final payload = d.payload;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeonPanel(
          kicker: 'SUMMARY',
          title: 'alg ${d.algorithm ?? '(none given)'}${d.header['typ'] is String ? ' | typ ${d.header['typ']}' : ''}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ActionWrap(
                children: [
                  if (!d.isEncrypted) StatusBadge(key: const Key('dev.jwt.status'), kind: kind, text: label),
                  const StatusBadge(kind: StatusKind.warning, text: 'SIGNATURE NOT VERIFIED'),
                  if (d.isEncrypted) const StatusBadge(kind: StatusKind.info, text: 'ENCRYPTED (JWE)'),
                ],
              ),
              const SizedBox(height: J3Space.sm),
              for (final c in d.timeClaims) ...[
                ValueRow(
                  label: '${c.label} (${c.name})',
                  value: '${Timestamps.isoUtc(c.time)}  |  ${Timestamps.relative(c.time, now)}',
                  copyable: false,
                ),
                ValueRow(
                  label: '  local time',
                  value: Timestamps.isoWithOffset(c.time, c.time.toLocal().timeZoneOffset),
                  copyable: false,
                ),
              ],
              if (payload != null)
                for (final e in JwtTools.claimNames.entries)
                  if (payload.containsKey(e.key) && !const {'exp', 'nbf', 'iat'}.contains(e.key))
                    ValueRow(
                      label: '${e.value} (${e.key})',
                      value: payload[e.key] is String ? payload[e.key] as String : jsonEncode(payload[e.key]),
                    ),
              if (!d.isEncrypted)
                ValueRow(
                  label: 'Signature',
                  value: d.signature.isEmpty ? '(empty)' : '${d.signatureBytes} bytes: ${d.signature}',
                  copyable: d.signature.isNotEmpty,
                ),
            ],
          ),
        ),
        if (d.warnings.isNotEmpty) ...[
          const SizedBox(height: J3Space.lg),
          StatusBanner(kind: StatusKind.warning, title: 'Warnings', details: d.warnings),
        ],
        const SizedBox(height: J3Space.lg),
        ResultPanel(text: d.headerJson, title: 'Header', kicker: 'JSON', fileName: 'jwt-header.json', toolId: _k),
        if (d.payloadJson != null) ...[
          const SizedBox(height: J3Space.lg),
          ResultPanel(
            key: const Key('dev.jwt.payload'),
            text: d.payloadJson!,
            title: 'Payload (claims)',
            kicker: 'JSON',
            fileName: 'jwt-payload.json',
            toolId: _k,
          ),
        ],
      ],
    );
  }
}
