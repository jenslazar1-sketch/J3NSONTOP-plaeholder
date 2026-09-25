import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/case_tools.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/common.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/jwt_tools.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/number_base.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/text_stats.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/timestamp_tools.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/uuid_tools.dart';

Matcher inputErrorAt(int? offset, [String? text]) => isA<InputError>()
    .having((e) => e.offset, 'offset', offset)
    .having((e) => e.message, 'message', text == null ? anything : contains(text));

String b64url(Object json) => base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

void main() {
  group('UUID', () {
    final canonical = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

    test('v4 generation: count, format and version bits', () {
      final ids = UuidTools.generate(UuidKind.v4, 50);
      expect(ids.length, 50);
      expect(ids.toSet().length, 50);
      for (final id in ids) {
        expect(id, matches(canonical));
        final info = UuidTools.inspect(id);
        expect(info.version, 4);
        expect(info.variant, UuidVariant.rfc);
      }
    });

    test('formatting options', () {
      final id = UuidTools.generate(
        UuidKind.v4,
        1,
        format: const UuidFormat(uppercase: true, hyphens: false, braces: true),
      ).single;
      expect(id, matches(RegExp(r'^\{[0-9A-F]{32}\}$')));
      expect(UuidTools.inspect(id).version, 4);
    });

    test('v7 embeds the clock and is strictly increasing within a batch', () {
      final t = DateTime.utc(2026, 9, 25, 19, 41, 7, 123);
      final ids = UuidTools.generate(UuidKind.v7, 1000, clock: () => t, random: Random(7));
      final sorted = [...ids]..sort();
      expect(sorted, ids);
      expect(ids.toSet().length, 1000);
      final info = UuidTools.inspect(ids.first);
      expect(info.version, 7);
      expect(info.timestamp, t);
      expect(info.versionName, contains('v7'));
    });

    test('count is validated', () {
      expect(() => UuidTools.generate(UuidKind.v4, 0), throwsA(isA<InputError>()));
      expect(() => UuidTools.generate(UuidKind.v4, 1001), throwsA(isA<InputError>()));
    });

    test('inspect accepts URN, braces, no hyphens and detects nil/max and v1 time', () {
      expect(UuidTools.inspect('urn:uuid:00000000-0000-0000-0000-000000000000').isNil, isTrue);
      expect(UuidTools.inspect('{FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF}').isMax, isTrue);
      final v1 = UuidTools.inspect('c232ab00-9414-11ec-b3c8-9f6bdeced846');
      expect(v1.version, 1);
      expect(v1.timestamp, DateTime.utc(2022, 2, 22, 19, 22, 22));
      final v6 = UuidTools.inspect('1EC9414C-232A-6B00-B3C8-9F6BDECED846');
      expect(v6.version, 6);
      expect(v6.timestamp, DateTime.utc(2022, 2, 22, 19, 22, 22));
      expect(UuidTools.inspect('0190163d8694739b0000000000000000').notes, contains('Written without hyphens'));
      expect(UuidTools.inspect('00000000-0000-0000-c000-000000000000').variant, UuidVariant.microsoft);
    });

    test('inspect errors carry positions', () {
      expect(() => UuidTools.inspect('0190163d-8694-739b-x000-000000000000'), throwsA(inputErrorAt(19, "'x'")));
      expect(() => UuidTools.inspect('0190163d-8694-739b'), throwsA(inputErrorAt(18, 'Too short')));
      expect(() => UuidTools.inspect('0190163d8-694-739b-0000-000000000000'), throwsA(inputErrorAt(0, 'Hyphens')));
      expect(() => UuidTools.inspect('{0190163d-8694-739b-0000-000000000000'), throwsA(inputErrorAt(0, '"}"')));
    });
  });

  group('Timestamps', () {
    final t = DateTime.utc(2026, 9, 25, 19, 41, 7, 123);

    test('auto-detects the unit by magnitude', () {
      expect(Timestamps.parse('1758829267').utc, DateTime.utc(2025, 9, 25, 19, 41, 7));
      expect(Timestamps.parse('1758829267123').utc, DateTime.utc(2025, 9, 25, 19, 41, 7, 123));
      expect(Timestamps.parse('1758829267123456').utc, DateTime.utc(2025, 9, 25, 19, 41, 7, 123, 456));
      final ns = Timestamps.parse('1758829267123456789');
      expect(ns.utc, DateTime.utc(2025, 9, 25, 19, 41, 7, 123, 456));
      expect(ns.subMicroNanos, 789);
      expect(ns.interpretation, contains('nanoseconds (auto-detected'));
      expect(Timestamps.parse('-1').utc, DateTime.utc(1969, 12, 31, 23, 59, 59));
      expect(Timestamps.parse('1_758_829_267').utc.year, 2025);
    });

    test('explicit unit override and fractions', () {
      expect(
        Timestamps.parse('1758829267', kind: TimestampInput.milliseconds).utc,
        DateTime.utc(1970, 1, 21, 8, 33, 49, 267),
      );
      final f = Timestamps.parse('1758829267.5');
      expect(f.utc, DateTime.utc(2025, 9, 25, 19, 41, 7, 500));
      expect(Timestamps.parse('-0.25').utc, DateTime.utc(1969, 12, 31, 23, 59, 59, 750));
    });

    test('numeric errors and range', () {
      expect(() => Timestamps.parse('17588x', kind: TimestampInput.seconds), throwsA(inputErrorAt(5, "'x'")));
      expect(
        () => Timestamps.parse('99999999999999999999999', kind: TimestampInput.seconds),
        throwsA(isA<InputError>()),
      );
      expect(() => Timestamps.parse('  '), throwsA(isA<InputError>()));
    });

    test('ISO-8601 with offsets, fractions and basic format', () {
      expect(Timestamps.parse('2026-09-25T19:41:07.123Z').utc, t);
      final p = Timestamps.parse('2026-09-25T21:41:07.123+02:00');
      expect(p.utc, t);
      expect(p.offset, const Duration(hours: 2));
      expect(Timestamps.parse('20260925T194107.123Z').utc, t);
      expect(Timestamps.parse('2026-09-25 19:41:07,123 UTC').utc, t);
      final n = Timestamps.parse('2026-09-25T19:41:07.123456789Z');
      expect(n.subMicroNanos, 789);
      expect(Timestamps.parse('2026-09-25', assumeUtc: true).utc, DateTime.utc(2026, 9, 25));
      expect(Timestamps.parse('2026-09-25T24:00:00Z').utc, DateTime.utc(2026, 9, 26));
      final local = Timestamps.parse('2026-09-25T10:00:00');
      expect(local.utc, DateTime(2026, 9, 25, 10).toUtc());
      expect(local.notes.single, contains('local time'));
    });

    test('ISO errors point at the bad field', () {
      expect(() => Timestamps.parse('2026-13-01'), throwsA(inputErrorAt(5, 'Month 13')));
      expect(() => Timestamps.parse('2026-02-30'), throwsA(inputErrorAt(8, 'Day 30')));
      expect(() => Timestamps.parse('2026-09-25T25:00Z'), throwsA(inputErrorAt(11, 'Hour 25')));
      expect(() => Timestamps.parse('2026-09-25T10:61Z'), throwsA(inputErrorAt(14, 'Minute 61')));
      expect(() => Timestamps.parse('2026-09-25T10:00:60Z'), throwsA(inputErrorAt(17, 'Leap second')));
      expect(() => Timestamps.parse('2026-09-25T10:00Zjunk'), throwsA(inputErrorAt(17, 'Unexpected')));
      expect(() => Timestamps.parse('2026-09-25T10:00+25:00'), throwsA(inputErrorAt(16, 'offset')));
    });

    test('RFC 2822 and all HTTP date forms', () {
      expect(Timestamps.parse('Fri, 25 Sep 2026 21:41:07 +0200').utc, DateTime.utc(2026, 9, 25, 19, 41, 7));
      expect(Timestamps.parse('Fri, 25 Sep 2026 19:41:07 GMT').utc, DateTime.utc(2026, 9, 25, 19, 41, 7));
      expect(Timestamps.parse('Sunday, 06-Nov-94 08:49:37 GMT').utc, DateTime.utc(1994, 11, 6, 8, 49, 37));
      expect(Timestamps.parse('Sun Nov  6 08:49:37 1994').utc, DateTime.utc(1994, 11, 6, 8, 49, 37));
      expect(Timestamps.parse('25 Sep 2026 12:41 PDT').utc, DateTime.utc(2026, 9, 25, 19, 41));
      final wrongDay = Timestamps.parse('Mon, 25 Sep 2026 19:41:07 GMT');
      expect(wrongDay.notes.single, contains('Friday'));
      expect(() => Timestamps.parse('Fri, 25 Sop 2026 19:41:07 GMT'), throwsA(inputErrorAt(8, 'Unknown month')));
      expect(() => Timestamps.parse('Fri, 25 Sep 2026 19:41:07 XYZ'), throwsA(inputErrorAt(26, 'time zone')));
    });

    test('formatting', () {
      expect(Timestamps.isoUtc(t), '2026-09-25T19:41:07.123Z');
      expect(Timestamps.isoWithOffset(t, const Duration(hours: 5, minutes: 30)), '2026-09-26T01:11:07.123+05:30');
      expect(Timestamps.isoWithOffset(t, const Duration(hours: -3)), '2026-09-25T16:41:07.123-03:00');
      expect(Timestamps.rfc2822(t, offset: const Duration(hours: 2)), 'Fri, 25 Sep 2026 21:41:07 +0200');
      expect(Timestamps.httpDate(t), 'Fri, 25 Sep 2026 19:41:07 GMT');
      final ns = BigInt.parse('1758829267123000000');
      expect(Timestamps.epochIn(ns, EpochUnit.seconds), '1758829267.123');
      expect(Timestamps.epochIn(ns, EpochUnit.milliseconds), '1758829267123');
      expect(Timestamps.epochIn(-BigInt.from(250000000), EpochUnit.seconds), '-0.25');
    });

    test('relative time, ISO weeks and describe rows', () {
      expect(Timestamps.relative(t, t), 'now');
      expect(Timestamps.relative(t.add(const Duration(days: 3, hours: 4, minutes: 5)), t), 'in 3 days, 4 hours');
      expect(Timestamps.relative(t.subtract(const Duration(minutes: 2, seconds: 5)), t), '2 minutes, 5 seconds ago');
      expect(Timestamps.relative(t.subtract(const Duration(hours: 1)), t), '1 hour ago');
      expect(Timestamps.isoWeek(2026, 9, 25), (2026, 39));
      expect(Timestamps.isoWeek(2021, 1, 3), (2020, 53));
      expect(Timestamps.isoWeek(2024, 12, 30), (2025, 1));
      final rows = Timestamps.describe(
        Timestamps.parse('2026-09-25T19:41:07.123Z'),
        t,
        localOffset: const Duration(hours: 2),
        zoneName: 'CEST',
      );
      final map = {for (final (k, v) in rows) k: v};
      expect(map['Unix seconds'], '1790365267.123');
      expect(map['ISO-8601 local'], '2026-09-25T21:41:07.123+02:00 (CEST)');
      expect(map['Relative'], 'now');
      expect(map['UTC calendar'], 'Friday, ISO week 2026-W39-5, day 268 of 2026');
    });
  });

  group('Text stats', () {
    test('counts code units, code points, graphemes and bytes', () {
      final family = String.fromCharCodes([0xD83D, 0xDC68, 0x200D, 0xD83D, 0xDC69, 0x200D, 0xD83D, 0xDC67]);
      final s = TextStatsCalculator.compute('e${String.fromCharCode(0x301)} $family');
      expect(s.utf16Units, 11);
      expect(s.codePoints, 8);
      expect(s.graphemes, 3);
      expect(s.utf8Bytes, utf8.encode('e${String.fromCharCode(0x301)} $family').length);
      expect(s.utf16Bytes, 22);
    });

    test('words, lines, blank lines, longest line and paragraphs', () {
      const text = "Don't panic.\n\nThe e-mail from 3.14 people arrived!\nSecond line here\n";
      final s = TextStatsCalculator.compute(text);
      expect(s.words, 11);
      expect(s.lines, 4);
      expect(s.blankLines, 1);
      expect(s.longestLine, 36);
      expect(s.longestLineNumber, 3);
      expect(s.paragraphs, 2);
      expect(s.sentences, 3);
      expect(s.topWords.first.$2, 1);
    });

    test('empty text and CJK words', () {
      final e = TextStatsCalculator.compute('');
      expect(e.lines, 0);
      expect(e.words, 0);
      expect(e.sentences, 0);
      expect(e.readingTime, Duration.zero);
      final cjk = TextStatsCalculator.compute(String.fromCharCodes([0x6F22, 0x5B57, 0x20, 0x61, 0x62, 0x63]));
      expect(cjk.words, 3);
    });

    test('reading time estimate', () {
      final s = TextStatsCalculator.compute(List.filled(476, 'word').join(' '));
      expect(s.readingTime, const Duration(minutes: 2));
      expect(TextStats.formatMinutes(const Duration(seconds: 65)), '1 min 5 s');
    });
  });

  group('Case converter', () {
    test('robust word splitting', () {
      expect(CaseTools.words('HTTPServerError'), ['HTTP', 'Server', 'Error']);
      expect(CaseTools.words('parseJSONString2Html'), ['parse', 'JSON', 'String2', 'Html']);
      expect(CaseTools.words('utf8Decoder'), ['utf8', 'Decoder']);
      expect(CaseTools.words('utf8Decoder', const CaseOptions(splitDigits: true)), ['utf', '8', 'Decoder']);
      expect(CaseTools.words('  snake_case--kebab.case/path  '), ['snake', 'case', 'kebab', 'case', 'path']);
      expect(CaseTools.words('ÄrgerÜberÖl'), ['Ärger', 'Über', 'Öl']);
    });

    test('all styles', () {
      const input = 'XMLHttpRequest id2';
      final r = {for (final s in CaseStyle.values) s: CaseTools.convert(input, s)};
      expect(r[CaseStyle.camel], 'xmlHttpRequestId2');
      expect(r[CaseStyle.pascal], 'XmlHttpRequestId2');
      expect(r[CaseStyle.snake], 'xml_http_request_id2');
      expect(r[CaseStyle.kebab], 'xml-http-request-id2');
      expect(r[CaseStyle.constant], 'XML_HTTP_REQUEST_ID2');
      expect(r[CaseStyle.title], 'Xml Http Request Id2');
      expect(r[CaseStyle.sentence], 'Xml http request id2');
      expect(r[CaseStyle.lower], 'xmlhttprequest id2');
      expect(r[CaseStyle.upper], 'XMLHTTPREQUEST ID2');
      expect(r[CaseStyle.dot], 'xml.http.request.id2');
      expect(r[CaseStyle.path], 'xml/http/request/id2');
    });

    test('keep acronyms and multi-line input', () {
      const keep = CaseOptions(keepAcronyms: true);
      expect(CaseTools.convert('xml http request', CaseStyle.pascal, keep), 'XmlHttpRequest');
      expect(CaseTools.convert('XML http request', CaseStyle.pascal, keep), 'XMLHttpRequest');
      expect(CaseTools.convert('first_name\nlastName\r\n', CaseStyle.camel), 'firstName\nlastName\n');
    });
  });

  group('Number base', () {
    test('parses bases, prefixes, signs and separators', () {
      expect(NumberBase.parse('ff', 16).value, BigInt.from(255));
      expect(NumberBase.parse('0xFF', null).value, BigInt.from(255));
      expect(NumberBase.parse('0b1010_1010', null).value, BigInt.from(170));
      expect(NumberBase.parse('0o777', null).value, BigInt.from(511));
      expect(NumberBase.parse('-42', 10).value, BigInt.from(-42));
      expect(NumberBase.parse('zz', 36).value, BigInt.from(1295));
      expect(NumberBase.parse('0b', 16).value, BigInt.from(11));
      expect(NumberBase.parse('1 000 000', 10).value, BigInt.from(1000000));
    });

    test('reports the offending character', () {
      expect(() => NumberBase.parse('12a4', 10), throwsA(inputErrorAt(2, 'base-10 digit')));
      expect(() => NumberBase.parse('0x1G', null), throwsA(inputErrorAt(3, "'G'")));
      expect(() => NumberBase.parse('  -', 10), throwsA(inputErrorAt(3, 'Expected digits')));
      expect(() => NumberBase.parse('1', 37), throwsA(isA<InputError>()));
    });

    test('formats with grouping', () {
      expect(NumberBase.format(BigInt.from(255), 2, group: 4), '1111 1111');
      expect(NumberBase.format(BigInt.from(-255), 16), '-FF');
      expect(NumberBase.format(BigInt.from(1295), 36, upper: false), 'zz');
    });

    test("two's complement views, overflow and bytes", () {
      final minus1 = NumberBase.view(BigInt.from(-1), 8);
      expect(minus1.pattern, BigInt.from(255));
      expect(minus1.signed, BigInt.from(-1));
      expect(minus1.fitsSigned, isTrue);
      expect(minus1.fitsUnsigned, isFalse);
      final big = NumberBase.view(BigInt.from(200), 8);
      expect(big.signed, BigInt.from(-56));
      expect(big.fitsUnsigned, isTrue);
      expect(big.fitsSigned, isFalse);
      final over = NumberBase.view(BigInt.from(256), 8);
      expect(over.overflows, isTrue);
      expect(over.pattern, BigInt.zero);
      final v = NumberBase.view(BigInt.from(0x12345678), 32);
      expect(hexBytes(v.bytesBigEndian), '12 34 56 78');
      expect(hexBytes(v.bytesLittleEndian), '78 56 34 12');
      expect(NumberBase.view(BigInt.from(0x3F800000), 32).asFloat, 1.0);
      expect(NumberBase.smallestWidth(BigInt.from(-129)), 16);
      expect(NumberBase.smallestWidth(BigInt.one << 200), isNull);
    });
  });

  group('JWT', () {
    final header = b64url({'alg': 'HS256', 'typ': 'JWT'});
    final payload = b64url({'sub': '42', 'name': 'Modder', 'iat': 1758800000, 'exp': 1758829267, 'nbf': 1758800000});
    final token = '$header.$payload.c2lnbmF0dXJl';

    test('decodes header, payload, signature and time claims', () {
      final d = JwtTools.decode('Bearer $token');
      expect(d.hadBearerPrefix, isTrue);
      expect(d.algorithm, 'HS256');
      expect(d.payload!['name'], 'Modder');
      expect(d.payloadJson, contains('"sub": "42"'));
      expect(d.signatureBytes, 9);
      expect(d.claim('exp')!.time, DateTime.utc(2025, 9, 25, 19, 41, 7));
      expect(d.statusAt(DateTime.utc(2025, 9, 25, 19)), JwtTimeStatus.valid);
      expect(d.statusAt(DateTime.utc(2025, 9, 26)), JwtTimeStatus.expired);
      expect(d.statusAt(DateTime.utc(2025, 9, 1)), JwtTimeStatus.notYetValid);
      expect(d.warnings, isEmpty);
    });

    test('alg none, JWE and malformed tokens', () {
      final none = JwtTools.decode('${b64url({'alg': 'none'})}.$payload.');
      expect(none.warnings.single, contains('unsigned'));
      final jwe = JwtTools.decode('$header.a.b.c.d');
      expect(jwe.isEncrypted, isTrue);
      expect(
        () => JwtTools.decode('abc'),
        throwsA(isA<InputError>().having((e) => e.hint, 'hint', contains('no dots'))),
      );
      expect(() => JwtTools.decode('$header.\$\$\$.x'), throwsA(inputErrorAt(header.length + 1, 'Payload')));
      expect(() => JwtTools.decode('${b64url([1])}.$payload.x'), throwsA(inputErrorAt(0, 'JSON object')));
      expect(
        () => JwtTools.decode('$header.${base64Url.encode(utf8.encode('{nope'))}.x'),
        throwsA(inputErrorAt(header.length + 1, 'not valid JSON')),
      );
    });
  });
}
