import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_parser.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_tools.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_value.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/source_location.dart';

JsonSyntaxError _err(String text) {
  try {
    parseJsonStrict(text);
  } on JsonSyntaxError catch (e) {
    return e;
  }
  fail('expected a syntax error for: $text');
}

void main() {
  group('parseJsonStrict: valid input matches jsonDecode', () {
    const samples = [
      '{}',
      '[]',
      '0',
      '-12',
      '3.25',
      '1e3',
      '-2.5E-3',
      'true',
      'false',
      'null',
      r'"a\"b\\c\/d\b\f\n\r\t'
          r'\'
          r'u00e9"',
      r'"x\'
          r'ud83d\'
          r'ude00y"',
      '{"a": [1, 2, {"b": null}], "c": "x", "d": {"e": [true, false]}}',
      '  \n\t {"nested": [[[]]], "empty": {}}  \r\n',
    ];
    for (final s in samples) {
      test(s, () {
        expect(jsonDeepEquals(parseJsonStrict(s).value, jsonDecode(s), orderedKeys: true), isTrue);
      });
    }

    test('keeps key order and int/double distinction', () {
      final v = parseJsonStrict('{"z": 1, "a": 1.0, "m": 2}').value! as Map<String, Object?>;
      expect(v.keys, ['z', 'a', 'm']);
      expect(v['z'], isA<int>());
      expect(v['a'], isA<double>());
    });
  });

  group('syntax errors carry exact offsets', () {
    test('trailing comma in object points at the comma', () {
      const text = '{\n  "a": 1,\n}';
      final e = _err(text);
      expect(e.message, contains('Trailing comma'));
      expect(e.offset, text.indexOf(','));
      final loc = SourceLocation.fromOffset(text, e.offset);
      expect((loc.line, loc.column), (2, 9));
    });

    test('trailing comma in array', () {
      final e = _err('[1, 2, ]');
      expect(e.message, contains('Trailing comma'));
      expect(e.offset, 5);
    });

    test('missing value after colon', () {
      const text = '{"a": 1,\n "b": }';
      final e = _err(text);
      expect(e.message, contains('expected a value'));
      final loc = SourceLocation.fromOffset(text, e.offset);
      expect((loc.line, loc.column), (2, 7));
    });

    test('comments, single quotes, unquoted keys, literals', () {
      expect(_err('{"a": 1 // x\n}').message, contains('Comments are not allowed'));
      expect(_err("{'a': 1}").message, contains('double quotes'));
      expect(_err('{a: 1}').message, contains('unquoted "a"'));
      expect(_err('[True]').message, contains('lowercase'));
      expect(_err('[NaN]').message, contains('"NaN" is not a valid JSON value'));
      expect(_err('{"a" = 1}').message, contains('found "="'));
    });

    test('number grammar', () {
      expect(_err('[01]').message, contains('Leading zeros'));
      expect(_err('[+1]').message, contains('must not start with "+"'));
      expect(_err('[.5]').message, contains('start with a digit'));
      expect(_err('[1.]').message, contains('decimal point'));
      expect(_err('[1e]').message, contains('exponent'));
      expect(_err('[-]').message, contains('after "-"'));
      expect(_err('[1e999]').message, contains('out of range'));
    });

    test('strings', () {
      final e = _err('["abc');
      expect(e.message, contains('Unterminated string'));
      expect(e.offset, 1);
      expect(_err('["a\nb"]').message, contains('line break'));
      expect(_err(r'["\x"]').message, contains(r'Invalid escape sequence "\x"'));
      expect(_err(r'["\u12G4"]').message, contains(r'\u escape'));
    });

    test('structure', () {
      expect(_err('').message, contains('Empty input'));
      expect(_err('{"a": 1} {"b": 2}').message, contains('after the JSON value'));
      expect(_err('[1 2]').message, contains('Expected "," or "]"'));
      expect(_err('{"a": 1 "b": 2}').message, contains('Expected "," between properties'));
      expect(_err('{"a": 1').message, contains('Unterminated object'));
      expect(_err('${String.fromCharCode(0xA0)}{}').message, contains('no-break space'));
    });

    test('nesting depth is bounded', () {
      final deep = '${'[' * 600}${']' * 600}';
      expect(_err(deep).message, contains('Nesting deeper'));
    });
  });

  group('warnings', () {
    test('duplicate keys: last value wins at the first position, both offsets reported', () {
      const text = '{"a": 1, "b": 2, "a": 3}';
      final out = parseJsonStrict(text);
      expect(out.value, {'a': 3, 'b': 2});
      expect((out.value! as Map<String, Object?>).keys, ['a', 'b']);
      expect(out.duplicates, hasLength(1));
      expect(out.duplicates.single.key, 'a');
      expect(out.duplicates.single.firstOffset, 1);
      expect(out.duplicates.single.offset, text.lastIndexOf('"a"'));
      expect(out.duplicates.single.path, ['a']);
    });

    test('number precision notes', () {
      final out = parseJsonStrict(
        '{"big": 12345678901234567890, "safe": 9007199254740993, "long": 0.123456789012345678901}',
      );
      final msgs = out.numberNotes.map((n) => n.message).join('\n');
      expect(msgs, contains('does not fit in 64 bits'));
      expect(msgs, contains('beyond 2^53'));
      expect(msgs, contains('17 significant digits'));
      expect(out.numberNotes.first.path, ['big']);
    });

    test('BOM is skipped and flagged', () {
      final out = parseJsonStrict('${String.fromCharCode(0xFEFF)}{"a":1}');
      expect(out.hadBom, isTrue);
      expect(out.value, {'a': 1});
    });
  });

  group('analyzeJson', () {
    test('valid document has stats and warnings with locations', () {
      final a = analyzeJson('{\n  "a": [1, 2],\n  "a": {"b": null}\n}');
      expect(a.valid, isTrue);
      expect(a.warnings.single.location.line, 3);
      expect(a.stats!.depth, 2);
      expect(a.stats!.keys, 2);
    });

    test('invalid document has location and caret snippet', () {
      const text = '{\n  "name": "x",\n  "hp": 10,\n}';
      final a = analyzeJson(text);
      expect(a.valid, isFalse);
      expect(a.error!.location!.line, 3);
      expect(a.error!.location!.column, 11);
      expect(a.error!.snippet, contains('3 |   "hp": 10,'));
      expect(a.error!.snippet!.split('\n').last, '  |           ^');
    });

    test('empty input', () {
      final a = analyzeJson('   ');
      expect(a.empty, isTrue);
      expect(a.valid, isFalse);
    });
  });

  group('caretSnippet', () {
    test('windows very long lines around the column', () {
      final line = '${'x' * 200}!${'y' * 200}';
      final s = caretSnippet(line, 1, 201);
      final rows = s.split('\n');
      final caretAt = rows[1].indexOf('^');
      expect(rows[0][caretAt], '!');
    });
  });
}
