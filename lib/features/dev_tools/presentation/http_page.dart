import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/activity/activity_controller.dart';
import '../../../core/drafts/drafts.dart';
import '../../../core/platform/capabilities.dart';
import '../../../core/theme/effects.dart';
import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/text_codec.dart';
import '../../../core/widgets/widgets.dart';
import '../data/http_history_store.dart';
import '../domain/common.dart';
import '../domain/http_history.dart';
import '../domain/http_models.dart';
import 'dev_widgets.dart';
import 'http_controller.dart';

class HttpPage extends ConsumerStatefulWidget {
  const HttpPage({super.key});
  static const id = httpToolId;

  /// Response bodies are displayed up to this size; "Save full body" writes
  /// everything that was received.
  static const int displayCap = 2 * 1024 * 1024;

  @override
  ConsumerState<HttpPage> createState() => _HttpPageState();
}

class _HttpPageState extends ConsumerState<HttpPage> {
  late final TextEditingController _url = ref.read(draftTextProvider(httpUrlKey));
  late final TextEditingController _body = ref.read(draftTextProvider(httpBodyKey));
  late final TextEditingController _timeout = ref.read(draftTextProvider(httpTimeoutKey));
  List<String> _formErrors = const [];

  @override
  void initState() {
    super.initState();
    if (_timeout.text.isEmpty) _timeout.text = '20';
  }

  void _send() {
    final session = ref.read(httpSessionProvider.notifier);
    if (session.isRunning) return;
    final draft = ref.read(httpDraftProvider);
    final check = buildHttpRequest(draft: draft, url: _url.text, body: _body.text, timeoutText: _timeout.text);
    if (check.spec == null) {
      setState(() => _formErrors = [if (check.urlError != null) 'URL: ${check.urlError}', ...check.errors]);
      return;
    }
    setState(() => _formErrors = const []);
    session.send(check.spec!, rawUrl: _url.text, headers: draft.headers, body: _body.text, bodyMode: draft.bodyMode);
  }

  void _formatJson() {
    try {
      _body.text = HttpValidation.formatJson(_body.text);
    } on InputError catch (e) {
      ref.read(activityProvider.notifier).notify(NoticeKind.error, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(httpDraftProvider);
    final session = ref.watch(httpSessionProvider);
    final caps = ref.watch(capabilitiesProvider);
    final draftCtl = ref.read(httpDraftProvider.notifier);

    final request = NeonPanel(
      kicker: 'REQUEST',
      title: 'Method and URL',
      icon: Icons.http,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, c) {
              final method = SizedBox(
                width: c.maxWidth < 520 ? double.infinity : 150,
                // Keyed by the value so loading a request from history updates it.
                child: KeyedSubtree(
                  key: ValueKey(draft.method),
                  child: DropdownButtonFormField<HttpMethod>(
                    key: const Key('dev.http.method'),
                    initialValue: draft.method,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Method'),
                    style: J3Type.code.copyWith(fontWeight: FontWeight.w700),
                    items: [for (final m in HttpMethod.values) DropdownMenuItem(value: m, child: Text(m.verb))],
                    onChanged: (m) => m == null ? null : draftCtl.setMethod(m),
                  ),
                ),
              );
              final url = ListenableBuilder(
                listenable: _url,
                builder: (context, _) {
                  final check = _url.text.trim().isEmpty ? null : HttpValidation.checkUrl(_url.text);
                  return TextField(
                    key: const Key('dev.http.url'),
                    controller: _url,
                    style: J3Type.code,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.url,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      labelText: 'URL (http:// or https://)',
                      hintText: 'http://192.168.1.23:8080/api/status',
                      errorText: check?.error?.toString(),
                      errorMaxLines: 4,
                    ),
                  );
                },
              );
              if (c.maxWidth < 520) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    method,
                    const SizedBox(height: J3Space.md),
                    url,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  method,
                  const SizedBox(width: J3Space.md),
                  Expanded(child: url),
                ],
              );
            },
          ),
          ListenableBuilder(
            listenable: _url,
            builder: (context, _) {
              if (_url.text.trim().isEmpty) return const SizedBox.shrink();
              final check = HttpValidation.checkUrl(_url.text);
              if (!check.ok) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final w in check.warnings) ...[
                    const SizedBox(height: J3Space.md),
                    StatusBanner(
                      kind: StatusKind.warning,
                      title: w.startsWith('Cleartext') ? 'Cleartext HTTP' : 'Check the address',
                      message: w,
                    ),
                  ],
                  if (_url.text.contains(HttpRedaction.redacted)) ...[
                    const SizedBox(height: J3Space.md),
                    const StatusBanner(
                      kind: StatusKind.warning,
                      title: 'Redacted values',
                      message:
                          'This URL came from history and still contains REDACTED placeholders. Replace them with '
                          'the real values before sending.',
                    ),
                  ],
                  if (check.loopback && caps.platform.isMobile) ...[
                    const SizedBox(height: J3Space.md),
                    const StatusBanner(
                      kind: StatusKind.info,
                      title: 'localhost is this phone',
                      message:
                          'On a phone, localhost/127.0.0.1 means the phone itself, not your computer. '
                          'See "Phone localhost vs your computer" below.',
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );

    final headersPanel = NeonPanel(
      kicker: 'HEADERS',
      title: '${draft.headers.where((h) => h.enabled && !h.isBlank).length} enabled',
      icon: Icons.list_alt,
      actions: [
        PopupMenuButton<(String, String)>(
          tooltip: 'Add a common header',
          icon: const Icon(Icons.playlist_add, size: 20),
          onSelected: (h) => draftCtl.addHeader(name: h.$1, value: h.$2),
          itemBuilder: (context) => [
            for (final h in const [
              ('Accept', 'application/json'),
              ('Content-Type', 'application/json'),
              ('Authorization', 'Bearer '),
              ('User-Agent', 'J3NSONTOP-Multitool'),
              ('Cache-Control', 'no-cache'),
            ])
              PopupMenuItem(
                value: h,
                child: Text('${h.$1}: ${h.$2}', style: J3Type.code),
              ),
          ],
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final h in draft.headers)
            Padding(
              padding: const EdgeInsets.only(bottom: J3Space.sm),
              child: HeaderRowEditor(key: ValueKey('header-${h.id}'), entry: h),
            ),
          ActionWrap(
            children: [
              NeonButton.secondary(
                label: 'Add header',
                icon: Icons.add,
                dense: true,
                onPressed: () => draftCtl.addHeader(),
              ),
            ],
          ),
          const HelpText(
            'Authorization, Cookie, X-Api-Key and names containing token/secret/password/api-key/session are '
            'treated as sensitive: masked here and never stored in history.',
          ),
        ],
      ),
    );

    final bodyPanel = draft.method.allowsBody
        ? NeonPanel(
            kicker: 'BODY',
            title: 'Request body',
            icon: Icons.data_object,
            actions: [InputActions(controller: _body, what: 'body')],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ChoiceRow<BodyMode>(
                  label: 'Type',
                  options: BodyMode.values,
                  selected: draft.bodyMode,
                  labelOf: (m) => m.label,
                  onSelected: draftCtl.setBodyMode,
                ),
                const SizedBox(height: J3Space.md),
                ListenableBuilder(
                  listenable: _body,
                  builder: (context, _) {
                    String? error;
                    if (draft.bodyMode == BodyMode.json && _body.text.trim().isNotEmpty) {
                      try {
                        HttpValidation.checkJson(_body.text);
                      } on InputError catch (e) {
                        error = e.toString();
                      }
                    }
                    return CodeField(
                      key: const Key('dev.http.body'),
                      controller: _body,
                      minLines: 4,
                      maxLines: 14,
                      errorText: error,
                      hint: draft.bodyMode == BodyMode.json ? '{"name": "j3", "level": 9000}' : 'plain text',
                    );
                  },
                ),
                const SizedBox(height: J3Space.sm),
                ActionWrap(
                  children: [
                    if (draft.bodyMode == BodyMode.json)
                      NeonButton.ghost(label: 'Format JSON', icon: Icons.auto_fix_high, onPressed: _formatJson),
                  ],
                ),
                HelpText(
                  'Content-Type is set to ${draft.bodyMode == BodyMode.json ? 'application/json' : 'text/plain'}; '
                  'charset=utf-8 unless you add your own header.',
                ),
              ],
            ),
          )
        : NeonPanel(
            kicker: 'BODY',
            title: 'No body for ${draft.method.verb}',
            brackets: false,
            emphasis: PanelEmphasis.subtle,
            child: const Text('GET and HEAD requests are sent without a body.', style: J3Type.caption),
          );

    final sendPanel = NeonPanel(
      kicker: 'SEND',
      title: 'Options',
      icon: Icons.send,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NumberField(
            key: const Key('dev.http.timeout'),
            controller: _timeout,
            label: 'Timeout (s, 1-120)',
            min: 1,
            max: 120,
            width: 180,
          ),
          DevSwitch(
            label: 'Follow redirects',
            description: 'Up to 5 hops; the final URL is shown with the response.',
            value: draft.followRedirects,
            onChanged: draftCtl.setFollowRedirects,
          ),
          const SizedBox(height: J3Space.sm),
          if (_formErrors.isNotEmpty) ...[
            StatusBanner(kind: StatusKind.error, title: 'Fix the request first', details: _formErrors),
            const SizedBox(height: J3Space.md),
          ],
          ActionWrap(
            children: [
              NeonButton(
                key: const Key('dev.http.send'),
                label: 'Send',
                icon: Icons.send_rounded,
                busy: session.running,
                tooltip: 'Send request (Ctrl+Enter)',
                onPressed: _send,
              ),
              if (session.running)
                NeonButton.danger(
                  key: const Key('dev.http.cancel'),
                  label: 'Cancel',
                  icon: Icons.stop_circle_outlined,
                  tooltip: 'Abort the request and close the connection',
                  onPressed: () => ref.read(httpSessionProvider.notifier).cancel(),
                ),
            ],
          ),
          const HelpText('TLS certificates are always verified. Requests go only to the URL you enter.'),
        ],
      ),
    );

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): _send},
      child: ToolScaffold(
        toolId: HttpPage.id,
        inputs: [
          request,
          headersPanel,
          bodyPanel,
          sendPanel,
          LocalhostGuide(platform: caps.platform),
        ],
        results: [_responseArea(session), const HttpHistoryPanel()],
      ),
    );
  }

  Widget _responseArea(HttpSessionState s) {
    if (s.running) {
      return NeonPanel(
        kicker: 'RESPONSE',
        title: 'Waiting for ${s.target ?? 'server'}',
        child: LoadingState(
          label: 'Request in flight. It stops at the timeout or when you cancel.',
          onCancel: () => ref.read(httpSessionProvider.notifier).cancel(),
        ),
      );
    }
    if (s.failure != null) {
      final f = s.failure!;
      return StatusBanner(
        kind: f.kind == HttpFailureKind.cancelled ? StatusKind.info : StatusKind.error,
        title: switch (f.kind) {
          HttpFailureKind.timeout => 'Timed out',
          HttpFailureKind.cancelled => 'Cancelled',
          HttpFailureKind.connection => 'Could not connect',
          HttpFailureKind.tls => 'TLS / certificate problem',
          HttpFailureKind.protocol => 'Request failed',
          HttpFailureKind.invalidRequest => 'Invalid request',
        },
        message: '${s.target ?? ''}\n${f.message}'.trim(),
        details: [?f.hint],
      );
    }
    final r = s.response;
    if (r == null) {
      return const EmptyState(
        title: 'No response yet',
        message: 'Enter a URL and press Send. Nothing is sent until you do.',
        glyph: '[ 0x00 ]',
      );
    }
    return ResponseView(key: ObjectKey(r), response: r, prettyJson: s.prettyJson, jsonError: s.jsonError);
  }
}

/// One editable header row: enable toggle, name, value (masked when
/// sensitive, with reveal) and delete.
class HeaderRowEditor extends ConsumerStatefulWidget {
  const HeaderRowEditor({super.key, required this.entry});
  final HeaderEntry entry;

  @override
  ConsumerState<HeaderRowEditor> createState() => _HeaderRowEditorState();
}

class _HeaderRowEditorState extends ConsumerState<HeaderRowEditor> {
  late final _name = TextEditingController(text: widget.entry.name);
  late final _value = TextEditingController(text: widget.entry.value);
  bool _revealed = false;

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final ctl = ref.read(httpDraftProvider.notifier);
    final sensitive = e.isSensitive;
    final error = HttpValidation.headerError(e.name, e.value);
    return Container(
      padding: const EdgeInsets.all(J3Space.sm),
      decoration: BoxDecoration(
        color: e.enabled ? J3Colors.surfaceRaised : J3Colors.surface,
        borderRadius: J3Radius.medium,
        border: Border.all(color: error != null ? J3Colors.error : J3Colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Tooltip(
                message: e.enabled ? 'Enabled (sent)' : 'Disabled (not sent)',
                child: Checkbox(
                  value: e.enabled,
                  onChanged: (v) => ctl.updateHeader(e.id, enabled: v ?? false),
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _name,
                  style: J3Type.code,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Name', hintText: 'X-Custom-Header'),
                  onChanged: (v) => ctl.updateHeader(e.id, name: v),
                ),
              ),
              IconButton(
                tooltip: 'Remove header',
                onPressed: () => ctl.removeHeader(e.id),
                icon: const Icon(Icons.delete_outline, size: 20),
              ),
            ],
          ),
          const SizedBox(height: J3Space.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _value,
                  style: J3Type.code,
                  autocorrect: false,
                  enableSuggestions: false,
                  obscureText: sensitive && !_revealed,
                  obscuringCharacter: '•',
                  decoration: InputDecoration(
                    labelText: e.needsReentry ? 'Value (re-enter: redacted in history)' : 'Value',
                    errorText: error,
                    errorMaxLines: 3,
                  ),
                  onChanged: (v) => ctl.updateHeader(e.id, value: v),
                ),
              ),
              if (sensitive)
                IconButton(
                  tooltip: _revealed ? 'Hide value' : 'Reveal value',
                  onPressed: () => setState(() => _revealed = !_revealed),
                  icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility, size: 20),
                ),
            ],
          ),
          if (sensitive || e.needsReentry) ...[
            const SizedBox(height: J3Space.xs),
            Wrap(
              spacing: J3Space.sm,
              runSpacing: J3Space.xs,
              children: [
                if (sensitive)
                  const StatusBadge(kind: StatusKind.warning, text: 'SENSITIVE - masked, never saved', dense: true),
                if (e.needsReentry) const StatusBadge(kind: StatusKind.error, text: 'VALUE REQUIRED', dense: true),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

enum _BodyView { pretty, text, hex }

/// Status, timing, headers and body of a response.
class ResponseView extends ConsumerStatefulWidget {
  const ResponseView({super.key, required this.response, this.prettyJson, this.jsonError});
  final HttpResponseData response;
  final String? prettyJson;
  final String? jsonError;

  @override
  ConsumerState<ResponseView> createState() => _ResponseViewState();
}

class _ResponseViewState extends ConsumerState<ResponseView> {
  late _BodyView _view = widget.prettyJson != null ? _BodyView.pretty : (_binary ? _BodyView.hex : _BodyView.text);
  final Set<String> _revealed = {};
  late final bool _binary = _looksBinary();
  String? _decoded;

  HttpResponseData get r => widget.response;

  bool _looksBinary() {
    final ct = (r.contentType ?? '').toLowerCase();
    if (ct.startsWith('image/') || ct.startsWith('audio/') || ct.startsWith('video/') || ct.contains('octet-stream')) {
      return true;
    }
    if (ct.startsWith('text/') || ct.contains('json') || ct.contains('xml') || ct.contains('javascript')) return false;
    return TextCodec.looksBinary(r.body);
  }

  String get _text {
    if (_decoded != null) return _decoded!;
    final shown = r.body.length > HttpPage.displayCap ? r.body.sublist(0, HttpPage.displayCap) : r.body;
    final ct = (r.contentType ?? '').toLowerCase();
    _decoded = ct.contains('iso-8859-1') || ct.contains('latin1')
        ? latin1.decode(shown)
        : utf8.decode(shown, allowMalformed: true);
    return _decoded!;
  }

  StatusKind get _statusKind => switch (r.statusClass) {
    HttpStatusClass.success => StatusKind.success,
    HttpStatusClass.redirect || HttpStatusClass.informational => StatusKind.info,
    HttpStatusClass.clientError => StatusKind.warning,
    HttpStatusClass.serverError || HttpStatusClass.unknown => StatusKind.error,
  };

  String _suggestedName() {
    final ct = (r.contentType ?? '').toLowerCase();
    final seg = r.finalUrl.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    if (seg != null && seg.contains('.')) return seg;
    final ext = ct.contains('json')
        ? 'json'
        : ct.contains('html')
        ? 'html'
        : ct.contains('xml')
        ? 'xml'
        : ct.startsWith('text/')
        ? 'txt'
        : sniffFileType(r.body)?.extension ?? 'bin';
    return 'response.$ext';
  }

  Future<void> _saveBody() => saveOutput(
    context,
    ref,
    suggestedName: _suggestedName(),
    bytes: r.body,
    mimeType: r.contentType?.split(';').first.trim() ?? 'application/octet-stream',
    toolId: HttpPage.id,
  );

  @override
  Widget build(BuildContext context) {
    final capped = r.body.length > HttpPage.displayCap;
    final views = [if (widget.prettyJson != null) _BodyView.pretty, if (!_binary) _BodyView.text, _BodyView.hex];
    final view = views.contains(_view) ? _view : views.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeonPanel(
          kicker: 'RESPONSE',
          title: '${r.method.verb} ${r.requestUrl.host}${r.requestUrl.path}',
          emphasis: r.statusClass == HttpStatusClass.success ? PanelEmphasis.success : PanelEmphasis.normal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ActionWrap(
                children: [
                  StatusBadge(
                    key: const Key('dev.http.status'),
                    kind: _statusKind,
                    text: '${r.statusCode} ${r.reasonPhrase}'.trim(),
                  ),
                  Text(r.statusClass.label, style: J3Type.caption),
                ],
              ),
              const SizedBox(height: J3Space.sm),
              StatGrid(
                tiles: [
                  StatTile(label: 'Total time', value: Fmt.duration(r.elapsed)),
                  StatTile(label: 'Headers after', value: Fmt.duration(r.timeToHeaders)),
                  StatTile(label: 'Body size', value: Fmt.bytes(r.body.length), hint: '${r.body.length} bytes'),
                ],
              ),
              if (r.redirected) ValueRow(label: 'Final URL (redirected)', value: r.finalUrl.toString()),
              if (r.contentType != null) ValueRow(label: 'Content-Type', value: r.contentType!),
              if (r.bodyCapped)
                const StatusLine(
                  kind: StatusKind.warning,
                  text: 'The body exceeded the 64 MiB safety limit; reading stopped there.',
                ),
            ],
          ),
        ),
        const SizedBox(height: J3Space.lg),
        NeonPanel(
          kicker: 'BODY',
          title: r.body.isEmpty ? 'Empty body' : 'Body (${Fmt.bytes(r.body.length)})',
          actions: [
            IconButton(
              tooltip: 'Copy body text',
              onPressed: r.body.isEmpty || _binary
                  ? null
                  : () => copyToClipboard(ref, view == _BodyView.pretty ? widget.prettyJson! : _text, what: 'body'),
              icon: const Icon(Icons.copy_rounded, size: 18),
            ),
            IconButton(
              tooltip: 'Save full body',
              onPressed: r.body.isEmpty ? null : _saveBody,
              icon: const Icon(Icons.save_alt_rounded, size: 18),
            ),
          ],
          child: r.body.isEmpty
              ? Text(
                  r.method == HttpMethod.head ? 'HEAD responses have no body.' : '(no content)',
                  style: J3Type.caption,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ChoiceRow<_BodyView>(
                      label: 'View',
                      options: views,
                      selected: view,
                      labelOf: (v) => switch (v) {
                        _BodyView.pretty => 'Pretty JSON',
                        _BodyView.text => 'Text',
                        _BodyView.hex => 'Hex',
                      },
                      onSelected: (v) => setState(() => _view = v),
                    ),
                    if (widget.jsonError != null) ...[
                      const SizedBox(height: J3Space.sm),
                      StatusLine(kind: StatusKind.warning, text: widget.jsonError!),
                    ],
                    const SizedBox(height: J3Space.sm),
                    switch (view) {
                      _BodyView.pretty => LargeTextView(
                        key: const Key('dev.http.body.pretty'),
                        text: widget.prettyJson!,
                      ),
                      _BodyView.text => LargeTextView(key: const Key('dev.http.body.text'), text: _text),
                      _BodyView.hex => HexPreview(bytes: r.body, maxBytes: 4096),
                    },
                    if (capped && view != _BodyView.hex)
                      HelpText(
                        'Showing the first ${Fmt.bytes(HttpPage.displayCap)} of ${Fmt.bytes(r.body.length)}. '
                        'Use "Save full body" for everything.',
                      ),
                    if (_binary)
                      HelpText(
                        'Binary content${sniffFileType(r.body) == null ? '' : ' (${sniffFileType(r.body)!.label})'}: '
                        'save it to open it in another app.',
                      ),
                  ],
                ),
        ),
        const SizedBox(height: J3Space.lg),
        NeonPanel(
          kicker: 'HEADERS',
          title: '${r.headers.length} response header${r.headers.length == 1 ? '' : 's'}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (name, value) in r.headers)
                Builder(
                  builder: (context) {
                    final sensitive = HttpRedaction.isSensitiveHeader(name);
                    final shown = !sensitive || _revealed.contains(name);
                    return ValueRow(
                      label: name,
                      value: shown ? value : HttpRedaction.mask,
                      copyable: shown,
                      badge: sensitive
                          ? const StatusBadge(kind: StatusKind.warning, text: 'SENSITIVE', dense: true)
                          : null,
                      trailing: sensitive
                          ? IconButton(
                              tooltip: shown ? 'Hide $name' : 'Reveal $name',
                              onPressed: () => setState(() => shown ? _revealed.remove(name) : _revealed.add(name)),
                              icon: Icon(shown ? Icons.visibility_off : Icons.visibility, size: 18),
                            )
                          : null,
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Last 50 requests (redacted), replay, export and clear.
class HttpHistoryPanel extends ConsumerWidget {
  const HttpHistoryPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(httpHistoryProvider);
    final running = ref.watch(httpSessionProvider.select((s) => s.running));
    return NeonPanel(
      kicker: 'HISTORY',
      title: items.isEmpty ? 'No requests yet' : 'Last ${items.length} request${items.length == 1 ? '' : 's'}',
      icon: Icons.history,
      actions: [
        IconButton(
          tooltip: 'Export redacted log',
          onPressed: items.isEmpty
              ? null
              : () => saveOutput(
                  context,
                  ref,
                  suggestedName: 'http-log-${Fmt.stamp(DateTime.now())}.txt',
                  bytes: Uint8List.fromList(utf8.encode(exportHistoryLog(items))),
                  mimeType: 'text/plain',
                  toolId: HttpPage.id,
                ),
          icon: const Icon(Icons.ios_share, size: 18),
        ),
        IconButton(
          tooltip: 'Clear history',
          onPressed: items.isEmpty
              ? null
              : () async {
                  final ok = await showJ3Confirm(
                    context,
                    title: 'Clear request history?',
                    message: 'Removes all ${items.length} saved requests from this device.',
                    confirmLabel: 'Clear',
                    destructive: true,
                  );
                  if (ok) await ref.read(httpHistoryStoreProvider).clear();
                },
          icon: const Icon(Icons.delete_sweep_outlined, size: 18),
        ),
      ],
      child: items.isEmpty
          ? const Text(
              'Sent requests appear here with secrets redacted. Tap one to load it again.',
              style: J3Type.caption,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final e in items)
                  _HistoryTile(
                    entry: e,
                    onReplay: running
                        ? null
                        : () {
                            final redacted = replayHistoryEntry(ref, e);
                            ref
                                .read(activityProvider.notifier)
                                .notify(
                                  redacted > 0 ? NoticeKind.warning : NoticeKind.info,
                                  redacted > 0
                                      ? 'Loaded ${e.method.verb} request. Re-enter $redacted redacted value(s) before sending.'
                                      : 'Loaded ${e.method.verb} request from history.',
                                );
                          },
                    onRemove: () => ref.read(httpHistoryStoreProvider).remove(e.id),
                  ),
              ],
            ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.entry, required this.onReplay, required this.onRemove});
  final HttpHistoryEntry entry;
  final VoidCallback? onReplay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final status = e.status;
    final kind = status == null
        ? StatusKind.error
        : switch (HttpStatusClass.of(status)) {
            HttpStatusClass.success => StatusKind.success,
            HttpStatusClass.clientError => StatusKind.warning,
            HttpStatusClass.serverError || HttpStatusClass.unknown => StatusKind.error,
            _ => StatusKind.info,
          };
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: J3Space.sm,
          runSpacing: J3Space.xxs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              e.method.verb,
              style: J3Type.code.copyWith(fontWeight: FontWeight.w700, color: context.effects.accentText),
            ),
            StatusBadge(
              kind: kind,
              dense: true,
              text: status == null ? 'ERROR' : '$status${e.reason == null ? '' : ' ${e.reason}'}',
            ),
            Text(
              [
                Fmt.time(e.time),
                if (e.elapsedMs != null) '${e.elapsedMs} ms',
                if (e.size != null) Fmt.bytes(e.size!),
              ].join('  |  '),
              style: J3Type.caption,
            ),
          ],
        ),
        Text(e.url, style: J3Type.codeSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
        if (e.status == null && e.error != null)
          Text(e.error!, style: J3Type.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: J3Space.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Tooltip(
              message: 'Load into the editor',
              // Own Material so the ink shows above the panel background.
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: onReplay,
                  borderRadius: J3Radius.small,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Padding(padding: const EdgeInsets.all(J3Space.xs), child: summary),
                  ),
                ),
              ),
            ),
          ),
          IconButton(tooltip: 'Remove from history', onPressed: onRemove, icon: const Icon(Icons.close, size: 18)),
        ],
      ),
    );
  }
}

/// Explains why `localhost` on a phone is not the development computer.
class LocalhostGuide extends ConsumerWidget {
  const LocalhostGuide({super.key, required this.platform});
  final AppPlatform platform;

  static const List<(String, String)> points = [
    (
      'Phone or tablet',
      'localhost and 127.0.0.1 are the device itself. A server on your computer is not reachable that way.',
    ),
    ('Android emulator', 'Use 10.0.2.2 to reach the host computer (e.g. http://10.0.2.2:8080/).'),
    ('iOS simulator', "The simulator shares the Mac's network, so localhost works there."),
    (
      'Physical device',
      "Use the computer's LAN IP (e.g. http://192.168.1.23:8080/). Bind the server to 0.0.0.0 instead of "
          '127.0.0.1, allow the port in the firewall and keep both devices on the same Wi-Fi.',
    ),
    ('iOS permission', 'iOS may ask for Local Network access the first time; allow it or LAN requests fail.'),
    ('Cleartext', 'Use http:// only for such development servers. Real services should use https://.'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.draft<bool>('${HttpPage.id}/guideOpen', false);
    final lead = switch (platform) {
      AppPlatform.android =>
        'You are on Android: localhost is this device. Emulator -> 10.0.2.2, real phone -> LAN IP.',
      AppPlatform.ios => 'You are on iOS: localhost is this device (or the Mac, in the simulator).',
      _ => 'You are on a computer: localhost is this machine. A phone needs this computer\'s LAN IP.',
    };
    return NeonPanel(
      kicker: 'GUIDE',
      title: 'Phone localhost vs your computer',
      icon: Icons.devices_other,
      emphasis: PanelEmphasis.subtle,
      brackets: false,
      actions: [
        IconButton(
          key: const Key('dev.http.guide'),
          tooltip: open ? 'Hide guide' : 'Show guide',
          onPressed: () => ref.setDraft('${HttpPage.id}/guideOpen', !open),
          icon: Icon(open ? Icons.expand_less : Icons.expand_more),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(lead, style: J3Type.bodySecondary),
          if (open) ...[
            const SizedBox(height: J3Space.sm),
            for (final (title, text) in points)
              Padding(
                padding: const EdgeInsets.only(bottom: J3Space.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('> $title', style: J3Type.label.copyWith(color: context.effects.accentText)),
                    Text(text, style: J3Type.bodySecondary),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
