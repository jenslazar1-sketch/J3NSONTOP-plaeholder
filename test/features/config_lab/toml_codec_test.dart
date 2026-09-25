import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/conversion_report.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_parser.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_value.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/toml_codec.dart';
import 'package:toml/toml.dart';

const _balance = '''
# Neon Dungeon balance
title = "Balance"   # inline comment

[player]
hp = 100
speed = 1.5
started = 2026-09-01T12:30:00Z
birthday = 1990-05-01
alarm = 07:30:00
local = 2026-09-01T12:30:00.250

[economy]
gold_start = 1_000
tax = 0x10

[[enemies]]
name = "slime"
hp = 12

[[enemies]]
name = "bat"
hp = 8
''';

void main() {
  group('checkToml', () {
    test('valid document', () {
      final c = checkToml(_balance);
      expect(c.valid, isTrue);
      expect(c.value!['player'], isA<Map<String, Object?>>());
    });

    test('parse errors carry line and column', () {
      final c = checkToml('a = [1,\nb = 2');
      expect(c.valid, isFalse);
      expect(c.error!.location!.line, 2);
      expect(c.error!.snippet, isNotNull);
    });

    test('redefinition errors are located best-effort', () {
      final c = checkToml('[a]\nx = 1\n\n[a]\ny = 2\n');
      expect(c.valid, isFalse);
      expect(c.error!.message, contains('redefine'));
      expect(c.error!.location!.line, 4);
    });
  });

  group('tomlToJson', () {
    test('datetimes become ISO-8601 strings and every one is reported', () {
      final r = tomlToJson(_balance);
      expect(r.ok, isTrue);
      final v = decodeJsonStrict(r.output!)! as Map<String, Object?>;
      final player = v['player']! as Map<String, Object?>;
      expect(player['started'], '2026-09-01T12:30:00Z');
      expect(player['birthday'], '1990-05-01');
      expect(player['alarm'], '07:30:00');
      expect(player['local'], '2026-09-01T12:30:00.250');
      final dates = r.report.ofKind(IssueKind.datetimeToString);
      expect(dates.map((d) => d.path), [
        r'$.player.started',
        r'$.player.birthday',
        r'$.player.alarm',
        r'$.player.local',
      ]);
      expect(r.report.lossless, isFalse);
    });

    test('comments, notation and structure are reported', () {
      final r = tomlToJson(_balance);
      expect(r.report.ofKind(IssueKind.commentsDropped).map((c) => c.line), [1, 2]);
      final notation = r.report.ofKind(IssueKind.numberNotation);
      expect(notation.any((n) => n.message.contains('Hexadecimal')), isTrue);
      expect(notation.any((n) => n.line == 13), isTrue); // 1_000
      expect(r.report.has(IssueKind.structureNote), isTrue);
      final v = decodeJsonStrict(r.output!)! as Map<String, Object?>;
      expect((v['economy']! as Map<String, Object?>)['tax'], 16);
      expect(v['enemies'], [
        {'name': 'slime', 'hp': 12},
        {'name': 'bat', 'hp': 8},
      ]);
    });

    test('a "#" inside strings is not a comment', () {
      final r = tomlToJson('a = "x # y"\nb = \'\'\'\n# still text\n\'\'\'\n');
      expect(r.report.has(IssueKind.commentsDropped), isFalse);
      expect(r.report.lossless, isTrue);
    });

    test('non-finite floats become strings', () {
      final r = tomlToJson('a = inf\nb = -inf\nc = nan\n');
      expect(decodeJsonStrict(r.output!), {'a': 'inf', 'b': '-inf', 'c': 'nan'});
      expect(r.report.ofKind(IssueKind.nonFiniteNumber), hasLength(3));
    });

    test('invalid TOML fails', () {
      final r = tomlToJson('a = ');
      expect(r.ok, isFalse);
      expect(r.report.errors.single.kind, IssueKind.syntax);
    });

    test('tomlDateTimeToIso formats offsets', () {
      final m = TomlDocument.parse('a = 1979-05-27T00:32:00.999-07:00').toMap();
      expect(tomlDateTimeToIso(m['a'] as TomlDateTime), '1979-05-27T00:32:00.999-07:00');
    });
  });

  group('jsonToToml', () {
    test('flat object is lossless and verified', () {
      final r = jsonToToml('{"title": "x", "n": 1, "f": 1.0, "ok": true, "list": [1, 2]}');
      expect(r.ok, isTrue, reason: r.report.toText());
      expect(r.report.verified, isTrue);
      expect(r.report.lossless, isTrue);
      expect(TomlDocument.parse(r.output!).toMap(), {
        'title': 'x',
        'n': 1,
        'f': 1.0,
        'ok': true,
        'list': [1, 2],
      });
    });

    test('nulls are itemised errors with paths', () {
      final r = jsonToToml('{"a": null, "b": {"c": null}, "d": [1, null]}');
      expect(r.ok, isFalse);
      expect(r.report.ofKind(IssueKind.nullsUnsupported).map((i) => i.path), [r'$.a', r'$.b.c', r'$.d[1]']);
    });

    test('dropNulls removes null properties (reported) but array nulls still fail', () {
      final r = jsonToToml('{"a": null, "b": 2}', dropNulls: true);
      expect(r.ok, isTrue);
      expect(r.report.ofKind(IssueKind.nullsUnsupported).single.severity, IssueSeverity.loss);
      expect(TomlDocument.parse(r.output!).toMap(), {'b': 2});
      expect(jsonToToml('{"a": [null]}', dropNulls: true).ok, isFalse);
    });

    test('top level must be an object', () {
      final r = jsonToToml('[1, 2]');
      expect(r.ok, isFalse);
      expect(r.report.errors.single.message, contains('top-level JSON value must be an object'));
    });

    test('mixed arrays are noted; key order changes are losses', () {
      final r = jsonToToml('{"table": {"x": 1}, "after": 2, "mixed": [1, "a", {"k": 1}]}');
      expect(r.ok, isTrue, reason: r.report.toText());
      expect(r.report.ofKind(IssueKind.mixedArray).single.path, r'$.mixed');
      expect(r.report.ofKind(IssueKind.keyOrderChanged).single.path, r'$');
      expect(r.report.lossless, isFalse);
      final back = TomlDocument.parse(r.output!).toMap();
      expect(
        jsonDeepEquals(back, decodeJsonStrict('{"table": {"x": 1}, "after": 2, "mixed": [1, "a", {"k": 1}]}')),
        isTrue,
      );
    });

    test('arrays of objects become arrays of tables and round-trip', () {
      const json = '{"enemies": [{"name": "slime", "stats": {"hp": 3}}, {"name": "bat", "stats": {"hp": 1}}], "e": {}}';
      final r = jsonToToml(json);
      expect(r.ok, isTrue, reason: r.report.toText());
      expect(r.output, contains('[[enemies]]'));
      expect(jsonDeepEquals(TomlDocument.parse(r.output!).toMap(), decodeJsonStrict(json)), isTrue);
    });

    test('TOML -> JSON -> TOML round trip (without datetimes)', () {
      const toml = 'name = "x"\n[a]\nb = [1, 2]\n[[c]]\nd = "e"\n';
      final json = tomlToJson(toml);
      final back = jsonToToml(json.output!);
      expect(back.ok, isTrue);
      expect(TomlDocument.parse(back.output!).toMap(), TomlDocument.parse(toml).toMap());
    });
  });
}
