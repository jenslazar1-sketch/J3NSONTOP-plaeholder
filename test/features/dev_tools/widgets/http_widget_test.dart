import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/core/storage/user_data.dart';
import 'package:j3nsontop_multitool/features/dev_tools/data/http_history_store.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/http_models.dart';
import 'package:j3nsontop_multitool/features/dev_tools/presentation/http_controller.dart';

import '../../../helpers/harness.dart';
import '../dev_test_utils.dart';

/// Echo server for widget tests (bound to 127.0.0.1 on a free port).
class _Server {
  late HttpServer server;
  final List<HttpRequest> requests = [];
  final List<String> bodies = [];

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests.add(req);
      bodies.add(await utf8.decodeStream(req));
      if (req.uri.path == '/slow') await Future<void>.delayed(const Duration(seconds: 4));
      req.response.headers.contentType = ContentType.json;
      req.response.headers.add('set-cookie', 'sid=SERVER_SECRET');
      req.response.write(
        jsonEncode({
          'ok': true,
          'method': req.method,
          'items': [1, 2],
        }),
      );
      await req.response.close();
    });
  }
}

void main() {
  late TestEnv env;
  final srv = _Server();
  setUpAll(srv.start);
  tearDownAll(() => srv.server.close(force: true));
  // flutter_test installs HttpOverrides that answer every request with a
  // canned 400. These tests talk to the real loopback server above, so they
  // lift that override for their duration.
  HttpOverrides? savedOverrides;
  setUp(() async {
    savedOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    env = await TestEnv.create();
  });
  tearDown(() async {
    HttpOverrides.global = savedOverrides;
    await env.dispose();
  });

  Future<void> send(WidgetTester tester) async {
    await tapVisible(tester, find.byKey(const Key('dev.http.send')));
    final c = containerOf(tester);
    await pumpUntil(tester, () => !c.read(httpSessionProvider).running);
  }

  testWidgets('renders with the localhost guide and no response', (tester) async {
    await pumpDevTool(tester, env, 'dev.http');
    expect(find.text('No response yet'), findsOneWidget);
    expect(find.text('Phone localhost vs your computer'), findsOneWidget);
    await tapVisible(tester, find.byKey(const Key('dev.http.guide')));
    expect(find.textContaining('10.0.2.2'), findsWidgets);
    expect(find.textContaining('0.0.0.0'), findsWidgets);
  });

  testWidgets('sends a GET and shows status, timing, pretty JSON and masked cookies', (tester) async {
    await pumpDevTool(tester, env, 'dev.http');
    await enter(tester, 'dev.http.url', srv.url('/hello?page=1'));
    expect(find.text('WARN // Cleartext HTTP'), findsOneWidget);
    await send(tester);
    expect(
      find.descendant(of: find.byKey(const Key('dev.http.status')), matching: find.text('200 OK')),
      findsOneWidget,
    );
    expect(find.text('Total time'), findsOneWidget);
    expect(find.textContaining('"ok": true'), findsOneWidget);
    expect(find.text('set-cookie'), findsOneWidget);
    expect(find.textContaining('SERVER_SECRET'), findsNothing);
    await tapVisible(tester, find.byTooltip('Reveal set-cookie'));
    expect(find.textContaining('SERVER_SECRET'), findsOneWidget);
    expect(srv.requests.last.method, 'GET');
    expect(srv.requests.last.uri.query, 'page=1');
  });

  testWidgets('POST with JSON body and a sensitive header; history is redacted', (tester) async {
    await pumpDevTool(tester, env, 'dev.http');
    await tester.tap(find.byKey(const Key('dev.http.method')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('POST').last);
    await tester.pumpAndSettle();
    await enter(tester, 'dev.http.url', srv.url('/login?token=QUERY_SECRET&x=1'));
    await enter(tester, 'dev.http.body', '{"level": 9}');
    final draft = containerOf(tester).read(httpDraftProvider.notifier);
    draft.addHeader(name: 'Authorization', value: 'Bearer HEADER_SECRET');
    await tester.pump();

    // The sensitive value is obscured in the editor until revealed.
    final obscured = tester.widgetList<EditableText>(find.byType(EditableText)).where((e) => e.obscureText);
    expect(obscured.single.controller.text, 'Bearer HEADER_SECRET');
    expect(find.textContaining('SENSITIVE'), findsWidgets);

    await send(tester);
    expect(srv.requests.last.method, 'POST');
    expect(srv.requests.last.headers.value('authorization'), 'Bearer HEADER_SECRET');
    expect(srv.requests.last.headers.contentType?.mimeType, 'application/json');
    expect(srv.bodies.last, '{"level": 9}');

    final stored = jsonEncode(containerOf(tester).read(featureDataProvider)[httpHistoryKey]);
    expect(stored, isNot(contains('HEADER_SECRET')));
    expect(stored, isNot(contains('QUERY_SECRET')));
    expect(stored, isNot(contains('level')), reason: 'bodies of requests with sensitive headers are not stored');
    expect(stored, contains('token=REDACTED'));
    expect(stored, contains(HttpRedaction.mask));
    expect(find.textContaining('token=REDACTED'), findsOneWidget);
  });

  testWidgets('replay from history requires re-entering redacted values', (tester) async {
    await pumpDevTool(tester, env, 'dev.http');
    await enter(tester, 'dev.http.url', srv.url('/r'));
    containerOf(tester).read(httpDraftProvider.notifier).addHeader(name: 'X-Api-Key', value: 'K_SECRET');
    await tester.pump();
    await send(tester);
    await tapVisible(tester, find.byTooltip('Load into the editor'));
    expect(find.text('VALUE REQUIRED'), findsOneWidget);
    final check = buildHttpRequest(
      draft: containerOf(tester).read(httpDraftProvider),
      url: srv.url('/r'),
      body: '',
      timeoutText: '20',
    );
    expect(check.spec, isNull);
    expect(check.errors.single, contains('X-Api-Key'));
  });

  testWidgets('timeout is surfaced', (tester) async {
    await pumpDevTool(tester, env, 'dev.http');
    await enter(tester, 'dev.http.url', srv.url('/slow'));
    await enter(tester, 'dev.http.timeout', '1');
    await tapVisible(tester, find.byKey(const Key('dev.http.send')));
    expect(find.byKey(const Key('dev.http.cancel')), findsOneWidget);
    final c = containerOf(tester);
    await pumpUntil(tester, () => !c.read(httpSessionProvider).running);
    expect(find.text('Timed out after 1 s'), findsOneWidget);
    expect(c.read(httpHistoryProvider).first.error, 'Timed out after 1 s');
  });

  testWidgets('malformed URL shows an inline error with position and blocks sending', (tester) async {
    await pumpDevTool(tester, env, 'dev.http');
    await enter(tester, 'dev.http.url', 'example.com/api');
    expect(find.textContaining('Missing scheme'), findsOneWidget);
    await enter(tester, 'dev.http.url', 'https://exa mple.com');
    expect(find.textContaining('URLs cannot contain U+0020 SPACE at line 1, column 12'), findsOneWidget);
    await tapVisible(tester, find.byKey(const Key('dev.http.send')));
    expect(find.text('ERROR // Fix the request first'), findsOneWidget);
    expect(containerOf(tester).read(httpHistoryProvider), isEmpty);
  });

  testWidgets('export log is redacted', (tester) async {
    final files = FakeFileAccess();
    await pumpDevTool(tester, env, 'dev.http', files: files);
    await enter(tester, 'dev.http.url', srv.url('/e?api_key=EXPORT_SECRET'));
    await send(tester);
    await tapVisible(tester, find.byTooltip('Export redacted log'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export...'));
    await tester.pumpAndSettle();
    final log = utf8.decode(files.savedBytes.single.$2);
    expect(log, contains('api_key=REDACTED'));
    expect(log, isNot(contains('EXPORT_SECRET')));
  });

  testWidgets('fits a small phone at 2x text', (tester) async {
    await pumpDevTool(tester, env, 'dev.http', size: smallPhone, textScale: 2, platform: AppPlatform.android);
    await enter(tester, 'dev.http.url', 'https://example.com/api');
    await tapVisible(tester, find.byKey(const Key('dev.http.guide')));
    expect(find.textContaining('You are on Android'), findsOneWidget);
  });
}
