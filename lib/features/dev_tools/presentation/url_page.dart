import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/drafts/drafts.dart';
import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/common.dart';
import '../domain/http_models.dart';
import '../domain/url_tools.dart';
import 'dev_widgets.dart';

enum UrlToolMode {
  encode('Encode'),
  decode('Decode'),
  inspect('Inspect URL');

  const UrlToolMode(this.label);
  final String label;
}

class UrlPage extends ConsumerStatefulWidget {
  const UrlPage({super.key});
  static const id = 'dev.url';

  @override
  ConsumerState<UrlPage> createState() => _UrlPageState();
}

class _UrlPageState extends ConsumerState<UrlPage> {
  static const _k = UrlPage.id;
  final _focus = FocusNode();
  bool _revealUserInfo = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final input = ref.watch(draftTextProvider('$_k/input'));
    final mode = ref.draft<UrlToolMode>('$_k/mode', UrlToolMode.encode);
    final encodeMode = ref.draft<UrlEncodeMode>('$_k/encodeMode', UrlEncodeMode.component);
    final plus = ref.draft<bool>('$_k/plusAsSpace', false);

    final inputs = [
      NeonPanel(
        kicker: 'INPUT',
        title: switch (mode) {
          UrlToolMode.encode => 'Text to percent-encode',
          UrlToolMode.decode => 'Percent-encoded text',
          UrlToolMode.inspect => 'URL to inspect',
        },
        icon: Icons.link,
        actions: [InputActions(controller: input)],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ChoiceRow<UrlToolMode>(
              label: 'Mode',
              options: UrlToolMode.values,
              selected: mode,
              labelOf: (m) => m.label,
              onSelected: (m) => ref.setDraft('$_k/mode', m),
            ),
            const SizedBox(height: J3Space.md),
            CodeField(
              key: const Key('dev.url.input'),
              controller: input,
              focusNode: _focus,
              minLines: mode == UrlToolMode.inspect ? 2 : 4,
              maxLines: 10,
              label: mode == UrlToolMode.inspect ? 'URL' : 'Text',
              hint: switch (mode) {
                UrlToolMode.encode => 'name=J3 & friends/ü',
                UrlToolMode.decode => 'name%3DJ3%20%26%20friends%2F%C3%BC',
                UrlToolMode.inspect => 'https://example.com:8443/api/v1/items?id=42&tag=a+b#details',
              },
            ),
            if (mode == UrlToolMode.encode) ...[
              const MiniHeader('Encoding'),
              ChoiceRow<UrlEncodeMode>(
                label: 'What to keep',
                options: UrlEncodeMode.values,
                selected: encodeMode,
                labelOf: (m) => m.label,
                onSelected: (m) => ref.setDraft('$_k/encodeMode', m),
              ),
              HelpText(encodeMode.description),
            ],
            if (mode == UrlToolMode.decode)
              OptionSwitch(
                label: 'Form decoding (+ means space)',
                description: 'For application/x-www-form-urlencoded data such as query strings.',
                value: plus,
                onChanged: (v) => ref.setDraft('$_k/plusAsSpace', v),
              ),
          ],
        ),
      ),
    ];

    final results = [
      ListenableBuilder(listenable: input, builder: (context, _) => _result(input, mode, encodeMode, plus)),
    ];
    return ToolScaffold(toolId: _k, inputs: inputs, results: results);
  }

  Widget _result(TextEditingController input, UrlToolMode mode, UrlEncodeMode encodeMode, bool plus) {
    final text = input.text;
    if (text.isEmpty) {
      return const EmptyState(title: 'Waiting for input', message: 'Results update as you type.', glyph: '[ %20 ]');
    }
    switch (mode) {
      case UrlToolMode.encode:
        return CappedTextResult(
          text: UrlTools.encode(text, encodeMode),
          title: 'Encoded (${encodeMode.label})',
          fileName: 'encoded-url.txt',
          toolId: _k,
        );
      case UrlToolMode.decode:
        try {
          return CappedTextResult(
            text: UrlTools.decode(text, plusAsSpace: plus),
            title: 'Decoded',
            fileName: 'decoded-url.txt',
            toolId: _k,
          );
        } on InputError catch (e) {
          return InputErrorBanner(error: e, title: 'Cannot decode', controller: input, focusNode: _focus);
        }
      case UrlToolMode.inspect:
        try {
          return _inspection(UrlTools.inspect(text));
        } on InputError catch (e) {
          return InputErrorBanner(error: e, title: 'Not a valid URL', controller: input, focusNode: _focus);
        }
    }
  }

  Widget _inspection(UrlInspection r) {
    final userInfo = r.userInfo;
    final colon = userInfo.indexOf(':');
    final maskedUser = colon < 0 || _revealUserInfo
        ? userInfo
        : '${userInfo.substring(0, colon)}:${HttpRedaction.mask}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (r.warnings.isNotEmpty) ...[
          StatusBanner(kind: StatusKind.warning, title: 'Check this URL', details: r.warnings),
          const SizedBox(height: J3Space.lg),
        ],
        NeonPanel(
          kicker: 'PARTS',
          title: r.origin.isEmpty ? 'Relative reference' : r.origin,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ValueRow(label: 'Scheme', value: r.scheme),
              if (userInfo.isNotEmpty)
                ValueRow(
                  label: 'User info',
                  value: maskedUser,
                  copyable: colon < 0 || _revealUserInfo,
                  trailing: colon < 0
                      ? null
                      : IconButton(
                          tooltip: _revealUserInfo ? 'Hide password' : 'Reveal password',
                          onPressed: () => setState(() => _revealUserInfo = !_revealUserInfo),
                          icon: Icon(_revealUserInfo ? Icons.visibility_off : Icons.visibility, size: 18),
                        ),
                ),
              ValueRow(label: 'Host', value: r.host),
              ValueRow(
                label: 'Port',
                value: r.port == null ? '(none)' : '${r.port}${r.portIsDefault ? ' (default for ${r.scheme})' : ''}',
                copyable: r.port != null,
              ),
              ValueRow(label: 'Path', value: r.path.isEmpty ? '/' : r.path),
              if (r.rawQuery.isNotEmpty) ValueRow(label: 'Raw query', value: r.rawQuery),
              if (r.fragment != null) ValueRow(label: 'Fragment (decoded)', value: r.fragment!),
            ],
          ),
        ),
        if (r.segments.isNotEmpty) ...[
          const SizedBox(height: J3Space.lg),
          NeonPanel(
            kicker: 'PATH',
            title: '${r.segments.length} segment${r.segments.length == 1 ? '' : 's'} (decoded)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (var i = 0; i < r.segments.length; i++) ValueRow(label: '[$i]', value: r.segments[i])],
            ),
          ),
        ],
        const SizedBox(height: J3Space.lg),
        NeonPanel(
          kicker: 'QUERY',
          title: r.query.isEmpty
              ? 'No query parameters'
              : '${r.query.length} parameter${r.query.length == 1 ? '' : 's'}',
          child: r.query.isEmpty
              ? Text('The URL has no ?key=value part.', style: J3Type.caption)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final q in r.query)
                      ValueRow(
                        label: q.name,
                        value: q.value ?? '(flag, no value)',
                        copyable: q.value != null,
                        badge: q.error == null
                            ? null
                            : const StatusBadge(kind: StatusKind.error, text: 'MALFORMED', dense: true),
                        valueStyle: q.error == null ? null : J3Type.code.copyWith(color: J3Colors.error),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
