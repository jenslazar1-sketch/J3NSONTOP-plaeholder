import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/base64_tools.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/common.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/json_escape.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/url_tools.dart';

Matcher inputErrorAt(int offset, [String? text]) => isA<InputError>()
    .having((e) => e.offset, 'offset', offset)
    .having((e) => e.message, 'message', text == null ? anything : contains(text));

/// A JSON unicode escape sequence, built at runtime so this source stays
/// free of literal escape sequences.
String u(String hex) => '${r'\'}u$hex';

void main() {
  group('Base64', () {
    test('encodes text in both alphabets with and without padding', () {
      expect(Base64Tools.encodeText('hello?>'), 'aGVsbG8/Pg==');
      expect(Base64Tools.encodeText('hello?>', urlSafe: true), 'aGVsbG8_Pg==');
      expect(Base64Tools.encodeText('hello?>', urlSafe: true, padding: false), 'aGVsbG8_Pg');
      expect(Base64Tools.encodeText(''), '');
      expect(Base64Tools.encodeText('ä€😀'), base64.encode(utf8.encode('ä€😀')));
    });

    test('wraps long output at the requested line length', () {
      final s = Base64Tools.encodeBytes(List<int>.filled(100, 7), lineLength: 76);
      final lines = s.split('\n');
      expect(lines.first.length, 76);
      expect(lines.length, 2);
      expect(Base64Tools.decode(s).bytes, List<int>.filled(100, 7));
    });

    test('decode tolerates whitespace, line breaks and missing padding', () {
      expect(Base64Tools.decode(' aGVs\nbG8g\r\n d29y bGQ= ').text, 'hello world');
      expect(Base64Tools.decode('aGVsbG8').text, 'hello');
      final url = Base64Tools.decode('aGVsbG8_Pg');
      expect(url.text, 'hello?>');
      expect(url.alphabet, Base64Alphabet.urlSafe);
      expect(url.hadPadding, isFalse);
      expect(Base64Tools.decode('').bytes, isEmpty);
    });

    test('invalid characters are reported with their position', () {
      expect(() => Base64Tools.decode('aGVs*G8='), throwsA(inputErrorAt(4, "'*'")));
      final e = _catch(() => Base64Tools.decode('aGVs\nbG8!'));
      expect(e.lineColumn, (2, 4));
      expect(e.toString(), contains('line 2, column 4'));
    });

    test('data after padding, mixed alphabets, truncation and bad padding', () {
      expect(() => Base64Tools.decode('aGk=aGk='), throwsA(inputErrorAt(4, 'after padding')));
      expect(() => Base64Tools.decode('ab+c-d=='), throwsA(inputErrorAt(4, 'Mixed alphabets')));
      expect(() => Base64Tools.decode('aGVsb'), throwsA(inputErrorAt(4, 'Truncated')));
      expect(() => Base64Tools.decode('aGk==='), throwsA(inputErrorAt(3, 'Incorrect padding')));
    });

    test('non-canonical trailing bits decode with a warning', () {
      final d = Base64Tools.decode('QR==');
      expect(d.bytes, [0x41]);
      expect(d.warnings.single, contains('Non-canonical'));
    });

    test('data URI prefix is stripped and reported', () {
      final d = Base64Tools.decode('data:text/plain;charset=utf-8;base64,aGk=');
      expect(d.text, 'hi');
      expect(d.dataUriMime, 'text/plain');
    });

    test('binary output is flagged as not UTF-8 with the byte offset', () {
      final d = Base64Tools.decode(base64.encode([0x61, 0x62, 0xFF, 0x00]));
      expect(d.text, isNull);
      expect(d.invalidUtf8Offset, 2);
    });
  });

  group('UTF-8 validation and helpers', () {
    test('firstInvalidUtf8 finds overlongs, surrogates and truncation', () {
      expect(firstInvalidUtf8(utf8.encode('ok ä € 😀')), isNull);
      expect(firstInvalidUtf8([0x61, 0xC0, 0x80]), 1); // overlong NUL
      expect(firstInvalidUtf8([0xED, 0xA0, 0x80]), 0); // UTF-16 surrogate
      expect(firstInvalidUtf8([0x61, 0xE2, 0x82]), 1); // truncated
      expect(firstInvalidUtf8([0xF4, 0x90, 0x80, 0x80]), 0); // > U+10FFFF
    });

    test('hex dump and sniffing', () {
      final dump = hexDump(utf8.encode('Hello, J3!'));
      expect(dump, startsWith('00000000  48 65 6c 6c 6f 2c 20 4a'));
      expect(dump, contains('|Hello, J3!|'));
      expect(hexBytes([0xde, 0xad]), 'DE AD');
      expect(sniffFileType([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])!.extension, 'png');
      expect(sniffFileType([0x50, 0x4B, 0x03, 0x04])!.label, 'ZIP archive');
      expect(sniffFileType([1, 2, 3]), isNull);
    });

    test('describeCharAt names invisible characters', () {
      expect(describeCharAt('a b', 1), 'U+0020 SPACE');
      expect(describeCharAt('x😀', 1), "'😀' (U+1F600)");
      expect(describeCharAt('\u0001', 0), contains('control character'));
    });
  });

  group('URL encoding', () {
    const sample = 'a b&c=d/é?#%~';
    test('component encoding keeps only unreserved characters', () {
      expect(UrlTools.encode(sample, UrlEncodeMode.component), 'a%20b%26c%3Dd%2F%C3%A9%3F%23%25~');
      expect(UrlTools.encode("!'()*", UrlEncodeMode.component), '%21%27%28%29%2A');
      expect(UrlTools.encode('😀', UrlEncodeMode.component), '%F0%9F%98%80');
    });

    test('full URI encoding keeps structure and existing escapes', () {
      expect(
        UrlTools.encode('https://x.dev/a b?q=ü&r=%20#top', UrlEncodeMode.fullUri),
        'https://x.dev/a%20b?q=%C3%BC&r=%20#top',
      );
      expect(UrlTools.encode('100%', UrlEncodeMode.fullUri), '100%25');
    });

    test('form encoding uses + for spaces', () {
      expect(UrlTools.encode('a b+c*', UrlEncodeMode.form), 'a+b%2Bc*');
    });

    test('decode round-trips and handles +', () {
      for (final mode in UrlEncodeMode.values) {
        expect(UrlTools.decode(UrlTools.encode(sample, mode), plusAsSpace: mode == UrlEncodeMode.form), sample);
      }
      expect(UrlTools.decode('a+b'), 'a+b');
      expect(UrlTools.decode('a+b', plusAsSpace: true), 'a b');
    });

    test('malformed percent sequences report their position', () {
      expect(() => UrlTools.decode('abc%zz'), throwsA(inputErrorAt(3, '%zz')));
      expect(() => UrlTools.decode('abc%4'), throwsA(inputErrorAt(3, 'Incomplete')));
      expect(() => UrlTools.decode('caf%E9!'), throwsA(inputErrorAt(3, 'not valid UTF-8')));
    });
  });

  group('URL inspector', () {
    test('splits all parts and decodes query parameters in order', () {
      final r = UrlTools.inspect('https://user:pw@example.com:8443/a%20b/c?x=1&tag=a+b&tag=%2F&flag#frag%20x');
      expect(r.scheme, 'https');
      expect(r.userInfo, 'user:pw');
      expect(r.host, 'example.com');
      expect(r.port, 8443);
      expect(r.portIsDefault, isFalse);
      expect(r.segments, ['a b', 'c']);
      expect(r.query.map((q) => '${q.name}=${q.value}'), ['x=1', 'tag=a b', 'tag=/', 'flag=null']);
      expect(r.fragment, 'frag x');
      expect(r.origin, 'https://example.com:8443');
      expect(r.warnings, contains(contains('password')));
    });

    test('default ports are marked', () {
      final r = UrlTools.inspect('http://localhost/');
      expect(r.port, 80);
      expect(r.portIsDefault, isTrue);
    });

    test('spaces and malformed escapes are errors with positions', () {
      expect(() => UrlTools.inspect('http://exa mple.com'), throwsA(inputErrorAt(10, 'SPACE')));
      expect(() => UrlTools.inspect('http://x.dev/%zz'), throwsA(inputErrorAt(13)));
      expect(() => UrlTools.inspect('   '), throwsA(isA<InputError>()));
    });
  });

  group('JSON escape', () {
    test('escapes quotes, backslashes and control characters', () {
      expect(
        JsonEscape.escape('He said "hi"\\\n\t${String.fromCharCode(1)}'),
        '"He said \\"hi\\"\\\\\\n\\t${u('0001')}"',
      );
      expect(JsonEscape.escape('x', const JsonEscapeOptions(quotes: false)), 'x');
      expect(JsonEscape.escape('</b>', const JsonEscapeOptions(escapeSlash: true)), r'"<\/b>"');
      expect(JsonEscape.escape(String.fromCharCode(0x2028)), '"${u('2028')}"');
    });

    test('ASCII-only escapes non-ASCII including surrogate pairs', () {
      final text = '${String.fromCharCode(0xE9)}${String.fromCharCodes([0xD83D, 0xDE00])}';
      expect(
        JsonEscape.escape(text, const JsonEscapeOptions(asciiOnly: true)),
        '"${u('00e9')}${u('d83d')}${u('de00')}"',
      );
      expect(JsonEscape.escape(text), '"$text"');
    });

    test('output always parses back with jsonDecode', () {
      final nasty = 'a"b\\c\n\r\t\b\f${String.fromCharCodes([0, 0xE9, 0xD83D, 0xDE00, 0x2029])}/';
      for (final ascii in [false, true]) {
        final lit = JsonEscape.escape(nasty, JsonEscapeOptions(asciiOnly: ascii, escapeSlash: ascii));
        expect(jsonDecode(lit), nasty);
      }
    });

    test('unescape accepts literals with or without quotes', () {
      final smile = String.fromCharCodes([0xD83D, 0xDE00]);
      expect(
        JsonEscape.unescape('"a\\nb ${u('00e9')} ${u('d83d')}${u('de00')}"').text,
        'a\nb ${String.fromCharCode(0xE9)} $smile',
      );
      final r = JsonEscape.unescape(r'tab\there');
      expect(r.text, 'tab\there');
      expect(r.hadQuotes, isFalse);
    });

    test('unescape reports precise errors', () {
      expect(() => JsonEscape.unescape(r'ab\x'), throwsA(inputErrorAt(2, r'"\x"')));
      expect(() => JsonEscape.unescape(r'\u12G4'), throwsA(inputErrorAt(0, 'expected 4 hex digits')));
      expect(() => JsonEscape.unescape(r'end\'), throwsA(inputErrorAt(3, 'incomplete escape')));
      expect(() => JsonEscape.unescape('"a"b"'), throwsA(inputErrorAt(2, 'Unescaped double quote')));
      expect(() => JsonEscape.unescape('line\nbreak'), throwsA(inputErrorAt(4, 'control character')));
      expect(() => JsonEscape.unescape('"open'), throwsA(inputErrorAt(0, 'matching closing quote')));
    });

    test('lone surrogates produce warnings', () {
      expect(JsonEscape.unescape(r'\ud83d').warnings.single, contains('high surrogate'));
      expect(JsonEscape.unescape(r'\ude00').warnings.single, contains('low surrogate'));
    });
  });
}

InputError _catch(void Function() f) {
  try {
    f();
  } on InputError catch (e) {
    return e;
  }
  fail('expected an InputError');
}
