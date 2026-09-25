import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZipDecoder;
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:j3nsontop_multitool/core/utils/hashing.dart';
import 'package:j3nsontop_multitool/features/sample/sample_content.dart';
import 'package:toml/toml.dart';
import 'package:yaml/yaml.dart';

import 'schema_subset.dart';

void main() {
  late SampleBundle bundle;
  late Map<String, Uint8List> files;
  setUpAll(() {
    bundle = buildSampleBundle();
    files = bundle.files;
  });

  String text(String path) {
    final bytes = files[path];
    expect(bytes, isNotNull, reason: 'missing $path');
    return utf8.decode(bytes!);
  }

  group('determinism', () {
    test('building twice gives identical bytes in the same order', () {
      final again = buildSampleBundle();
      for (final (a, b) in [
        (bundle.files, again.files),
        (bundle.packages, again.packages),
        (bundle.profiles, again.profiles),
      ]) {
        expect(b.keys.toList(), a.keys.toList());
        for (final k in a.keys) {
          expect(Hashing.bytes(b[k]!), Hashing.bytes(a[k]!), reason: k);
        }
      }
    });

    test('public builders agree with the bundle', () {
      final ws = buildSampleWorkspaceFiles();
      final pk = buildSamplePackages();
      final pr = buildSampleProfiles();
      expect(ws.keys, bundle.files.keys);
      expect(pk.keys, bundle.packages.keys);
      expect(pr.keys, bundle.profiles.keys);
      for (final k in ws.keys) {
        expect(ws[k], bundle.files[k], reason: k);
      }
    });
  });

  test('contains every file listed in docs/SAMPLES.md', () {
    const expected = [
      'README.txt',
      'game/game.json',
      'game/config/settings.ini',
      'game/config/graphics.json',
      'game/config/controls.yaml',
      'game/config/balance.toml',
      'game/data/items.csv',
      'game/data/enemies.tsv',
      'game/data/ui/hud.json',
      'game/data/localization/en.json',
      'game/saves/slot1.json',
      'game/saves/save.schema.json',
      'game/sprites/hero_walk.png',
      'game/sprites/items/potion.png',
      'game/sprites/items/sword.png',
      'game/sprites/items/shield.png',
      'game/sprites/items/key.png',
      'game/sprites/items/gem.png',
      'game/sprites/items/skull.png',
      'game/textures/logo.png',
      'game/logs/game.log',
      'game/logs/crash-2026-09-01.log',
      'downloads/core-patch-1.0.0.j3mod',
      'downloads/neon-hud-1.2.0.j3mod',
      'downloads/hardcore-balance-2.0.1.j3mod',
      'downloads/brutal-mode-0.9.0.j3mod',
      'downloads/legacy-skin-0.3.0.j3mod',
      'downloads/cycle-a-1.0.0.j3mod',
      'downloads/cycle-b-1.0.0.j3mod',
      'notes/todo.md',
      'notes/unicode-名前-ünïcødé.txt',
    ];
    for (final f in expected) {
      expect(files.containsKey(f), isTrue, reason: f);
    }
    expect(files.keys.where((k) => k.startsWith('duplicates/')), isNotEmpty);
    expect(files.keys.where((k) => k.startsWith('rename-demo/IMG_')), hasLength(6));
    expect(files.containsKey('rename-demo/Screen Shot 1.txt'), isTrue);
    expect(files.containsKey('rename-demo/screen shot 2.TXT'), isTrue);
    for (final e in bundle.packages.entries) {
      expect(files['downloads/${e.key}'], e.value, reason: 'downloads/ holds the library packages');
    }
    expect(bundle.totalBytes, lessThan(1024 * 1024), reason: 'keep the sample small');
  });

  test('game.json identifies the target', () {
    final j = jsonDecode(text('game/game.json')) as Map<String, dynamic>;
    expect(j['id'], 'neon-dungeon');
    expect(j['name'], 'Neon Dungeon');
    expect(j['version'], '1.4.2');
  });

  test('every JSON document parses', () {
    final json = files.keys.where((k) => k.endsWith('.json')).toList();
    expect(json.length, greaterThanOrEqualTo(8));
    for (final k in json) {
      expect(() => jsonDecode(text(k)), returnsNormally, reason: k);
    }
    for (final e in bundle.packages.entries) {
      final entries = ZipDecoder().decodeBytes(e.value).files.where((f) => f.name.endsWith('.json')).toList();
      expect(entries, isNotEmpty);
      for (final f in entries) {
        expect(() => jsonDecode(utf8.decode(f.content)), returnsNormally, reason: '${e.key}: ${f.name}');
      }
    }
    for (final e in bundle.profiles.entries) {
      expect(() => jsonDecode(utf8.decode(e.value)), returnsNormally, reason: e.key);
    }
    final graphics = jsonDecode(text('game/config/graphics.json')) as Map<String, dynamic>;
    final values = <Object?>[];
    void walk(Object? v) {
      values.add(v);
      if (v is Map) v.values.forEach(walk);
      if (v is List) v.forEach(walk);
    }

    walk(graphics);
    expect(values.whereType<bool>(), isNotEmpty);
    expect(values.whereType<num>(), isNotEmpty);
    expect(values.whereType<String>(), isNotEmpty);
    expect(values.whereType<List<dynamic>>(), isNotEmpty);
    expect(values.where((v) => v == null), isNotEmpty);
    final en = jsonDecode(text('game/data/localization/en.json')) as Map<String, dynamic>;
    final strings = (en['strings'] as Map<String, dynamic>).values.join();
    expect(strings, contains('☠'));
    expect(strings, contains('日本語'));
  });

  test('settings.ini has a global key, the documented sections and both comment styles', () {
    final lines = const LineSplitter().convert(text('game/config/settings.ini'));
    final sections = <String>[];
    final keys = <String, List<String>>{'': []};
    var current = '';
    for (final raw in lines) {
      final l = raw.trim();
      if (l.isEmpty || l.startsWith(';') || l.startsWith('#')) continue;
      if (l.startsWith('[')) {
        expect(l.endsWith(']'), isTrue, reason: l);
        current = l.substring(1, l.length - 1);
        sections.add(current);
        keys[current] = [];
        continue;
      }
      expect(l.contains('='), isTrue, reason: 'key = value expected: $l');
      keys[current]!.add(l.split('=').first.trim());
    }
    expect(sections, ['Display', 'Audio', 'Gameplay', 'Network']);
    expect(keys['']!, contains('config_version'));
    expect(lines.where((l) => l.startsWith(';')), isNotEmpty);
    expect(lines.where((l) => l.startsWith('#')), isNotEmpty);
    // The log claims "4 sections, 27 keys".
    final count = keys.values.fold<int>(0, (s, k) => s + k.length);
    expect(text('game/logs/game.log'), contains('(4 sections, $count keys)'));
  });

  test('controls.yaml parses and uses an anchor with aliases', () {
    final src = text('game/config/controls.yaml');
    expect(src, contains('&look'));
    expect(': *look'.allMatches(src), hasLength(2));
    final doc = loadYaml(src) as YamlMap;
    final look = doc['look_defaults'];
    expect((doc['keyboard'] as YamlMap)['look'], look);
    expect((doc['gamepad'] as YamlMap)['look'], look);
    expect(((doc['keyboard'] as YamlMap)['movement'] as YamlMap)['up'], ['W', 'Up']);
    expect((doc['macros'] as YamlMap)['panic_button'], isNull);
    Object? plain(Object? v) => v is YamlMap
        ? {for (final e in v.entries) '${e.key}': plain(e.value)}
        : v is YamlList
        ? [for (final x in v) plain(x)]
        : v;
    expect(() => jsonEncode(plain(doc)), returnsNormally);
  });

  test('balance.toml parses with tables, an array of tables and date-times', () {
    for (final src in [
      text('game/config/balance.toml'),
      ..._payloads('hardcore-balance', 'config/balance.toml', bundle),
      ..._payloads('brutal-mode', 'config/balance.toml', bundle),
    ]) {
      final map = TomlDocument.parse(src).toMap();
      expect(map['player'], isA<Map<String, dynamic>>());
      expect(map['economy'], isA<Map<String, dynamic>>());
      expect((map['economy'] as Map)['drop_rates'], isA<Map<String, dynamic>>());
      final enemies = map['enemies'] as List<dynamic>;
      expect(enemies, hasLength(5));
      expect(enemies.first, isA<Map<String, dynamic>>());
      expect(map['last_tuned'], isA<TomlOffsetDateTime>());
      expect(map['season_start'], isA<TomlLocalDate>());
      expect((map['economy'] as Map)['max_gold'], 999999);
    }
    final vanilla = TomlDocument.parse(text('game/config/balance.toml')).toMap();
    final hard = TomlDocument.parse(_payloads('hardcore-balance', 'config/balance.toml', bundle).single).toMap();
    expect((hard['player'] as Map)['max_health'], lessThan((vanilla['player'] as Map)['max_health'] as int));
  });

  test('items.csv has ~20 rows incl. a quoted comma and an escaped quote', () {
    final src = text('game/data/items.csv');
    expect(src, contains('"Bow, Short"'));
    expect(src, contains('"The ""Laughing"" Skull"'));
    expect(src, contains('\r\n'));
    final rows = csv.decode(src).where((r) => r.isNotEmpty && !(r.length == 1 && r.first == '')).toList();
    expect(rows.first, ['id', 'name', 'type', 'damage', 'price', 'rarity']);
    expect(rows.length - 1, inInclusiveRange(18, 22));
    for (final r in rows) {
      expect(r, hasLength(6), reason: '$r');
    }
    final byId = {for (final r in rows.skip(1)) r[0] as String: r};
    expect(byId['short-bow']![1], 'Bow, Short');
    expect(byId['laughing-skull']![1], 'The "Laughing" Skull');
    final hard = csv.decode(_payloads('hardcore-balance', 'data/items.csv', bundle).single);
    expect(hard.where((r) => r.length == 6).map((r) => r[0]).toSet(), byId.keys.toSet()..add('id'));
  });

  test('enemies.tsv is a consistent tab-separated table', () {
    final lines = text('game/data/enemies.tsv').split('\n')..removeLast();
    final header = lines.first.split('\t');
    expect(header.first, 'id');
    for (final l in lines) {
      expect(l.split('\t'), hasLength(header.length), reason: l);
    }
    expect(lines.any((l) => l.endsWith('\t')), isTrue, reason: 'one empty cell for the demo');
  });

  group('save file', () {
    late Map<String, dynamic> schema;
    late Map<String, dynamic> save;
    setUp(() {
      schema = jsonDecode(text('game/saves/save.schema.json')) as Map<String, dynamic>;
      save = jsonDecode(text('game/saves/slot1.json')) as Map<String, dynamic>;
    });

    test('schema uses only the documented keyword subset and every feature of it', () {
      final used = schemaKeywords(schema);
      expect(used.difference(schemaSubsetKeywords), isEmpty);
      for (final k in ['required', 'additionalProperties', 'enum', 'pattern', 'maxLength', 'minimum', 'maximum']) {
        expect(used, contains(k));
      }
      final inventory = (schema['properties'] as Map)['inventory'] as Map;
      expect(inventory['type'], 'array');
      expect((inventory['items'] as Map)['type'], 'object');
    });

    test('slot1.json is valid against the schema', () {
      expect(validateSchemaSubset(save, schema), isEmpty);
      final itemIds = sampleItemIds.toSet();
      for (final stack in save['inventory'] as List<dynamic>) {
        expect(itemIds, contains((stack as Map)['id']), reason: 'inventory ids refer to items.csv');
      }
    });

    test('the validator catches broken saves', () {
      Map<String, dynamic> copy() => jsonDecode(jsonEncode(save)) as Map<String, dynamic>;
      Map<String, dynamic> player(Map<String, dynamic> s) => s['player'] as Map<String, dynamic>;
      final cases = <String, void Function(Map<String, dynamic>)>{
        'maximum': (s) => player(s)['gold'] = 1000000,
        'minimum': (s) => player(s)['level'] = 0,
        'enum': (s) => player(s)['class'] = 'bard',
        'pattern': (s) => s['savedAt'] = 'yesterday',
        'maxLength': (s) => player(s)['name'] = 'A' * 17,
        'required': (s) => s.remove('inventory'),
        'additionalProperties': (s) => player(s)['godMode'] = true,
        'type': (s) => s['slot'] = '1',
        'items': (s) => (s['inventory'] as List).add({'id': 'bomb', 'count': 0}),
      };
      cases.forEach((name, mutate) {
        final broken = copy();
        mutate(broken);
        expect(validateSchemaSubset(broken, schema), isNotEmpty, reason: name);
      });
    });
  });

  group('images', () {
    img.Image decode(String path) {
      final image = img.decodePng(files[path]!);
      expect(image, isNotNull, reason: path);
      return image!;
    }

    ({int transparent, int partial, int opaque}) alpha(img.Image im) {
      var t = 0, pa = 0, o = 0;
      for (final px in im) {
        final a = px.a.toInt();
        if (a == 0) {
          t++;
        } else if (a == 255) {
          o++;
        } else {
          pa++;
        }
      }
      return (transparent: t, partial: pa, opaque: o);
    }

    test('hero_walk.png is a 128x64 RGBA sheet of 8 distinct 32x32 frames', () {
      final sheet = decode('game/sprites/hero_walk.png');
      expect((sheet.width, sheet.height), (128, 64));
      expect(sheet.numChannels, 4);
      final a = alpha(sheet);
      expect(a.transparent, greaterThan(128 * 64 ~/ 2), reason: 'transparent background');
      expect(a.opaque, greaterThan(8 * 150));
      final frames = <String>{};
      for (var f = 0; f < 8; f++) {
        final frame = img.copyCrop(sheet, x: (f % 4) * 32, y: (f ~/ 4) * 32, width: 32, height: 32);
        frames.add(Hashing.bytes(frame.getBytes()));
        // Every frame contains the character.
        expect(alpha(frame).opaque, greaterThan(150), reason: 'frame $f');
        // Nothing crosses into the neighbouring frame.
        for (var i = 0; i < 32; i++) {
          expect(frame.getPixel(i, 0).a, 0, reason: 'frame $f top row');
          expect(frame.getPixel(0, i).a, 0, reason: 'frame $f left column');
        }
      }
      expect(frames, hasLength(8), reason: 'walk cycle frames differ (legs/arms move)');
      final hasNeonRed = sheet.any((px) => px.r == 255 && px.g == 0x17 && px.b == 0x44 && px.a == 255);
      expect(hasNeonRed, isTrue);
    });

    test('item icons are 32x32 RGBA with transparency', () {
      for (final name in ['potion', 'sword', 'shield', 'key', 'gem', 'skull']) {
        final icon = decode('game/sprites/items/$name.png');
        expect((icon.width, icon.height), (32, 32), reason: name);
        expect(icon.numChannels, 4, reason: name);
        final a = alpha(icon);
        expect(a.transparent, greaterThan(100), reason: name);
        expect(a.partial, greaterThan(0), reason: '$name has a soft shadow');
        expect(a.opaque, greaterThan(150), reason: name);
        expect(icon.getPixel(0, 0).a, 0, reason: '$name corner is transparent');
      }
    });

    test('logo.png is 256x128 with transparent, translucent (glow) and opaque pixels', () {
      final logo = decode('game/textures/logo.png');
      expect((logo.width, logo.height), (256, 128));
      final a = alpha(logo);
      expect(a.transparent, greaterThan(1000));
      expect(a.partial, greaterThan(1000));
      expect(a.opaque, greaterThan(1000));
      for (final (x, y) in [(0, 0), (255, 0), (0, 127), (255, 127)]) {
        expect(logo.getPixel(x, y).a, 0);
      }
    });

    test('rename-demo images decode', () {
      final hashes = <String>{};
      for (var i = 1; i <= 6; i++) {
        final path = 'rename-demo/IMG_000$i.png';
        final im = decode(path);
        expect(im.width, greaterThan(8));
        hashes.add(Hashing.bytes(files[path]!));
      }
      expect(hashes, hasLength(6));
    });
  });

  test('duplicates: two exact copies and one near-duplicate differing by one byte', () {
    final hud = files['game/data/ui/hud.json']!;
    final potion = files['game/sprites/items/potion.png']!;
    final dups = {for (final e in files.entries.where((e) => e.key.startsWith('duplicates/'))) e.key: e.value};
    expect(dups.values.where((b) => listEquals(b, hud)), hasLength(1));
    expect(dups.values.where((b) => listEquals(b, potion)), hasLength(1));
    final near = dups.values.where((b) => b.length == hud.length && !listEquals(b, hud)).toList();
    expect(near, hasLength(1));
    var diff = 0;
    for (var i = 0; i < hud.length; i++) {
      if (near.single[i] != hud[i]) diff++;
    }
    expect(diff, 1);
    expect(() => jsonDecode(utf8.decode(near.single)), returnsNormally);
  });

  test('game.log: ~300 consistent lines with every level and stack traces', () {
    final lines = const LineSplitter().convert(text('game/logs/game.log'));
    expect(lines.length, inInclusiveRange(280, 320));
    final entry = RegExp(
      r'^\[2026-09-01 (\d{2}:\d{2}:\d{2}\.\d{3})\] \[(TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\] \[[a-z]+\] \S.*$',
    );
    final levels = <String, int>{};
    var stackTraces = 0;
    String? lastTime;
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      final m = entry.firstMatch(l);
      if (m == null) {
        expect(l, startsWith('    at '), reason: 'line ${i + 1}: $l');
        if (!lines[i - 1].startsWith('    at ')) stackTraces++;
        continue;
      }
      levels[m.group(2)!] = (levels[m.group(2)!] ?? 0) + 1;
      final t = m.group(1)!;
      if (lastTime != null) expect(t.compareTo(lastTime), greaterThanOrEqualTo(0), reason: 'line ${i + 1}');
      lastTime = t;
    }
    expect(levels.keys.toSet(), {'TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL'});
    expect(stackTraces, greaterThanOrEqualTo(3));
    final fatal = lines.firstWhere((l) => l.contains('[FATAL]'));
    final crash = text('game/logs/crash-2026-09-01.log');
    expect(crash, contains(fatal.substring(1, 24)), reason: 'crash report time matches the FATAL entry');
    expect(crash, contains('Stack trace'));
  });

  test('text files: Unicode note and notes are well-formed', () {
    final note = text('notes/unicode-名前-ünïcødé.txt');
    expect(note, contains('💀'));
    expect(note, contains('́'));
    expect(text('notes/todo.md'), startsWith('# '));
    expect(text('README.txt'), contains('Conflict demo'));
  });
}

/// Contents of `files/<target>` inside the library package [id], read from
/// the actual archive bytes.
List<String> _payloads(String id, String target, SampleBundle bundle) {
  final name = bundle.packages.keys.firstWhere((k) => k.startsWith('$id-'));
  final archive = ZipDecoder().decodeBytes(bundle.packages[name]!);
  return [utf8.decode(archive.findFile('files/$target')!.content)];
}
