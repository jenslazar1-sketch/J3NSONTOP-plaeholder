import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_parser.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_schema.dart';

import 'fixtures.dart';

SchemaNode _schema() => parseSchema(decodeJsonStrict(saveSchema)).root!;

List<String> _v(String json) =>
    validateAgainstSchema(decodeJsonStrict(json), _schema()).map((v) => '${v.pointer} ${v.keyword}').toList();

void main() {
  group('parseSchema', () {
    test('parses the fixture with no errors or warnings', () {
      final r = parseSchema(decodeJsonStrict(saveSchema));
      expect(r.ok, isTrue, reason: r.errors.join('\n'));
      expect(r.warnings, isEmpty);
      final root = r.root!;
      expect(root.properties.keys, ['version', 'slotName', 'player', 'inventory']);
      expect(root.properties['player']!.properties['class']!.enumValues, ['rogue', 'mage', 'knight']);
      expect(root.properties['inventory']!.items!.required, ['id', 'count']);
      expect(root.additionalProperties, isFalse);
    });

    test('unsupported keywords are warnings; malformed ones are errors', () {
      final r = parseSchema(decodeJsonStrict('{"type": "object", "oneOf": [], "properties": {"a": {"type": "wat"}}}'));
      expect(r.warnings.single, contains('"oneOf" is not supported'));
      expect(r.errors.single, contains('unknown type "wat"'));
      expect(r.ok, isFalse);
      expect(parseSchema(decodeJsonStrict('{"pattern": "("}')).errors.single, contains('invalid "pattern"'));
      expect(parseSchema(decodeJsonStrict('{"items": [{}]}')).errors.single, contains('single schema'));
      expect(parseSchema(decodeJsonStrict('{"minLength": -1}')).errors.single, contains('non-negative'));
      expect(parseSchema(decodeJsonStrict('{"enum": []}')).errors.single, contains('must not be empty'));
      expect(parseSchema(decodeJsonStrict('[]')).errors.single, contains('must be an object'));
    });
  });

  group('validateAgainstSchema', () {
    test('valid save passes', () {
      expect(_v(validSave), isEmpty);
    });

    test('type', () {
      expect(_v(validSave.replaceFirst('"version": 2', '"version": "2"')), ['/version type']);
      expect(_v(validSave.replaceFirst('"level": 7', '"level": 7.5')), ['/player/level type']);
      expect(_v(validSave.replaceFirst('"level": 7', '"level": 7.0')), isEmpty, reason: '7.0 is an integer');
      expect(_v(validSave.replaceFirst('"hardcore": false', '"hardcore": 0')), ['/player/hardcore type']);
    });

    test('minimum / maximum', () {
      expect(_v(validSave.replaceFirst('"version": 2', '"version": 0')), ['/version minimum']);
      expect(_v(validSave.replaceFirst('"level": 7', '"level": 100')), ['/player/level maximum']);
      expect(_v(validSave.replaceFirst('"count": 3', '"count": 0')), ['/inventory/0/count minimum']);
    });

    test('minLength / maxLength count characters', () {
      expect(_v(validSave.replaceFirst('"name": "Kaya"', '"name": ""')), ['/player/name minLength']);
      expect(_v(validSave.replaceFirst('"name": "Kaya"', '"name": "ABCDEFGHIJKLMNOPQ"')), ['/player/name maxLength']);
      // 16 emoji = 16 characters (32 UTF-16 code units) is still valid.
      final emoji = String.fromCharCode(0x1F480) * 16;
      expect(_v(validSave.replaceFirst('"name": "Kaya"', '"name": "$emoji"')), isEmpty);
    });

    test('pattern', () {
      expect(_v(validSave.replaceFirst('"iron_key"', '"Iron Key"')), ['/inventory/1/id pattern']);
      expect(_v(validSave.replaceFirst('"Main run"', '"Main/run"')), ['/slotName pattern']);
    });

    test('enum', () {
      expect(_v(validSave.replaceFirst('"rogue"', '"bard"')), ['/player/class enum']);
    });

    test('required and additionalProperties', () {
      expect(_v(validSave.replaceFirst('"hp": 42.5, ', '')), ['/player/hp required']);
      expect(_v(validSave.replaceFirst('"version": 2,', '"version": 2, "cheat": true,')), [
        '/cheat additionalProperties',
      ]);
      expect(_v('{"version": 1, "player": {"name": "a", "class": "mage", "level": 1, "hp": 1}}'), [
        '/inventory required',
      ]);
    });

    test('pointers escape ~ and /', () {
      final s = parseSchema(decodeJsonStrict('{"type": "object", "additionalProperties": false}')).root!;
      final v = validateAgainstSchema(decodeJsonStrict('{"a/b~c": 1}'), s);
      expect(v.single.pointer, '/a~1b~0c');
    });

    test('validateWithSchemaJson reports schema errors instead of throwing', () {
      final v = validateWithSchemaJson(1, decodeJsonStrict('{"type": "nope"}'));
      expect(v.single.keyword, 'schema');
      expect(validateWithSchemaJson(decodeJsonStrict(validSave), decodeJsonStrict(saveSchema)), isEmpty);
    });
  });

  group('defaultForSchema', () {
    test('uses default, enum, bounds and required properties', () {
      final root = _schema();
      expect(defaultForSchema(root.properties['slotName']!), 'Slot');
      expect(defaultForSchema(root.properties['player']!.properties['class']!), 'rogue');
      expect(defaultForSchema(root.properties['version']!), 1);
      final item = defaultForSchema(root.properties['inventory']!.items!);
      expect(item, {'id': '', 'count': 1});
      expect(defaultForSchema(root.properties['player']!.properties['hardcore']!), false);
      expect(defaultForSchema(root.properties['inventory']!), <Object?>[]);
    });
  });
}
