import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/tasks/isolate_runner.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/field_search.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_parser.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_tools.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_tree_ops.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_value.dart';

const _doc = {
  'player': {
    'name': 'Kaya',
    'stats': {
      'max hp': [10, 20, 30],
      'level': 4,
    },
  },
  'flags': [true, null],
};

void main() {
  String formatJsonText(String text, {JsonIndent indent = JsonIndent.two}) =>
      encodeJson(decodeJsonStrict(text), indent: indent);
  String minifyJsonText(String text, {bool ensureAscii = false}) =>
      encodeJson(decodeJsonStrict(text), indent: null, ensureAscii: ensureAscii);

  group('formatting', () {
    test('indent variants, minify, ensure ASCII', () {
      const src = '{"a":[1,{"b":"é"}]}';
      expect(formatJsonText(src), '{\n  "a": [\n    1,\n    {\n      "b": "é"\n    }\n  ]\n}');
      expect(formatJsonText(src, indent: JsonIndent.four), contains('\n    "a": [\n        1,'));
      expect(formatJsonText(src, indent: JsonIndent.tab), contains('\n\t"a": [\n\t\t1,'));
      expect(minifyJsonText(' { "a" : [ 1 , 2 ] } '), '{"a":[1,2]}');
      const bs = r'\';
      expect(minifyJsonText('{"k":"é😀"}', ensureAscii: true), '{"k":"${bs}u00e9${bs}ud83d${bs}ude00"}');
      // ASCII escaping round-trips to the same value.
      expect(decodeJsonStrict(minifyJsonText('{"k":"é😀"}', ensureAscii: true)), {'k': 'é😀'});
    });

    test('formatting invalid JSON throws a located error', () {
      expect(() => formatJsonText('{"a":}'), throwsA(isA<JsonSyntaxError>()));
    });

    test('sortKeysDeep sorts every object but never arrays', () {
      final sorted = sortKeysDeep({
        'b': 1,
        'a': {'z': 1, 'y': 2},
        'c': [
          {'k': 1, 'j': 2},
          3,
          1,
        ],
      });
      expect(encodeJson(sorted, indent: null), '{"a":{"y":2,"z":1},"b":1,"c":[{"j":2,"k":1},3,1]}');
    });

    test('JsonIndent.parse', () {
      expect(JsonIndent.parse('2'), JsonIndent.two);
      expect(JsonIndent.parse('4'), JsonIndent.four);
      expect(JsonIndent.parse('tab'), JsonIndent.tab);
      expect(JsonIndent.parse('3'), isNull);
    });
  });

  group('stats', () {
    test('counts every node', () {
      final s = computeJsonStats(_doc, '{}');
      expect(s.objects, 3);
      expect(s.arrays, 2);
      expect(s.keys, 6);
      expect(s.numbers, 4);
      expect(s.strings, 1);
      expect(s.booleans, 1);
      expect(s.nulls, 1);
      expect(s.depth, 4);
      expect(s.longestArray, 3);
    });
  });

  group('JSONPath and pointers', () {
    test('identifier keys use dots, others brackets', () {
      expect(formatJsonPath(['player', 'stats', 'max hp', 2]), r'$.player.stats["max hp"][2]');
      expect(formatJsonPath([]), r'$');
      expect(formatJsonPath(['a"b', r'_ok$']), r'$["a\"b"]._ok$');
      expect(formatJsonPointer(['a/b', 'c~d', 0]), '/a~1b/c~0d/0');
    });
  });

  group('tree edit operations', () {
    test('setValueAt copies along the path and leaves the source untouched', () {
      final updated = setValueAt(_doc, ['player', 'stats', 'max hp', 2], 99);
      expect(lookupPath(updated, ['player', 'stats', 'max hp', 2]).value, 99);
      expect(lookupPath(_doc, ['player', 'stats', 'max hp', 2]).value, 30);
    });

    test('renameKeyAt keeps position and rejects duplicates', () {
      final r = renameKeyAt(_doc, ['player'], 'name', 'nick')! as Map<String, Object?>;
      expect((r['player']! as Map<String, Object?>).keys, ['nick', 'stats']);
      expect(() => renameKeyAt(_doc, ['player'], 'name', 'stats'), throwsA(isA<JsonEditError>()));
      expect(() => renameKeyAt(_doc, ['flags'], 'x', 'y'), throwsA(isA<JsonEditError>()));
    });

    test('add, insert, remove and move', () {
      var v = addPropertyAt(_doc, ['player'], 'class', 'rogue');
      expect(lookupPath(v, ['player', 'class']).value, 'rogue');
      expect(() => addPropertyAt(v, ['player'], 'class', 1), throwsA(isA<JsonEditError>()));
      v = insertItemAt(v, ['flags'], 'x', index: 0);
      expect(lookupPath(v, ['flags']).value, ['x', true, null]);
      v = removeAt(v, ['flags', 1]);
      expect(lookupPath(v, ['flags']).value, ['x', null]);
      v = moveItemAt(v, ['flags'], 0, 1);
      expect(lookupPath(v, ['flags']).value, [null, 'x']);
      v = removeAt(v, ['player', 'stats']);
      expect(lookupPath(v, ['player', 'stats']).exists, isFalse);
      expect(() => removeAt(v, const []), throwsA(isA<JsonEditError>()));
      expect(() => setValueAt(v, ['nope', 1], 1), throwsA(isA<JsonEditError>()));
    });

    test('type-aware scalar parsing', () {
      expect(parseScalarInput(ScalarKind.number, '42'), 42);
      expect(parseScalarInput(ScalarKind.number, '-1.5e2'), -150.0);
      expect(() => parseScalarInput(ScalarKind.number, '12abc'), throwsA(isA<JsonEditError>()));
      expect(() => parseScalarInput(ScalarKind.number, '01'), throwsA(isA<JsonEditError>()));
      expect(parseScalarInput(ScalarKind.boolean, 'true'), true);
      expect(() => parseScalarInput(ScalarKind.boolean, 'yes'), throwsA(isA<JsonEditError>()));
      expect(parseScalarInput(ScalarKind.nul, 'anything'), isNull);
      expect(parseScalarInput(ScalarKind.string, ' keep '), ' keep ');
    });
  });

  group('field search', () {
    test('keys, values, both, case sensitivity', () {
      final keys = searchJson(_doc, const FieldSearchQuery(pattern: 'HP', scope: SearchScope.keys));
      expect(keys.hits.map((h) => h.jsonPath), [r'$.player.stats["max hp"]']);
      final values = searchJson(_doc, const FieldSearchQuery(pattern: 'kaya', scope: SearchScope.valuesOnly));
      expect(values.hits.single.jsonPath, r'$.player.name');
      expect(values.hits.single.valueMatch, isTrue);
      final cs = searchJson(_doc, const FieldSearchQuery(pattern: 'kaya', caseSensitive: true));
      expect(cs.hits, isEmpty);
      final nulls = searchJson(_doc, const FieldSearchQuery(pattern: 'null', scope: SearchScope.valuesOnly));
      expect(nulls.hits.single.path, ['flags', 1]);
    });

    test('regex and limit', () {
      final r = searchJson(_doc, const FieldSearchQuery(pattern: r'^[0-9]0$', regex: true));
      expect(r.hits.map((h) => h.jsonPath), [
        r'$.player.stats["max hp"][0]',
        r'$.player.stats["max hp"][1]',
        r'$.player.stats["max hp"][2]',
      ]);
      final limited = searchJson(_doc, const FieldSearchQuery(pattern: r'\d', regex: true, limit: 2));
      expect(limited.hits, hasLength(2));
      expect(limited.truncated, isTrue);
      expect(() => searchJson(_doc, const FieldSearchQuery(pattern: '(', regex: true)), throwsFormatException);
    });

    test('catastrophic regex is stopped by runBounded', () async {
      final doc = {'k': '${'a' * 40}!'};
      await expectLater(
        runBounded(
          () => searchJson(doc, const FieldSearchQuery(pattern: r'^(a+)+$', regex: true)),
          timeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<OperationTimedOut>()),
      );
    });
  });
}
