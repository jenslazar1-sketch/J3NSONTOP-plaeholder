import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/settings/app_settings.dart';
import 'package:j3nsontop_multitool/core/storage/json_store.dart';
import 'package:j3nsontop_multitool/core/theme/j3_colors.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('j3_store_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  JsonDocumentStore store(String name, {int version = 1, Map<int, JsonMigration>? migrations}) => JsonDocumentStore(
    path: p.join(tmp.path, name),
    schema: 'test.$name',
    currentVersion: version,
    defaults: () => {'value': 'default'},
    migrations: migrations,
  );

  test('missing file yields defaults with created outcome', () async {
    final r = await store('a.json').load();
    expect(r.outcome, LoadOutcome.created);
    expect(r.data['value'], 'default');
  });

  test('save then load round-trips through the envelope', () async {
    final s = store('b.json');
    await s.save({'value': 'hello', 'n': 3});
    final raw = jsonDecode(File(s.path).readAsStringSync()) as Map<String, dynamic>;
    expect(raw['schema'], 'test.b.json');
    expect(raw['version'], 1);
    final r = await s.load();
    expect(r.outcome, LoadOutcome.loaded);
    expect(r.data, {'value': 'hello', 'n': 3});
  });

  test('corrupt JSON is preserved and defaults are restored', () async {
    final s = store('c.json');
    File(s.path).writeAsStringSync('{"schema": "test.c.json", "version": 1, "data": {broken');
    final r = await s.load();
    expect(r.outcome, LoadOutcome.recoveredFromCorruption);
    expect(r.data['value'], 'default');
    expect(r.backupPath, isNotNull);
    expect(File(r.backupPath!).existsSync(), isTrue, reason: 'damaged file must never be deleted');
    expect(File(r.backupPath!).readAsStringSync(), contains('broken'));
    expect(r.message, contains('damaged'));
  });

  test('non-object and wrong-shape documents are treated as damaged', () async {
    final s = store('d.json');
    File(s.path).writeAsStringSync('[1,2,3]');
    expect((await s.load()).outcome, LoadOutcome.recoveredFromCorruption);
    File(s.path).writeAsStringSync('{"version": "one", "data": {}}');
    expect((await s.load()).outcome, LoadOutcome.recoveredFromCorruption);
  });

  test('invalid UTF-8 is treated as damaged', () async {
    final s = store('u.json');
    File(s.path).writeAsBytesSync([0xFF, 0xFE, 0xFD, 0x00, 0x7B]);
    expect((await s.load()).outcome, LoadOutcome.recoveredFromCorruption);
  });

  test('migrations run in order and the old file is backed up', () async {
    final v1 = store('m.json');
    await v1.save({'old': 5});
    final v3 = store(
      'm.json',
      version: 3,
      migrations: {
        1: (d) => {'renamed': d['old']},
        2: (d) => {...d, 'doubled': (d['renamed'] as int) * 2},
      },
    );
    final r = await v3.load();
    expect(r.outcome, LoadOutcome.migrated);
    expect(r.fromVersion, 1);
    expect(r.data, {'renamed': 5, 'doubled': 10});
    expect(File(r.backupPath!).existsSync(), isTrue);
    // The migrated document was persisted at the new version.
    final again = await v3.load();
    expect(again.outcome, LoadOutcome.loaded);
    expect(again.data['doubled'], 10);
  });

  test('missing migration step recovers instead of crashing', () async {
    await store('g.json').save({'x': 1});
    final r = await store('g.json', version: 3, migrations: {1: (d) => d}).load();
    expect(r.outcome, LoadOutcome.recoveredFromCorruption);
  });

  test('document from a newer app version is preserved, not overwritten', () async {
    final s = store('n.json');
    File(s.path).writeAsStringSync(jsonEncode({'schema': 'test.n.json', 'version': 9, 'data': {'future': true}}));
    final r = await s.load();
    expect(r.outcome, LoadOutcome.recoveredFromNewerVersion);
    expect(File(r.backupPath!).readAsStringSync(), contains('future'));
  });

  test('interrupted save leaves a recoverable temp file', () async {
    final s = store('t.json');
    File('${s.path}.tmp').writeAsStringSync(jsonEncode({'schema': 'test.t.json', 'version': 1, 'data': {'value': 'from-temp'}}));
    final r = await s.load();
    expect(r.outcome, LoadOutcome.recoveredFromTemp);
    expect(r.data['value'], 'from-temp');
  });

  test('concurrent saves are serialised and the last one wins', () async {
    final s = store('s.json');
    await Future.wait([for (var i = 0; i < 25; i++) s.save({'i': i})]);
    final r = await s.load();
    expect(r.data['i'], 24);
    expect(File('${s.path}.tmp').existsSync(), isFalse);
  });

  group('AppSettings tolerant decoding', () {
    test('bad fields fall back individually', () {
      final s = AppSettings.fromJson({
        'skipIntro': true,
        'intensity': 'loud',
        'volume': 7.5,
        'accent': 'nope',
        'motion': 'reduced',
        'scanlines': 0,
      });
      expect(s.skipIntro, isTrue);
      expect(s.intensity, const AppSettings().intensity);
      expect(s.volume, 1.0, reason: 'clamped to max');
      expect(s.accent, AccentPreset.neon);
      expect(s.motion, MotionPreference.reduced);
      expect(s.scanlines, isTrue);
    });

    test('round trip', () {
      const s = AppSettings(skipIntro: true, intensity: 0.3, accent: AccentPreset.ember, lowEffects: true, sound: true);
      final back = AppSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.toJson(), s.toJson());
    });
  });
}
