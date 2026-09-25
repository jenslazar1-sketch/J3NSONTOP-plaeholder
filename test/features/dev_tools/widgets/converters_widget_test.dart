import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/drafts/drafts.dart';

import '../../../helpers/harness.dart';
import '../dev_test_utils.dart';

String b64url(Object json) => base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  group('UUID tool', () {
    testWidgets('renders, generates and formats', (tester) async {
      final c = await pumpDevTool(tester, env, 'dev.uuid');
      expect(find.text('No UUIDs yet'), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('dev.uuid.generate')));
      final ids = c.read(draftValueProvider('dev.uuid/generated')) as List<String>;
      expect(ids.length, 5);
      expect(find.text('5 x v4 random'), findsOneWidget);
      await tapVisible(tester, find.text('Uppercase'));
      expect(find.textContaining(ids.first.toUpperCase()), findsOneWidget);
    });

    testWidgets('v7 batch inspects to the fixed clock time', (tester) async {
      await pumpDevTool(tester, env, 'dev.uuid');
      await tapVisible(tester, find.text('v7 time-ordered'));
      await enter(tester, 'dev.uuid.count', '3');
      await tapVisible(tester, find.byKey(const Key('dev.uuid.generate')));
      await tapVisible(tester, find.byTooltip('Inspect the first UUID'));
      expect(find.text('v7 - Unix epoch time-ordered'), findsOneWidget);
      expect(find.text('2026-09-25T19:41:07.123Z'), findsOneWidget);
    });

    testWidgets('invalid count and malformed UUID are explained', (tester) async {
      await pumpDevTool(tester, env, 'dev.uuid');
      await enter(tester, 'dev.uuid.count', '5000');
      await tapVisible(tester, find.byKey(const Key('dev.uuid.generate')));
      expect(find.text('Count must be a whole number from 1 to 1000.'), findsOneWidget);
      await enter(tester, 'dev.uuid.inspect', '0190163d-8694-739b-x000-000000000000');
      expect(find.textContaining("Invalid character 'x' (U+0078)"), findsOneWidget);
    });

    testWidgets('fits a small phone at 2x text', (tester) async {
      await pumpDevTool(tester, env, 'dev.uuid', size: smallPhone, textScale: 2);
      await tapVisible(tester, find.byKey(const Key('dev.uuid.generate')));
      await enter(tester, 'dev.uuid.inspect', '00000000-0000-0000-0000-000000000000');
      expect(find.text('NIL'), findsOneWidget);
    });
  });

  group('Timestamp tool', () {
    testWidgets('live clock shows the injected time and converts', (tester) async {
      await pumpDevTool(tester, env, 'dev.timestamp');
      expect(find.text('1790365267'), findsOneWidget);
      expect(find.text('2026-09-25T19:41:07.123Z'), findsOneWidget);
      await enter(tester, 'dev.timestamp.input', '1758829267123');
      expect(find.text('Read as Unix milliseconds (auto-detected by magnitude)'), findsOneWidget);
      expect(find.text('2025-09-25T19:41:07.123Z'), findsOneWidget);
      expect(find.text('Thu, 25 Sep 2025 19:41:07 GMT'), findsOneWidget);
      expect(find.text('1 year ago'), findsOneWidget);
    });

    testWidgets('Use now fills the converter; override unit', (tester) async {
      await pumpDevTool(tester, env, 'dev.timestamp');
      await tapVisible(tester, find.text('Use now'));
      expect(find.text('Read as Unix seconds (auto-detected by magnitude)'), findsOneWidget);
      await tapVisible(tester, find.text('Unix ms'));
      expect(find.text('Read as Unix milliseconds'), findsOneWidget);
      expect(find.text('1970-01-21T17:19:25.267Z'), findsOneWidget);
    });

    testWidgets('clock ticks, pauses, and stops while offstage', (tester) async {
      var now = fixedNow;
      final visible = ValueNotifier(true);
      await pumpDevTool(
        tester,
        env,
        'dev.timestamp',
        clock: () => now,
        wrap: (page) => ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (context, v, child) => TickerMode(enabled: v, child: child!),
          child: page,
        ),
      );
      now = now.add(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('1790365272'), findsOneWidget);

      await tester.tap(find.byKey(const Key('dev.timestamp.pause')));
      await tester.pump();
      now = now.add(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('1790365272'), findsOneWidget, reason: 'paused');
      expect(find.text('NOW (PAUSED)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('dev.timestamp.pause')));
      await tester.pump();
      expect(find.text('1790365277'), findsOneWidget);

      visible.value = false;
      await tester.pump();
      now = now.add(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('1790365277'), findsOneWidget, reason: 'offstage: no ticks');
      visible.value = true;
      await tester.pump();
      expect(find.text('1790365282'), findsOneWidget, reason: 'resumes when visible');
    });

    testWidgets('invalid dates show the position', (tester) async {
      await pumpDevTool(tester, env, 'dev.timestamp');
      await enter(tester, 'dev.timestamp.input', '2026-13-01');
      expect(find.textContaining('Month 13 is out of range (01-12) at line 1, column 6'), findsOneWidget);
    });

    testWidgets('fits a small phone at 2x text', (tester) async {
      await pumpDevTool(tester, env, 'dev.timestamp', size: smallPhone, textScale: 2);
      await enter(tester, 'dev.timestamp.input', '2026-09-25T21:41:07+02:00');
      expect(find.text('2026-09-25T19:41:07.000Z'), findsOneWidget);
    });
  });

  group('Text stats tool', () {
    testWidgets('renders and counts live', (tester) async {
      await pumpDevTool(tester, env, 'dev.text_stats');
      expect(find.text('No text yet'), findsOneWidget);
      await enter(tester, 'dev.text_stats.input', 'one two three\n\nfour');
      expect(find.text('4 words, 3 lines'), findsOneWidget);
      expect(find.text('Graphemes'), findsOneWidget);
    });

    testWidgets('large text is computed in the background', (tester) async {
      await pumpDevTool(tester, env, 'dev.text_stats');
      final big = List.filled(60000, 'word').join(' ');
      await enter(tester, 'dev.text_stats.input', big);
      expect(find.text('No text yet'), findsNothing);
      await tester.pump(const Duration(milliseconds: 450)); // debounce for big input
      expect(find.text('STATS (UPDATING...)'), findsOneWidget);
      await pumpUntil(tester, () => find.text('60,000 words, 1 lines').evaluate().isNotEmpty);
    });

    testWidgets('fits a small phone at 2x text', (tester) async {
      await pumpDevTool(tester, env, 'dev.text_stats', size: smallPhone, textScale: 2);
      await enter(tester, 'dev.text_stats.input', 'Hello world');
      expect(find.text('2 words, 1 lines'), findsOneWidget);
    });
  });

  group('JSON escape tool', () {
    testWidgets('escapes live and unescapes', (tester) async {
      await pumpDevTool(tester, env, 'dev.json_escape');
      await enter(tester, 'dev.json_escape.input', 'say "hi"\nnow');
      expect(find.text(r'"say \"hi\"\nnow"'), findsOneWidget);
      await tapVisible(tester, find.text('Unescape literal'));
      await enter(tester, 'dev.json_escape.input', r'"tab\there"');
      expect(find.text('tab\there'), findsOneWidget);
    });

    testWidgets('invalid escapes report their position', (tester) async {
      await pumpDevTool(tester, env, 'dev.json_escape');
      await tapVisible(tester, find.text('Unescape literal'));
      await enter(tester, 'dev.json_escape.input', r'ab\qcd');
      expect(find.textContaining(r'Invalid escape sequence "\q" at line 1, column 3'), findsOneWidget);
    });

    testWidgets('fits a small phone at 2x text', (tester) async {
      await pumpDevTool(tester, env, 'dev.json_escape', size: smallPhone, textScale: 2);
      await enter(tester, 'dev.json_escape.input', 'x');
      expect(find.text('"x"'), findsOneWidget);
    });
  });

  group('Case converter', () {
    testWidgets('converts to every style live', (tester) async {
      await pumpDevTool(tester, env, 'dev.case');
      await enter(tester, 'dev.case.input', 'HTTPServerError');
      expect(find.text('httpServerError'), findsOneWidget);
      expect(find.text('HTTP_SERVER_ERROR'), findsOneWidget);
      expect(find.text('http-server-error'), findsOneWidget);
      expect(find.text('Words (first line): HTTP | Server | Error'), findsOneWidget);
      await tapVisible(tester, find.text('Keep acronyms'));
      expect(find.text('HTTPServerError'), findsNWidgets(2));
    });

    testWidgets('fits a small phone at 2x text', (tester) async {
      await pumpDevTool(tester, env, 'dev.case', size: smallPhone, textScale: 2);
      await enter(tester, 'dev.case.input', 'player max health');
      expect(find.text('player_max_health'), findsOneWidget);
    });
  });

  group('Number base converter', () {
    testWidgets('converts and shows fixed-width views', (tester) async {
      await pumpDevTool(tester, env, 'dev.number_base');
      await enter(tester, 'dev.number_base.input', '0xFF');
      expect(find.text('1111 1111'), findsOneWidget);
      expect(find.text('255'), findsWidgets);
      expect(find.text('FITS UNSIGNED'), findsOneWidget);
      await enter(tester, 'dev.number_base.input', '-1');
      expect(find.text('FF FF FF FF'), findsNWidgets(2));
      expect(find.text('4294967295'), findsOneWidget);
    });

    testWidgets('invalid digits point at the character', (tester) async {
      await pumpDevTool(tester, env, 'dev.number_base');
      await tapVisible(tester, find.text('Bin'));
      await enter(tester, 'dev.number_base.input', '10201');
      expect(find.textContaining("Invalid base-2 digit '2' (U+0032) at line 1, column 3"), findsOneWidget);
    });

    testWidgets('overflow warning', (tester) async {
      await pumpDevTool(tester, env, 'dev.number_base');
      await tapVisible(tester, find.text('8-bit'));
      await enter(tester, 'dev.number_base.input', '300');
      expect(find.textContaining('does not fit in 8 bits'), findsOneWidget);
    });

    testWidgets('fits a small phone at 2x text', (tester) async {
      await pumpDevTool(tester, env, 'dev.number_base', size: smallPhone, textScale: 2);
      await enter(tester, 'dev.number_base.input', '42');
      expect(find.text('2A'), findsOneWidget);
    });
  });

  group('JWT decoder', () {
    final token =
        '${b64url({'alg': 'HS256', 'typ': 'JWT'})}.'
        '${b64url({'sub': '42', 'name': 'Modder', 'exp': 1758829267})}.c2ln';

    testWidgets('decodes and flags expiry against the clock', (tester) async {
      await pumpDevTool(tester, env, 'dev.jwt');
      expect(find.textContaining('the signature is NOT verified'), findsOneWidget);
      await enter(tester, 'dev.jwt.input', 'Bearer $token');
      expect(find.text('EXPIRED'), findsOneWidget);
      expect(find.text('SIGNATURE NOT VERIFIED'), findsOneWidget);
      expect(find.text('Modder'), findsOneWidget);
      expect(find.textContaining('"name": "Modder"'), findsOneWidget);
    });

    testWidgets('malformed tokens are explained', (tester) async {
      await pumpDevTool(tester, env, 'dev.jwt');
      await enter(tester, 'dev.jwt.input', 'not-a-token');
      expect(find.textContaining('Expected 3 parts'), findsOneWidget);
    });

    testWidgets('fits a small phone at 2x text', (tester) async {
      await pumpDevTool(tester, env, 'dev.jwt', size: smallPhone, textScale: 2);
      await enter(tester, 'dev.jwt.input', token);
      expect(find.text('EXPIRED'), findsOneWidget);
    });
  });
}
