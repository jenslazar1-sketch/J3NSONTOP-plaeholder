import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/http_history.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/http_models.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/http_service.dart';

/// A local echo server: reports what it received as JSON, with a few
/// special paths for timeouts, redirects and large bodies.
class EchoServer {
  late HttpServer server;
  final List<Map<String, Object?>> received = [];

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await utf8.decodeStream(req);
      final headers = <String, String>{};
      req.headers.forEach((k, v) => headers[k] = v.join(','));
      received.add({'method': req.method, 'path': req.uri.toString(), 'headers': headers, 'body': body});
      final res = req.response;
      switch (req.uri.path) {
        case '/slow':
          await Future<void>.delayed(const Duration(seconds: 3));
        case '/redirect':
          await res.redirect(url('/final'));
          return;
        case '/big':
          res.headers.contentType = ContentType.binary;
          res.add(List<int>.filled(300000, 7));
          await res.close();
          return;
        case '/teapot':
          res.statusCode = 418;
          res.reasonPhrase = "I'm a teapot";
      }
      res.headers.contentType = ContentType.json;
      res.headers.add('set-cookie', 'session=abc123; HttpOnly');
      res.write(jsonEncode({'method': req.method, 'path': req.uri.path, 'body': body}));
      await res.close();
    });
  }

  Future<void> stop() => server.close(force: true);
}

void main() {
  group('HttpRequestService against a local server', () {
    final echo = EchoServer();
    const service = HttpRequestService();
    setUpAll(echo.start);
    tearDownAll(echo.stop);

    test('sends method, headers and body; parses status, time and size', () async {
      final body = utf8.encode('{"hello":"world"}');
      final r = await service.send(
        HttpRequestSpec(
          method: HttpMethod.post,
          url: echo.url('/echo?x=1'),
          headers: {'Content-Type': 'application/json', 'X-Mod': 'j3'},
          body: body,
        ),
      );
      final got = echo.received.last;
      expect(got['method'], 'POST');
      expect(got['path'], '/echo?x=1');
      expect((got['headers']! as Map)['x-mod'], 'j3');
      expect((got['headers']! as Map)['content-type'], 'application/json');
      expect(got['body'], '{"hello":"world"}');
      expect(r.statusCode, 200);
      expect(r.reasonPhrase, 'OK');
      expect(r.statusClass, HttpStatusClass.success);
      expect(r.elapsed, greaterThan(Duration.zero));
      expect(r.timeToHeaders, lessThanOrEqualTo(r.elapsed));
      expect(
        r.body.length,
        utf8.encode(jsonEncode({'method': 'POST', 'path': '/echo', 'body': '{"hello":"world"}'})).length,
      );
      expect(r.looksJson, isTrue);
      expect(r.header('set-cookie'), contains('session=abc123'));
    });

    test('non-2xx statuses keep their reason phrase', () async {
      final r = await service.send(
        HttpRequestSpec(method: HttpMethod.get, url: echo.url('/teapot'), headers: const {}),
      );
      expect(r.statusCode, 418);
      expect(r.reasonPhrase, "I'm a teapot");
      expect(r.statusClass, HttpStatusClass.clientError);
    });

    test('HEAD has no body', () async {
      final r = await service.send(HttpRequestSpec(method: HttpMethod.head, url: echo.url('/x'), headers: const {}));
      expect(r.statusCode, 200);
      expect(r.body, isEmpty);
      expect(echo.received.last['method'], 'HEAD');
    });

    test('redirects are followed and reported', () async {
      final r = await service.send(
        HttpRequestSpec(method: HttpMethod.get, url: echo.url('/redirect'), headers: const {}),
      );
      expect(r.statusCode, 200);
      expect(r.redirected, isTrue);
      expect(r.finalUrl.path, '/final');
      final noFollow = await service.send(
        HttpRequestSpec(method: HttpMethod.get, url: echo.url('/redirect'), headers: const {}, followRedirects: false),
      );
      expect(noFollow.statusClass, HttpStatusClass.redirect);
    });

    test('timeout is surfaced as a timeout failure', () async {
      final sw = Stopwatch()..start();
      await expectLater(
        service.send(
          HttpRequestSpec(
            method: HttpMethod.get,
            url: echo.url('/slow'),
            headers: const {},
            timeout: const Duration(seconds: 1),
          ),
        ),
        throwsA(isA<HttpRequestFailure>().having((f) => f.kind, 'kind', HttpFailureKind.timeout)),
      );
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 2800)));
    });

    test('cancellation aborts a pending request', () async {
      final token = CancellationToken();
      final f = service.send(
        HttpRequestSpec(method: HttpMethod.get, url: echo.url('/slow'), headers: const {}),
        token: token,
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      token.cancel();
      await expectLater(f, throwsA(isA<HttpRequestFailure>().having((e) => e.kind, 'kind', HttpFailureKind.cancelled)));
    });

    test('response bodies beyond the hard limit are capped', () async {
      const small = HttpRequestService(maxBodyBytes: 1000);
      final r = await small.send(HttpRequestSpec(method: HttpMethod.get, url: echo.url('/big'), headers: const {}));
      expect(r.bodyCapped, isTrue);
      expect(r.body.length, 1000);
    });

    test('connection refused is a connection failure with a localhost hint', () async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      await expectLater(
        service.send(
          HttpRequestSpec(method: HttpMethod.get, url: Uri.parse('http://127.0.0.1:$port/'), headers: const {}),
        ),
        throwsA(
          isA<HttpRequestFailure>()
              .having((e) => e.kind, 'kind', HttpFailureKind.connection)
              .having((e) => e.hint, 'hint', contains('10.0.2.2')),
        ),
      );
    });
  });

  group('Validation', () {
    test('URL checks', () {
      expect(HttpValidation.checkUrl('https://example.com/api').ok, isTrue);
      final cleartext = HttpValidation.checkUrl('http://192.168.1.23:8080/');
      expect(cleartext.ok, isTrue);
      expect(cleartext.cleartext, isTrue);
      expect(cleartext.warnings.single, contains('development'));
      expect(HttpValidation.checkUrl('http://localhost:3000').loopback, isTrue);
      expect(HttpValidation.checkUrl('example.com/x').error!.message, 'Missing scheme');
      expect(HttpValidation.checkUrl('localhost:8080/x').error!.message, 'Missing scheme');
      expect(HttpValidation.checkUrl('ftp://example.com').error!.message, contains('Only http'));
      final space = HttpValidation.checkUrl('  https://exa mple.com');
      expect(space.error!.offset, 13);
      expect(HttpValidation.checkUrl('https:///path').error, isNotNull);
      expect(HttpValidation.checkUrl('').error, isNotNull);
    });

    test('header validation blocks injection', () {
      expect(HttpValidation.headerError('X-Ok', 'fine'), isNull);
      expect(HttpValidation.headerError('Bad Name', 'x'), contains('header name'));
      expect(HttpValidation.headerError('X-Evil', 'a\r\nInjected: 1'), contains('injection'));
      expect(HttpValidation.headerError('', ''), isNull);
      expect(HttpValidation.headerError('', 'orphan'), contains('empty'));
    });

    test('JSON body validation reports line and column', () {
      expect(HttpValidation.formatJson('{"a":[1,2]}'), '{\n  "a": [\n    1,\n    2\n  ]\n}');
      try {
        HttpValidation.checkJson('{\n  "a": 1,\n  oops\n}');
        fail('expected an error');
      } on Exception catch (e) {
        expect(e.toString(), contains('line 3'));
      }
    });
  });

  group('Redaction', () {
    test('sensitive header names', () {
      for (final n in [
        'Authorization',
        'proxy-authorization',
        'Cookie',
        'Set-Cookie',
        'X-Api-Key',
        'X-Auth-Token',
        'client-secret',
        'X-Password',
        'Api-Key',
        'X-Session-Id',
        'apikey',
      ]) {
        expect(HttpRedaction.isSensitiveHeader(n), isTrue, reason: n);
      }
      for (final n in ['Accept', 'Content-Type', 'User-Agent', 'X-Request-Id']) {
        expect(HttpRedaction.isSensitiveHeader(n), isFalse, reason: n);
      }
    });

    test('URLs: sensitive query values, fragments and user-info', () {
      expect(
        HttpRedaction.redactUrl('https://api.dev/v1?page=2&access_token=abc&api_key=k1&sig=zz&q=x'),
        'https://api.dev/v1?page=2&access_token=REDACTED&api_key=REDACTED&sig=REDACTED&q=x',
      );
      expect(HttpRedaction.redactUrl('https://u:p@host.dev/x'), 'https://REDACTED@host.dev/x');
      expect(
        HttpRedaction.redactUrl('https://h.dev/cb#access_token=abc&state=1'),
        'https://h.dev/cb#access_token=REDACTED&state=1',
      );
      expect(HttpRedaction.redactUrl('https://h.dev/p?Password=hunter2'), 'https://h.dev/p?Password=REDACTED');
      expect(HttpRedaction.redactUrl('https://h.dev/p'), 'https://h.dev/p');
    });

    test('history never persists sensitive values', () {
      final entry = HttpHistoryEntry.record(
        id: '1',
        time: DateTime.utc(2026, 9, 25),
        method: HttpMethod.post,
        url: 'http://127.0.0.1:8080/login?token=SECRET_Q&page=1',
        headers: const [
          HeaderEntry(id: 1, name: 'Authorization', value: 'Bearer SECRET_H'),
          HeaderEntry(id: 2, name: 'Accept', value: 'application/json'),
          HeaderEntry(id: 3, name: 'X-Api-Key', value: 'SECRET_K', enabled: false),
        ],
        body: '{"user":"me"}',
        bodyMode: BodyMode.json,
      );
      final json = jsonEncode(HttpHistoryEntry.encodeList([entry]));
      for (final secret in ['SECRET_Q', 'SECRET_H', 'SECRET_K', '"user"']) {
        expect(json, isNot(contains(secret)), reason: secret);
      }
      expect(entry.url, 'http://127.0.0.1:8080/login?token=REDACTED&page=1');
      expect(entry.headers.first.$2, HttpRedaction.mask);
      expect(entry.headers[1].$2, 'application/json');
      expect(entry.bodyOmitted, contains('sensitive headers'));
      expect(entry.hasRedactions, isTrue);

      final decoded = HttpHistoryEntry.decodeList(jsonDecode(json));
      expect(decoded.single.url, entry.url);
      expect(decoded.single.headers.first.$2, HttpRedaction.mask);
    });

    test('bodies are kept only when harmless', () {
      HttpHistoryEntry rec(String body, [List<HeaderEntry> headers = const []]) => HttpHistoryEntry.record(
        id: 'x',
        time: DateTime.utc(2026),
        method: HttpMethod.post,
        url: 'https://h.dev/',
        headers: headers,
        body: body,
        bodyMode: BodyMode.raw,
      );
      expect(rec('{"level":3}').body, '{"level":3}');
      expect(rec('{"password":"x"}').body, isNull);
      expect(rec('client_secret=abc&x=1').body, isNull);
      expect(rec('x' * 40000).bodyOmitted, contains('KiB'));
      // A disabled sensitive header was not sent, so the body may be kept.
      expect(rec('{"a":1}', const [HeaderEntry(id: 1, name: 'Cookie', value: 'c', enabled: false)]).body, '{"a":1}');
    });

    test('stored data is re-redacted on load (defence in depth)', () {
      final doc = {
        'v': 1,
        'items': [
          {
            'id': 'z',
            'time': '2026-09-25T00:00:00Z',
            'method': 'GET',
            'url': 'https://h.dev/?apikey=LEAK',
            'headers': [
              {'name': 'Cookie', 'value': 'LEAK', 'enabled': true},
            ],
          },
          {'broken': true},
        ],
      };
      final items = HttpHistoryEntry.decodeList(doc);
      expect(items.length, 1);
      expect(items.single.url, isNot(contains('LEAK')));
      expect(items.single.headers.single.$2, HttpRedaction.mask);
    });

    test('export log is redacted plain text', () {
      final e = HttpHistoryEntry.record(
        id: '1',
        time: DateTime.utc(2026, 9, 25, 12),
        method: HttpMethod.get,
        url: 'https://h.dev/a?key=TOPSECRET',
        headers: const [HeaderEntry(id: 1, name: 'Cookie', value: 'TOPSECRET2')],
        body: null,
        bodyMode: BodyMode.raw,
        failure: const HttpRequestFailure(HttpFailureKind.timeout, 'Timed out after 20 s'),
      );
      final log = exportHistoryLog([e], now: DateTime.utc(2026, 9, 25, 13));
      expect(log, contains('GET https://h.dev/a?key=REDACTED'));
      expect(log, contains('error: Timed out after 20 s'));
      expect(log, contains('Cookie: ${HttpRedaction.mask}'));
      expect(log, isNot(contains('TOPSECRET')));
    });

    test('history is capped at 50 entries', () {
      final many = List.generate(
        60,
        (i) => HttpHistoryEntry(
          id: '$i',
          time: DateTime.utc(2026),
          method: HttpMethod.get,
          url: 'https://h.dev/$i',
          headers: const [],
        ),
      );
      expect((HttpHistoryEntry.encodeList(many)['items']! as List).length, 50);
    });
  });
}
