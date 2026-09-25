import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/config_format.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_parser.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_value.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/merge_patch.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/presets.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/semantic_diff.dart';

Object? _j(String s) => decodeJsonStrict(s);

void main() {
  group('RFC 7386 appendix A examples', () {
    const cases = [
      ['{"a":"b"}', '{"a":"c"}', '{"a":"c"}'],
      ['{"a":"b"}', '{"b":"c"}', '{"a":"b","b":"c"}'],
      ['{"a":"b"}', '{"a":null}', '{}'],
      ['{"a":"b","b":"c"}', '{"a":null}', '{"b":"c"}'],
      ['{"a":["b"]}', '{"a":"c"}', '{"a":"c"}'],
      ['{"a":"c"}', '{"a":["b"]}', '{"a":["b"]}'],
      ['{"a":{"b":"c"}}', '{"a":{"b":"d","c":null}}', '{"a":{"b":"d"}}'],
      ['{"a":[{"b":"c"}]}', '{"a":[1]}', '{"a":[1]}'],
      ['["a","b"]', '["c","d"]', '["c","d"]'],
      ['{"a":"b"}', '["c"]', '["c"]'],
      ['{"a":"foo"}', 'null', 'null'],
      ['{"a":"foo"}', '"bar"', '"bar"'],
      ['{"e":null}', '{"a":1}', '{"e":null,"a":1}'],
      ['[1,2]', '{"a":"b","c":null}', '{"a":"b"}'],
      ['{}', '{"a":{"bb":{"ccc":null}}}', '{"a":{"bb":{}}}'],
    ];
    for (final c in cases) {
      test('${c[0]} + ${c[1]}', () {
        final target = _j(c[0]);
        final before = jsonDeepCopy(target);
        final result = applyMergePatch(target, _j(c[1]));
        expect(jsonDeepEquals(result, _j(c[2])), isTrue, reason: 'got $result');
        expect(jsonDeepEquals(target, before), isTrue, reason: 'target must not be mutated');
      });
    }

    test('describeMergePatch lists leaf operations', () {
      expect(describeMergePatch(_j('{"a":{"b":1,"c":null},"d":{}}')), [
        r'$.a.b = 1',
        r'$.a.c removed',
        r'$.d made an object (existing keys kept)',
      ]);
    });
  });

  group('semanticDiff', () {
    test('added, removed, changed and type changes with paths', () {
      final d = semanticDiff(
        _j('{"a":1,"b":{"c":"x","d":true},"gone":1,"t":"1","f":1}'),
        _j('{"a":2,"b":{"c":"x","d":false,"e":null},"t":1,"f":1.5}'),
      );
      expect(d.changes.map((c) => '${c.kind.name} ${c.pathLabel}'), [
        r'changed $.a',
        r'changed $.b.d',
        r'added $.b.e',
        r'removed $.gone',
        r'typeChanged $.t',
        r'changed $.f',
      ]);
      expect((d.added, d.removed, d.changed, d.typeChanged), (1, 1, 3, 1));
      final t = d.changes.firstWhere((c) => c.kind == ChangeKind.typeChanged);
      expect(t.oldType, 'string');
      expect(t.newType, 'integer');
    });

    test('key order is ignored; identical documents', () {
      expect(semanticDiff(_j('{"a":1,"b":2}'), _j('{"b":2,"a":1}')).identical, isTrue);
      expect(semanticDiff(_j('1'), _j('1.0')).identical, isTrue);
    });

    test('arrays are aligned: insertion at the front is one addition', () {
      final d = semanticDiff(_j('[1,2,3]'), _j('[0,1,2,3]'));
      expect(d.changes.single.kind, ChangeKind.added);
      expect(d.changes.single.path, [0]);
      final r = semanticDiff(_j('["a","b","c"]'), _j('["a","c"]'));
      expect(r.changes.single.kind, ChangeKind.removed);
      expect(r.changes.single.path, [1]);
    });

    test('paired array items are compared recursively', () {
      final d = semanticDiff(_j('[{"id":1,"hp":3}]'), _j('[{"id":1,"hp":4}]'));
      expect(d.changes.single.pathLabel, r'$[0].hp');
    });
  });

  group('format detection and parsing', () {
    test('by extension and by content', () {
      expect(detectConfigFormat('', fileName: 'a.yml'), ConfigFormat.yaml);
      expect(detectConfigFormat('', fileName: 'x/settings.INI'), ConfigFormat.ini);
      expect(detectConfigFormat('{"a": 1}'), ConfigFormat.json);
      expect(detectConfigFormat('[a]\nb = 1\n'), ConfigFormat.toml);
      expect(detectConfigFormat('[Display]\nwidth = 1920\nmode = fullscreen\n'), ConfigFormat.ini);
      expect(detectConfigFormat('player:\n  hp: 3\n'), ConfigFormat.yaml);
      expect(detectConfigFormat('[1, 2]'), ConfigFormat.json);
    });

    test('every format parses to comparable values', () {
      final json = parseConfigValue('{"Display": {"width": "1920"}}', ConfigFormat.json);
      final ini = parseConfigValue('[Display]\nwidth = 1920\n', ConfigFormat.ini);
      expect(semanticDiff(json.value, ini.value).identical, isTrue);
      final toml = parseConfigValue('[Display]\nwidth = 1920\nwhen = 2026-01-02\n', ConfigFormat.toml);
      expect(toml.value, {
        'Display': {'width': 1920, 'when': '2026-01-02'},
      });
      final yaml = parseConfigValue('Display:\n  width: 1920\n', ConfigFormat.yaml);
      expect(yaml.value, {
        'Display': {'width': 1920},
      });
      expect(parseConfigValue('{', ConfigFormat.json).ok, isFalse);
      expect(parseConfigValue('oops', ConfigFormat.ini).error!.location!.line, 1);
    });
  });

  group('presets', () {
    test('built-ins are labelled examples for the sample graphics.json', () {
      expect(builtInPresets.map((p) => p.name), ['Potato mode', 'Ultra']);
      for (final p in builtInPresets) {
        expect(p.builtIn, isTrue);
        expect(p.target, kSampleGraphicsPath);
        expect(p.description, startsWith('EXAMPLE'));
        expect(p.patch, isA<Map<String, Object?>>());
      }
    });

    test('payload round trip with version', () {
      final p = ConfigPreset(
        id: 'u1',
        name: 'Mine',
        description: 'd',
        patch: const {'a': 1},
        createdAt: DateTime.utc(2026, 1, 2),
      );
      final payload = presetsPayload([p]);
      expect(payload['v'], 1);
      final back = readPresetsPayload(payload);
      expect(back.problems, isEmpty);
      expect(back.presets.single.name, 'Mine');
      expect(back.presets.single.patch, {'a': 1});
      expect(back.presets.single.createdAt, DateTime.utc(2026, 1, 2));
    });

    test('unknown versions and bad items are reported, not guessed', () {
      expect(readPresetsPayload({'v': 2, 'items': <Object?>[]}).problems.single, contains('version 2'));
      final r = readPresetsPayload({
        'v': 1,
        'items': [
          {'id': 'a', 'name': 'ok', 'patch': <String, Object?>{}},
          {'id': 'b', 'patch': 1},
          'junk',
        ],
      });
      expect(r.presets, hasLength(1));
      expect(r.problems, hasLength(2));
    });

    test('import accepts payloads, lists and single presets with fresh ids', () {
      var n = 0;
      String id() => 'new-${n++}';
      final payload = parsePresetImport(exportPresets(builtInPresets), newId: id);
      expect(payload.presets.map((p) => p.name), ['Potato mode', 'Ultra']);
      expect(payload.presets.every((p) => !p.builtIn && p.id.startsWith('new-')), isTrue);
      expect(parsePresetImport('[{"name": "x", "patch": {}}]', newId: id).presets, hasLength(1));
      expect(parsePresetImport('{"name": "y", "patch": {"a": null}}', newId: id).presets.single.name, 'y');
      expect(parsePresetImport('{"a": 1}', newId: id).problems.single, contains('Not a preset file'));
      expect(parsePresetImport('{', newId: id).problems.single, contains('Not valid JSON'));
      expect(parsePresetImport('{"v": 9, "items": []}', newId: id).problems.single, contains('version 9'));
    });

    test('applying a built-in to a sample graphics document', () {
      final doc = _j(
        '{"quality":"high","vsync":true,"postfx":{"bloom":true,"grain":true},"resolution":{"width":1920}}',
      );
      final potato = applyMergePatch(doc, builtInPresets.first.patch)! as Map<String, Object?>;
      expect(potato['quality'], 'low');
      expect((potato['postfx']! as Map<String, Object?>)['grain'], true);
      expect((potato['resolution']! as Map<String, Object?>)['width'], 1920);
      final diff = semanticDiff(doc, potato);
      expect(diff.changed, greaterThan(0));
      expect(diff.added, greaterThan(0));
    });
  });
}
