import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/activity/activity_controller.dart';
import '../../../core/drafts/drafts.dart';
import '../../../core/tasks/cancellation.dart';
import '../data/http_history_store.dart';
import '../domain/common.dart';
import '../domain/http_history.dart';
import '../domain/http_models.dart';
import '../domain/http_service.dart';

const String httpToolId = 'dev.http';

/// The request service. Tests may override it.
final httpRequestServiceProvider = Provider<HttpRequestService>((ref) => const HttpRequestService());

/// Editable request (URL, body and timeout text live in draft controllers).
class HttpDraft {
  const HttpDraft({
    this.method = HttpMethod.get,
    this.headers = const [HeaderEntry(id: 1, name: 'Accept', value: '*/*')],
    this.bodyMode = BodyMode.json,
    this.followRedirects = true,
    this.nextId = 2,
  });

  final HttpMethod method;
  final List<HeaderEntry> headers;
  final BodyMode bodyMode;
  final bool followRedirects;
  final int nextId;

  HttpDraft copyWith({
    HttpMethod? method,
    List<HeaderEntry>? headers,
    BodyMode? bodyMode,
    bool? followRedirects,
    int? nextId,
  }) => HttpDraft(
    method: method ?? this.method,
    headers: headers ?? this.headers,
    bodyMode: bodyMode ?? this.bodyMode,
    followRedirects: followRedirects ?? this.followRedirects,
    nextId: nextId ?? this.nextId,
  );
}

class HttpDraftController extends Notifier<HttpDraft> {
  @override
  HttpDraft build() => const HttpDraft();

  void setMethod(HttpMethod m) => state = state.copyWith(method: m);
  void setBodyMode(BodyMode m) => state = state.copyWith(bodyMode: m);
  void setFollowRedirects(bool v) => state = state.copyWith(followRedirects: v);

  void addHeader({String name = '', String value = ''}) => state = state.copyWith(
    headers: [
      ...state.headers,
      HeaderEntry(id: state.nextId, name: name, value: value),
    ],
    nextId: state.nextId + 1,
  );

  void updateHeader(int id, {String? name, String? value, bool? enabled}) => state = state.copyWith(
    headers: [
      for (final h in state.headers)
        if (h.id == id)
          h.copyWith(
            name: name,
            value: value,
            enabled: enabled,
            needsReentry: value != null && value.isNotEmpty ? false : null,
          )
        else
          h,
    ],
  );

  void removeHeader(int id) => state = state.copyWith(headers: state.headers.where((h) => h.id != id).toList());

  /// Loads a history entry. Redacted values are cleared and flagged so the
  /// user must re-enter them; returns how many need re-entry.
  int loadFromHistory(HttpHistoryEntry e) {
    var id = state.nextId;
    var redacted = 0;
    final headers = <HeaderEntry>[];
    for (final (name, value, enabled) in e.headers) {
      final masked = value == HttpRedaction.mask;
      if (masked) redacted++;
      headers.add(
        HeaderEntry(id: id++, name: name, value: masked ? '' : value, enabled: enabled, needsReentry: masked),
      );
    }
    state = HttpDraft(
      method: e.method,
      headers: headers,
      bodyMode: e.bodyMode,
      followRedirects: state.followRedirects,
      nextId: id,
    );
    return redacted + HttpRedaction.redacted.allMatches(e.url).length;
  }
}

final httpDraftProvider = NotifierProvider<HttpDraftController, HttpDraft>(HttpDraftController.new);

/// Outcome of the last request.
class HttpSessionState {
  const HttpSessionState({
    this.running = false,
    this.target,
    this.response,
    this.failure,
    this.prettyJson,
    this.jsonError,
  });

  final bool running;

  /// "GET host:port" of the running/last request (no query string).
  final String? target;
  final HttpResponseData? response;
  final HttpRequestFailure? failure;

  /// Pretty-printed body when the response is JSON (and small enough).
  final String? prettyJson;
  final String? jsonError;
}

/// Sends requests, tracks them as activity operations and records the
/// redacted history.
class HttpSessionController extends Notifier<HttpSessionState> {
  static const _uuid = Uuid();

  /// Bodies above this size are not pretty-printed.
  static const int prettyLimit = 2 * 1024 * 1024;

  CancellationToken? _token;

  @override
  HttpSessionState build() {
    ref.onDispose(() => _token?.cancel());
    return const HttpSessionState();
  }

  bool get isRunning => state.running;

  void cancel() => _token?.cancel();

  static String _target(HttpMethod m, Uri u) => '${m.verb} ${u.host}${u.hasPort ? ':${u.port}' : ''}${u.path}';

  Future<void> send(
    HttpRequestSpec spec, {
    required String rawUrl,
    required List<HeaderEntry> headers,
    required String? body,
    required BodyMode bodyMode,
  }) async {
    if (state.running) return;
    final token = CancellationToken();
    _token = token;
    final target = _target(spec.method, spec.url);
    state = HttpSessionState(running: true, target: target);
    final op = ref.read(activityProvider.notifier).start(toolId: httpToolId, title: 'HTTP $target', cancellable: true);
    unawaited(op.token.whenCancelled.then((_) => token.cancel()));

    HttpResponseData? response;
    HttpRequestFailure? failure;
    try {
      response = await ref.read(httpRequestServiceProvider).send(spec, token: token);
    } on HttpRequestFailure catch (e) {
      failure = e;
    } catch (e) {
      failure = HttpRequestService.describeError(e, spec.url);
    }
    if (!ref.mounted) return;

    String? pretty;
    String? jsonError;
    if (response != null && response.looksJson && response.body.isNotEmpty && response.body.length <= prettyLimit) {
      final bytes = response.body;
      (pretty, jsonError) = bytes.length > 256 * 1024 ? await prettyJsonInBackground(bytes) : prettyJsonOf(bytes);
      if (!ref.mounted) return;
    }

    state = HttpSessionState(
      target: target,
      response: response,
      failure: failure,
      prettyJson: pretty,
      jsonError: jsonError,
    );
    if (response != null) {
      op.succeed(
        '${response.statusCode} ${response.reasonPhrase} in ${response.elapsed.inMilliseconds} ms',
        counts: {'bytes': response.body.length, 'status': response.statusCode},
        notify: false,
      );
    } else if (failure!.kind == HttpFailureKind.cancelled) {
      op.cancelled();
    } else {
      op.fail(failure.message);
    }

    final entry = HttpHistoryEntry.record(
      id: _uuid.v4(),
      time: DateTime.now(),
      method: spec.method,
      url: rawUrl,
      headers: headers,
      body: spec.method.allowsBody ? body : null,
      bodyMode: bodyMode,
      response: response,
      failure: failure,
    );
    await ref.read(httpHistoryStoreProvider).add(entry);
  }
}

/// [prettyJsonOf] in a background isolate (top-level so the closure only
/// captures [bytes]).
Future<(String?, String?)> prettyJsonInBackground(List<int> bytes) =>
    Isolate.run(() => prettyJsonOf(bytes), debugName: 'j3-json');

/// (pretty text, error) for a JSON body.
(String?, String?) prettyJsonOf(List<int> bytes) {
  try {
    final text = utf8.decode(bytes, allowMalformed: true);
    return (const JsonEncoder.withIndent('  ').convert(jsonDecode(text)), null);
  } on FormatException catch (e) {
    return (null, 'Body is not valid JSON: ${e.message}${e.offset == null ? '' : ' (offset ${e.offset})'}');
  }
}

final httpSessionProvider = NotifierProvider<HttpSessionController, HttpSessionState>(HttpSessionController.new);

/// Validation result for the whole request form.
class HttpFormCheck {
  const HttpFormCheck({this.spec, this.urlError, this.errors = const []});
  final HttpRequestSpec? spec;
  final InputError? urlError;
  final List<String> errors;
}

/// Builds a request from the draft, or explains what is wrong.
HttpFormCheck buildHttpRequest({
  required HttpDraft draft,
  required String url,
  required String body,
  required String timeoutText,
}) {
  final urlCheck = HttpValidation.checkUrl(url);
  final errors = <String>[];
  final headers = <String, String>{};
  final lower = <String, String>{};
  for (var i = 0; i < draft.headers.length; i++) {
    final h = draft.headers[i];
    if (!h.enabled || h.isBlank) continue;
    final name = h.name.trim();
    final err = HttpValidation.headerError(name, h.value);
    if (err != null) {
      errors.add('Header #${i + 1}: $err');
      continue;
    }
    if (h.needsReentry && h.value.isEmpty) {
      errors.add('Header "$name" was redacted in history. Enter its value again or disable the row.');
      continue;
    }
    final key = name.toLowerCase();
    if (lower.containsKey(key)) {
      final orig = lower[key]!;
      headers[orig] = '${headers[orig]}${key == 'cookie' ? '; ' : ', '}${h.value}';
    } else {
      lower[key] = name;
      headers[name] = h.value;
    }
  }
  List<int>? bodyBytes;
  if (draft.method.allowsBody && body.isNotEmpty) {
    if (draft.bodyMode == BodyMode.json) {
      try {
        HttpValidation.checkJson(body);
      } on InputError catch (e) {
        errors.add('Body: $e');
      }
    }
    bodyBytes = utf8.encode(body);
    if (!lower.containsKey('content-type')) {
      headers['Content-Type'] = draft.bodyMode == BodyMode.json
          ? 'application/json; charset=utf-8'
          : 'text/plain; charset=utf-8';
    }
  }
  final t = int.tryParse(timeoutText.trim());
  if (t == null || t < 1 || t > 120) errors.add('Timeout must be a whole number of seconds from 1 to 120.');
  if (!urlCheck.ok || errors.isNotEmpty) {
    return HttpFormCheck(urlError: urlCheck.error, errors: errors);
  }
  return HttpFormCheck(
    spec: HttpRequestSpec(
      method: draft.method,
      url: urlCheck.uri!,
      headers: headers,
      body: bodyBytes,
      timeout: Duration(seconds: t!),
      followRedirects: draft.followRedirects,
    ),
  );
}

/// Keys of the draft text fields.
const String httpUrlKey = '$httpToolId/url';
const String httpBodyKey = '$httpToolId/body';
const String httpTimeoutKey = '$httpToolId/timeout';

/// Fills URL/body drafts and the header draft from a history entry.
int replayHistoryEntry(WidgetRef ref, HttpHistoryEntry e) {
  final n = ref.read(httpDraftProvider.notifier).loadFromHistory(e);
  ref.read(draftTextProvider(httpUrlKey)).text = e.url;
  ref.read(draftTextProvider(httpBodyKey)).text = e.body ?? '';
  return n;
}
