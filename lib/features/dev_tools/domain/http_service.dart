import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../../core/tasks/cancellation.dart';
import 'http_models.dart';

/// Creates the HTTP client for one request.
typedef HttpClientFactory = http.Client Function(Duration connectionTimeout);

/// Sends explicitly entered requests with `package:http` over
/// `dart:io`'s HttpClient.
///
/// TLS certificate verification is always on: the tool never installs a
/// certificate override, so self-signed/invalid certificates fail with a
/// clear error instead of being accepted.
class HttpRequestService {
  const HttpRequestService({this.clientFactory = defaultClientFactory, this.maxBodyBytes = defaultMaxBodyBytes});

  final HttpClientFactory clientFactory;

  /// Hard limit on bytes read from a response (memory guard).
  final int maxBodyBytes;

  static const int defaultMaxBodyBytes = 64 * 1024 * 1024;

  static http.Client defaultClientFactory(Duration connectionTimeout) =>
      IOClient(HttpClient()..connectionTimeout = connectionTimeout);

  /// Sends [spec]. The whole exchange (connect, headers and body) must
  /// finish within [HttpRequestSpec.timeout]. Cancelling [token] aborts the
  /// request and closes the client.
  ///
  /// Throws [HttpRequestFailure].
  Future<HttpResponseData> send(HttpRequestSpec spec, {CancellationToken? token}) async {
    final client = clientFactory(spec.timeout);
    final abort = Completer<void>();
    var timedOut = false;
    var cancelled = false;
    void stop() {
      if (!abort.isCompleted) abort.complete();
      client.close();
    }

    final request = http.AbortableRequest(spec.method.verb, spec.url, abortTrigger: abort.future)
      ..followRedirects = spec.followRedirects
      ..maxRedirects = 5
      ..persistentConnection = false;
    request.headers.addAll(spec.headers);
    if (spec.body != null) request.bodyBytes = spec.body!;

    final timer = Timer(spec.timeout, () {
      timedOut = true;
      stop();
    });
    if (token != null) {
      if (token.isCancelled) {
        timer.cancel();
        client.close();
        throw const HttpRequestFailure(HttpFailureKind.cancelled, 'Cancelled before sending');
      }
      unawaited(
        token.whenCancelled.then((_) {
          cancelled = true;
          stop();
        }),
      );
    }

    final sw = Stopwatch()..start();
    try {
      final streamed = await client.send(request);
      final ttfb = sw.elapsed;
      final builder = BytesBuilder(copy: false);
      var total = 0;
      var capped = false;
      await for (final chunk in streamed.stream) {
        if (total + chunk.length > maxBodyBytes) {
          final keep = maxBodyBytes - total;
          if (keep > 0) builder.add(chunk.sublist(0, keep));
          total += keep;
          capped = true;
          break;
        }
        builder.add(chunk);
        total += chunk.length;
      }
      sw.stop();
      if (timedOut) throw _timeout(spec.timeout);
      if (cancelled) throw _cancelled();
      final headers = <(String, String)>[for (final e in streamed.headers.entries) (e.key.toLowerCase(), e.value)]
        ..sort((a, b) => a.$1.compareTo(b.$1));
      final finalUrl = switch (streamed) {
        http.BaseResponseWithUrl(:final url) => url,
        _ => spec.url,
      };
      return HttpResponseData(
        method: spec.method,
        requestUrl: spec.url,
        finalUrl: finalUrl,
        statusCode: streamed.statusCode,
        reasonPhrase: streamed.reasonPhrase ?? '',
        headers: headers,
        body: builder.takeBytes(),
        bodyCapped: capped,
        elapsed: sw.elapsed,
        timeToHeaders: ttfb,
        contentLength: streamed.contentLength,
      );
    } on HttpRequestFailure {
      rethrow;
    } catch (e) {
      if (cancelled) throw _cancelled();
      if (timedOut) throw _timeout(spec.timeout);
      throw describeError(e, spec.url);
    } finally {
      timer.cancel();
      client.close();
    }
  }

  static HttpRequestFailure _timeout(Duration t) => HttpRequestFailure(
    HttpFailureKind.timeout,
    'Timed out after ${t.inSeconds} s',
    hint: 'The server did not answer in time. Check the address and port, or raise the timeout.',
  );

  static HttpRequestFailure _cancelled() => const HttpRequestFailure(HttpFailureKind.cancelled, 'Cancelled');

  /// Maps transport exceptions to user-facing failures.
  static HttpRequestFailure describeError(Object e, Uri url) {
    const localHint =
        'On a phone, localhost is the phone itself. Use 10.0.2.2 from the Android emulator, or your '
        "computer's LAN IP (server bound to 0.0.0.0, firewall open, same Wi-Fi) from a real device.";
    if (e is HandshakeException || e is TlsException || (e is http.ClientException && _isTls(e.message))) {
      return HttpRequestFailure(
        HttpFailureKind.tls,
        'TLS/certificate error: ${e is http.ClientException ? e.message : e.toString()}',
        hint:
            'Certificate verification is always enabled. Use a certificate trusted by this device, or plain '
            'http:// for a local development server.',
      );
    }
    if (e is SocketException) {
      return HttpRequestFailure(HttpFailureKind.connection, 'Connection failed: ${e.message}', hint: localHint);
    }
    if (e is http.ClientException) {
      final msg = e.message;
      final lower = msg.toLowerCase();
      if (lower.contains('refused') || lower.contains('failed host lookup') || lower.contains('unreachable')) {
        return HttpRequestFailure(HttpFailureKind.connection, 'Connection failed: $msg', hint: localHint);
      }
      if (lower.contains('redirect')) {
        return HttpRequestFailure(HttpFailureKind.protocol, 'Redirect problem: $msg');
      }
      return HttpRequestFailure(HttpFailureKind.protocol, 'Request failed: $msg');
    }
    if (e is HttpException) return HttpRequestFailure(HttpFailureKind.protocol, 'HTTP error: ${e.message}');
    if (e is ArgumentError || e is FormatException) {
      return HttpRequestFailure(HttpFailureKind.invalidRequest, 'Invalid request: $e');
    }
    return HttpRequestFailure(HttpFailureKind.protocol, 'Request failed: $e');
  }

  static bool _isTls(String m) {
    final l = m.toLowerCase();
    return l.contains('certificate') || l.contains('handshake') || l.contains('tls');
  }
}
