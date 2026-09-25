import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/text/diff.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/compare.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/config_format.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/conversion_report.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/ini_document.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_parser.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_tools.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/toml_codec.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/yaml_codec.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/save_editor/save_editor_controller.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/widgets/value_tree.dart';
import 'package:toml/toml.dart';

void main() {
  group('indent detection and style-preserving encoding', () {
    test('detectJsonIndent', () {
      expect(detectJsonIndent('{\n    "a": 1\n}'), JsonIndent.four);
      expect(detectJsonIndent('{\n\t"a": 1\n}'), JsonIndent.tab);
      expect(detectJsonIndent('{\n  "a": 1\n}'), JsonIndent.two);
      expect(detectJsonIndent('{"a": 1}'), JsonIndent.two);
    });

    test('encodeLike keeps indent, minified style and trailing newline', () {
      expect(encodeLike({'a': 2}, '{\n    "a": 1\n}\n'), '{\n    "a": 2\n}\n');
      expect(encodeLike({'a': 2}, '{"a":1}'), '{"a":2}');
      expect(encodeLike({'a': 2}, '{\n\t"a": 1\n}'), '{\n\t"a": 2\n}');
    });
  });

  group('parser positions', () {
    test('every value pointer maps to its offset', () {
      const text = '{"a": [10, {"b": true}], "c d": null}';
      final out = parseJsonStrict(text, recordPositions: true);
      expect(out.positions![''], 0);
      expect(out.positions!['/a'], text.indexOf('['));
      expect(out.positions!['/a/1/b'], text.indexOf('true'));
      expect(out.positions!['/c d'], text.indexOf('null'));
      expect(parseJsonStrict(text).positions, isNull);
    });

    test('parseSaveText returns positions or a located error', () {
      final (value, positions, error) = parseSaveText('{"x": 1}');
      expect(value, {'x': 1});
      expect(positions['/x'], 6);
      expect(error, isNull);
      final (_, _, bad) = parseSaveText('{"x": }');
      expect(bad!.location!.column, 7);
    });

    test('schemaCandidates look next to the save', () {
      expect(schemaCandidates('/w/game/saves/slot1.json').map((s) => s.replaceAll(r'\', '/')), [
        '/w/game/saves/slot1.schema.json',
        '/w/game/saves/save.schema.json',
      ]);
    });
  });

  group('compare helpers', () {
    test('side-by-side pairs deletions with insertions', () {
      final d = LineDiff.diffText('a\nb\nc\n', 'a\nB\nc\nd\n');
      final rows = sideBySide(d);
      expect(rows.map((r) => '${r.left?.text ?? '_'}|${r.right?.text ?? '_'}'), ['a|a', 'b|B', 'c|c', '_|d']);
    });

    test('compareConfigs detects formats and reports', () {
      final r = compareConfigs('{"a": 1}', 'a: 1\nb: 2\n', nameA: 'x.json', nameB: 'y.yaml');
      expect(r.a.format, ConfigFormat.json);
      expect(r.b.format, ConfigFormat.yaml);
      expect(r.semantic!.added, 1);
      final report = compareReport(r, nameA: 'x.json', nameB: 'y.yaml');
      expect(report, contains('A: x.json (JSON)'));
      expect(report, contains(r'+ $.b added: 2'));
      expect(report, contains('--- x.json'));
      final broken = compareConfigs('{', '{}', formatA: ConfigFormat.json);
      expect(broken.semantic, isNull);
      expect(compareReport(broken, nameA: 'A', nameB: 'B'), contains('A does not parse'));
    });
  });

  group('conversion report text', () {
    test('lists every group with verdict', () {
      const r = ConversionReport(
        from: 'YAML',
        to: 'JSON',
        verified: true,
        issues: [
          ConversionIssue.loss(IssueKind.commentsDropped, 'Comment dropped', line: 3),
          ConversionIssue.note(IssueKind.tagsResolved, 'tag', path: r'$.a'),
        ],
      );
      final t = r.toText();
      expect(t, contains('Conversion YAML -> JSON: CHANGES REPRESENTATION'));
      expect(t, contains('Round trip verified'));
      expect(t, contains('[Comments dropped] line 3: Comment dropped'));
      expect(t, contains(r'[Explicit tags resolved] $.a: tag'));
      expect(const ConversionReport(from: 'A', to: 'B').toText(), contains('No differences'));
    });
  });

  group('tree flattening', () {
    test('only expanded containers contribute rows', () {
      final v = {
        'a': {'b': 1},
        'c': [1, 2],
      };
      expect(flattenTree(v, {''}).map((r) => r.label), ['root', 'a', 'c']);
      expect(flattenTree(v, {'', '/c'}).map((r) => r.label), ['root', 'a', 'c', '[0]', '[1]']);
      expect(allContainerPointers(v), {'', '/a', '/c'});
      expect(allContainerPointers(v, limit: 1), isNull);
      expect(ancestorPointers(['a', 'b', 0]), {'', '/a', '/a/b'});
    });

    test('non-string YAML keys are labelled and stringified in paths', () {
      final doc = checkYaml('1: one\ntrue: yes\n').documents.single;
      final rows = flattenTree(doc, {''});
      expect(rows[1].label, '1 (integer key)');
      expect(rows[1].path, ['1']);
      expect(yamlDisplayToJsonLike(doc), {'1': 'one', 'true': 'yes'});
    });

    test('TOML values convert to JSON-like values for copying', () {
      final m = TomlDocument.parse('d = 2026-01-02\nf = inf\n').toMap();
      expect(tomlValueToJsonLike(m), {'d': '2026-01-02', 'f': 'inf'});
    });
  });

  group('INI edits keep a BOM', () {
    test('editing the first line preserves the byte order mark', () {
      final bom = String.fromCharCode(0xFEFF);
      final doc = IniDocument.parse('${bom}a=1\n');
      expect(doc.setValue(0, '2').toText(), '${bom}a=2\n');
    });
  });
}
