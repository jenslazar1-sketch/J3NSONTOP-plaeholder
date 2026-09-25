import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/conversion_report.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_parser.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_tools.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_value.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/yaml_codec.dart';
import 'package:yaml/yaml.dart';

Object? _json(ConversionResult r) => decodeJsonStrict(r.output!);

void main() {
  group('checkYaml', () {
    test('valid document gives display values', () {
      final c = checkYaml('player:\n  name: Kaya\n  hp: 10\n1: numeric key\n');
      expect(c.valid, isTrue);
      final doc = c.documents.single! as Map<Object?, Object?>;
      expect(doc.keys, ['player', 1]);
    });

    test('syntax error has 1-based line/column and a caret snippet', () {
      final c = checkYaml('a: 1\n  b: 2\n');
      expect(c.valid, isFalse);
      expect(c.error!.location!.line, 2);
      expect(c.error!.location!.column, 4);
      expect(c.error!.snippet, contains('2 |   b: 2'));
    });

    test('duplicate keys are errors', () {
      final c = checkYaml('a: 1\na: 2\n');
      expect(c.valid, isFalse);
      expect(c.error!.message, contains('Duplicate mapping key'));
      expect(c.error!.location!.line, 2);
    });

    test('empty input', () {
      expect(checkYaml('  \n').empty, isTrue);
    });
  });

  group('yamlToJson', () {
    test('plain mapping is lossless', () {
      final r = yamlToJson('name: Kaya\nhp: 10\nratio: 0.5\nalive: true\nnothing: null\nlist: [1, "2"]\n');
      expect(r.ok, isTrue);
      expect(r.report.lossless, isTrue);
      expect(r.report.verdict, 'LOSSLESS');
      final v = _json(r)! as Map<String, Object?>;
      expect(v.keys, ['name', 'hp', 'ratio', 'alive', 'nothing', 'list']);
      expect(v['list'], [1, '2']);
    });

    test('comments are itemised with their lines', () {
      final r = yamlToJson('# header\na: 1 # trailing\nb: "x # not a comment"\nc: |\n  # not a comment either\n');
      final comments = r.report.ofKind(IssueKind.commentsDropped);
      expect(comments.map((c) => c.line), [1, 2]);
      expect(r.report.lossless, isFalse);
      expect((_json(r)! as Map<String, Object?>)['b'], 'x # not a comment');
    });

    test('anchors and aliases are expanded and reported with paths', () {
      final r = yamlToJson('base: &b\n  speed: 3\nfast: *b\nslow: *b\n');
      final aliases = r.report.ofKind(IssueKind.anchorsExpanded);
      expect(aliases, hasLength(2));
      expect(aliases.first.path, r'$.fast');
      expect(aliases.first.line, 3);
      expect(_json(r), {
        'base': {'speed': 3},
        'fast': {'speed': 3},
        'slow': {'speed': 3},
      });
    });

    test('tags are resolved and noted; directives dropped', () {
      final r = yamlToJson('%YAML 1.2\n---\nzip: !!str 01234\ncount: !!int "7"\n');
      expect(_json(r), {'zip': '01234', 'count': 7});
      expect(r.report.ofKind(IssueKind.tagsResolved), hasLength(2));
      expect(r.report.ofKind(IssueKind.directivesDropped).single.line, 1);
    });

    test('non-string keys are stringified and collisions reported', () {
      final r = yamlToJson('1: one\n"1": again\ntrue: yes\n~: nil\n[a, b]: complex\n');
      final v = _json(r)! as Map<String, Object?>;
      expect(v, {'1': 'again', 'true': 'yes', 'null': 'nil', '["a","b"]': 'complex'});
      expect(r.report.ofKind(IssueKind.nonStringKeys), hasLength(4));
      expect(r.report.ofKind(IssueKind.duplicateKeys), hasLength(1));
    });

    test('non-finite floats and number notation', () {
      final r = yamlToJson('a: .inf\nb: -.inf\nc: .nan\nd: 0x1F\ne: 0o17\nf: 1e3\n');
      final v = _json(r)! as Map<String, Object?>;
      expect(v['a'], '.inf');
      expect(v['c'], '.nan');
      expect(v['d'], 31);
      expect(v['e'], 15);
      expect(v['f'], 1000.0);
      expect(r.report.ofKind(IssueKind.nonFiniteNumber), hasLength(3));
      expect(r.report.ofKind(IssueKind.numberNotation).map((i) => i.path), [r'$.d', r'$.e', r'$.f']);
    });

    test('merge key is not applied and reported', () {
      final r = yamlToJson('base: &b {x: 1}\nderived:\n  <<: *b\n  y: 2\n');
      expect(r.report.has(IssueKind.mergeKeyNotApplied), isTrue);
      expect((_json(r)! as Map<String, Object?>)['derived'], {
        '<<': {'x': 1},
        'y': 2,
      });
    });

    test('multi-document streams: array or first only', () {
      const text = 'a: 1\n---\nb: 2\n---\nc: 3\n';
      final all = yamlToJson(text);
      expect(_json(all), [
        {'a': 1},
        {'b': 2},
        {'c': 3},
      ]);
      expect(all.report.ofKind(IssueKind.multiDocument), hasLength(1));
      final first = yamlToJson(text, multiDoc: YamlMultiDoc.first);
      expect(_json(first), {'a': 1});
      expect(first.report.ofKind(IssueKind.multiDocument).map((i) => i.line), [2, 4]); // the --- lines
    });

    test('invalid YAML fails with a syntax item', () {
      final r = yamlToJson('a: [1, 2\n');
      expect(r.ok, isFalse);
      expect(r.report.failed, isTrue);
      expect(r.report.errors.single.kind, IssueKind.syntax);
    });

    test('indent option', () {
      final r = yamlToJson('a: [1]\n', indent: JsonIndent.four);
      expect(r.output, '{\n    "a": [\n        1\n    ]\n}');
    });
  });

  group('jsonToYaml emitter', () {
    test('ambiguous scalars are quoted and the output round-trips', () {
      const json =
          '{"yes":"yes","no":"No","on":"on","off":"OFF","nul":"null","tilde":"~","num":"123","float":"1.5",'
          '"date":"2001-12-14","hex":"0x1F","empty":"","space":" padded ","colon":"a: b","hash":"a #b",'
          '"dash":"-x","star":"*x","real":1.0,"int":7,"bool":false,"null":null,"quote":"say \\"hi\\"",'
          '"tab":"a\\tb","ctrl":"\\u0001","merge":"<<"}';
      final r = jsonToYaml(json);
      expect(r.ok, isTrue, reason: r.report.toText());
      expect(r.report.verified, isTrue);
      final back = yamlNodeToJsonLike(loadYamlNode(r.output!));
      expect(jsonDeepEquals(back, decodeJsonStrict(json), orderedKeys: true), isTrue);
      expect(r.output, contains('"yes": "yes"'));
      expect(r.output, contains('num: "123"'));
      expect(r.output, contains('real: 1.0'));
      expect(r.report.ofKind(IssueKind.quotingAdded).length, greaterThanOrEqualTo(10));
      expect(r.report.lossless, isTrue);
    });

    test('multiline strings become literal blocks with correct chomping', () {
      const json = '{"strip":"a\\nb","clip":"a\\nb\\n","keep":"a\\n\\n\\n","list":["x\\ny"],"lead":"\\nfirst"}';
      final r = jsonToYaml(json);
      expect(r.ok, isTrue, reason: r.report.toText());
      expect(r.output, contains('strip: |-\n  a\n  b\n'));
      expect(r.output, contains('clip: |\n  a\n  b\n'));
      expect(r.output, contains('keep: |+\n  a\n\n\n'));
      final back = yamlNodeToJsonLike(loadYamlNode(r.output!));
      expect(jsonDeepEquals(back, decodeJsonStrict(json)), isTrue);
    });

    test('strings that cannot be literal blocks fall back to double quotes', () {
      const json = '{"indented":"  a\\nb","blankline":"a\\n  \\nb","cr":"a\\r\\nb"}';
      final r = jsonToYaml(json);
      expect(r.ok, isTrue, reason: r.report.toText());
      expect(r.output, contains(r'indented: "  a\nb"'));
      expect(r.output, contains(r'cr: "a\r\nb"'));
    });

    test('nested structures and empty containers', () {
      const json = '{"a":{"b":[{"c":1,"d":[]},[1,[2]],{}],"e":{}},"top":[]}';
      final r = jsonToYaml(json);
      expect(r.ok, isTrue, reason: r.report.toText());
      expect(r.output, 'a:\n  b:\n    - c: 1\n      d: []\n    - - 1\n      - - 2\n    - {}\n  e: {}\ntop: []\n');
    });

    test('top-level scalars and arrays', () {
      expect(jsonToYaml('"yes"').output, '"yes"\n');
      expect(jsonToYaml('[1, "a"]').output, '- 1\n- a\n');
      expect(jsonToYaml('{}').output, '{}\n');
    });

    test('invalid JSON reports the location', () {
      final r = jsonToYaml('{"a": }');
      expect(r.ok, isFalse);
      expect(r.report.errors.single.message, contains('line 1, column 7'));
    });

    test('duplicate JSON keys are reported as losses', () {
      final r = jsonToYaml('{"a": 1, "a": 2}');
      expect(r.ok, isTrue);
      expect(r.report.ofKind(IssueKind.duplicateKeys), hasLength(1));
      expect(r.report.lossless, isFalse);
    });

    test('YAML -> JSON -> YAML keeps the data', () {
      const yaml = 'server:\n  host: example.local\n  ports: [80, 443]\n  tls: true\nnames:\n  - "on"\n  - off-peak\n';
      final json = yamlToJson(yaml);
      final back = jsonToYaml(json.output!);
      expect(back.ok, isTrue);
      expect(
        jsonDeepEquals(yamlNodeToJsonLike(loadYamlNode(back.output!)), yamlNodeToJsonLike(loadYamlNode(yaml))),
        isTrue,
      );
    });
  });
}
