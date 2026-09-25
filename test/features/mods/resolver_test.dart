import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/mods/domain/issues.dart';
import 'package:j3nsontop_multitool/features/mods/domain/manifest.dart';
import 'package:j3nsontop_multitool/features/mods/domain/profile.dart';
import 'package:j3nsontop_multitool/features/mods/domain/resolver.dart';
import 'package:pub_semver/pub_semver.dart';

import 'mod_fixtures.dart';

Map<String, ModManifest> lib(List<ModManifest> ms) => {for (final m in ms) m.id: m};

List<ResolutionCode> codes(ResolutionReport r, [IssueSeverity? s]) => [
  for (final i in r.issues)
    if (s == null || i.severity == s) i.code,
];

const neonDungeon = TargetGame(id: 'neon-dungeon', version: null, source: TargetGameSource.gameJson);

TargetGame game(String id, String version) =>
    TargetGame(id: id, version: Version.parse(version), source: TargetGameSource.gameJson);

void main() {
  final core = manifestOf('core-patch', targets: ['config/core.ini']);
  final hardcore = manifestOf(
    'hardcore-balance',
    version: '2.0.1',
    targets: ['config/balance.toml', 'data/items.csv'],
    deps: [
      {'id': 'core-patch', 'version': '^1.0.0'},
    ],
  );
  final brutal = manifestOf(
    'brutal-mode',
    version: '0.9.0',
    targets: ['config/balance.toml'],
    deps: [
      {'id': 'core-patch'},
    ],
  );
  final hud = manifestOf('neon-hud', version: '1.2.0', targets: ['data/ui/hud.json']);

  test('clean profile resolves without issues', () {
    final r = ModResolver.resolve(
      profile: profileOf('p', ['core-patch', 'hardcore-balance', 'neon-hud']),
      library: lib([core, hardcore, hud]),
    );
    expect(r.issues, isEmpty);
    expect(r.canApply, isTrue);
    expect(r.order, ['core-patch', 'hardcore-balance', 'neon-hud']);
  });

  test('disabled entries are ignored', () {
    final r = ModResolver.resolve(
      profile: profileOf('p', ['core-patch', 'ghost'], disabled: {'ghost'}),
      library: lib([core]),
    );
    expect(r.issues, isEmpty);
    expect(r.order, ['core-patch']);
  });

  test('missing and invalid packages', () {
    final r = ModResolver.resolve(
      profile: profileOf('p', ['legacy-skin', 'broken']),
      library: lib([]),
      invalid: {'broken'},
    );
    expect(codes(r, IssueSeverity.error), [ResolutionCode.missingPackage, ResolutionCode.invalidPackage]);
    expect(r.errors.first.message, contains('legacy-skin is not in the library'));
    expect(r.canApply, isFalse);
  });

  test('required dependency missing from the library', () {
    final legacy = manifestOf(
      'legacy-skin',
      deps: [
        {'id': 'retro-core', 'version': '>=1.0.0'},
      ],
    );
    final r = ModResolver.resolve(profile: profileOf('p', ['legacy-skin']), library: lib([legacy]));
    expect(codes(r), [ResolutionCode.missingDependency]);
    expect(r.errors.single.message, contains('requires retro-core >=1.0.0'));
    expect(r.errors.single.relatedId, 'retro-core');
  });

  test('required dependency present but not enabled', () {
    final r = ModResolver.resolve(
      profile: profileOf('p', ['core-patch', 'hardcore-balance'], disabled: {'core-patch'}),
      library: lib([core, hardcore]),
    );
    expect(codes(r), [ResolutionCode.dependencyNotEnabled]);
    expect(r.errors.single.message, contains('not enabled'));
  });

  test('version mismatch', () {
    final core2 = manifestOf('core-patch', version: '2.1.0');
    final r = ModResolver.resolve(
      profile: profileOf('p', ['core-patch', 'hardcore-balance']),
      library: lib([core2, hardcore]),
    );
    expect(codes(r), [ResolutionCode.dependencyVersionMismatch]);
    expect(r.errors.single.message, contains('^1.0.0'));
    expect(r.errors.single.message, contains('2.1.0'));
  });

  test('dependency ordered after its dependent, and the sort fix', () {
    final profile = profileOf('p', ['neon-hud', 'hardcore-balance', 'core-patch']);
    final library = lib([core, hardcore, hud]);
    final r = ModResolver.resolve(profile: profile, library: library);
    expect(codes(r), [ResolutionCode.dependencyOrder]);
    expect(r.hasOrderProblems, isTrue);
    expect(r.errors.single.message, contains('core-patch must be applied before hardcore-balance'));

    final sorted = ModResolver.sortByDependencies(profile, library);
    expect(sorted.changed, isTrue);
    // Stable: neon-hud keeps its place, core-patch moves before hardcore.
    expect(sorted.mods.map((m) => m.id), ['neon-hud', 'core-patch', 'hardcore-balance']);
    final fixed = ModResolver.resolve(
      profile: profile.copyWith(mods: sorted.mods),
      library: library,
    );
    expect(fixed.issues, isEmpty);
  });

  test('sortByDependencies keeps an already valid order and disabled positions', () {
    final profile = profileOf('p', ['core-patch', 'ghost', 'hardcore-balance', 'neon-hud'], disabled: {'ghost'});
    final sorted = ModResolver.sortByDependencies(profile, lib([core, hardcore, hud]));
    expect(sorted.changed, isFalse);
    expect(sorted.mods, profile.mods);
  });

  test('sortByDependencies handles chains and reports cycles as unsortable', () {
    final a = manifestOf(
      'a-mod',
      deps: [
        {'id': 'b-mod'},
      ],
    );
    final b = manifestOf(
      'b-mod',
      deps: [
        {'id': 'c-mod'},
      ],
    );
    final c = manifestOf('c-mod');
    final s = ModResolver.sortByDependencies(profileOf('p', ['a-mod', 'b-mod', 'c-mod']), lib([a, b, c]));
    expect(s.mods.map((m) => m.id), ['c-mod', 'b-mod', 'a-mod']);
    expect(s.unsortable, isEmpty);

    final x = manifestOf(
      'cycle-a',
      deps: [
        {'id': 'cycle-b'},
      ],
    );
    final y = manifestOf(
      'cycle-b',
      deps: [
        {'id': 'cycle-a'},
      ],
    );
    final s2 = ModResolver.sortByDependencies(profileOf('p', ['cycle-a', 'cycle-b', 'c-mod']), lib([x, y, c]));
    expect(s2.mods.map((m) => m.id), ['c-mod', 'cycle-a', 'cycle-b']);
    expect(s2.unsortable, ['cycle-a', 'cycle-b']);
  });

  test('cycle reported with the full path, not as ordering errors', () {
    final a = manifestOf(
      'cycle-a',
      deps: [
        {'id': 'cycle-b'},
      ],
    );
    final b = manifestOf(
      'cycle-b',
      deps: [
        {'id': 'cycle-a'},
      ],
    );
    final r = ModResolver.resolve(profile: profileOf('p', ['cycle-a', 'cycle-b']), library: lib([a, b]));
    expect(codes(r), [ResolutionCode.cycle]);
    expect(r.errors.single.message, 'Dependency cycle: cycle-a -> cycle-b -> cycle-a');
    expect(r.cycles.single, ['cycle-a', 'cycle-b', 'cycle-a']);
  });

  test('longer cycle path', () {
    final a = manifestOf(
      'x-one',
      deps: [
        {'id': 'x-two'},
      ],
    );
    final b = manifestOf(
      'x-two',
      deps: [
        {'id': 'x-three'},
      ],
    );
    final c = manifestOf(
      'x-three',
      deps: [
        {'id': 'x-one'},
      ],
    );
    final r = ModResolver.resolve(profile: profileOf('p', ['x-two', 'x-one', 'x-three']), library: lib([a, b, c]));
    expect(r.cycles.single, ['x-two', 'x-three', 'x-one', 'x-two']);
  });

  test('sample broken-deps profile: missing dependency + cycle', () {
    final legacy = manifestOf(
      'legacy-skin',
      version: '0.3.0',
      deps: [
        {'id': 'retro-core'},
      ],
    );
    final a = manifestOf(
      'cycle-a',
      deps: [
        {'id': 'cycle-b'},
      ],
    );
    final b = manifestOf(
      'cycle-b',
      deps: [
        {'id': 'cycle-a'},
      ],
    );
    final r = ModResolver.resolve(
      profile: profileOf('broken-deps', ['legacy-skin', 'cycle-a', 'cycle-b']),
      library: lib([legacy, a, b]),
    );
    expect(codes(r, IssueSeverity.error), containsAll([ResolutionCode.missingDependency, ResolutionCode.cycle]));
    expect(r.canApply, isFalse);
  });

  test('optional dependencies: absent is a note, mismatch and order are warnings', () {
    final icons = manifestOf('hd-icons', version: '1.5.0');
    final hudOpt = manifestOf(
      'neon-hud',
      optional: [
        {'id': 'hd-icons', 'version': '>=2.0.0'},
      ],
    );
    final absent = ModResolver.resolve(profile: profileOf('p', ['neon-hud']), library: lib([hudOpt, icons]));
    expect(codes(absent), [ResolutionCode.optionalAbsent]);
    expect(absent.notes.single.severity, IssueSeverity.info);
    expect(absent.canApply, isTrue);

    final wrong = ModResolver.resolve(profile: profileOf('p', ['neon-hud', 'hd-icons']), library: lib([hudOpt, icons]));
    expect(codes(wrong), [ResolutionCode.optionalVersionMismatch, ResolutionCode.optionalOrder]);
    expect(wrong.hasErrors, isFalse);
    expect(wrong.hasWarnings, isTrue);
  });

  test('declared conflicts are errors (reported once per pair)', () {
    final classic = manifestOf(
      'classic-hud',
      conflicts: [
        {'id': 'neon-hud', 'reason': 'Both replace the HUD layout.'},
      ],
    );
    final hud2 = manifestOf(
      'neon-hud',
      targets: ['data/ui/hud2.json'],
      conflicts: [
        {'id': 'classic-hud'},
      ],
    );
    final r = ModResolver.resolve(profile: profileOf('p', ['classic-hud', 'neon-hud']), library: lib([classic, hud2]));
    expect(codes(r), [ResolutionCode.conflict]);
    expect(r.errors.single.message, contains('Both replace the HUD layout.'));
  });

  test('conflict limited to a version range', () {
    final old = manifestOf(
      'old-mod',
      conflicts: [
        {'id': 'core-patch', 'version': '<1.0.0'},
      ],
    );
    final r = ModResolver.resolve(profile: profileOf('p', ['core-patch', 'old-mod']), library: lib([core, old]));
    expect(r.issues.where((i) => i.code == ResolutionCode.conflict), isEmpty);
  });

  group('compatibility', () {
    final compat = manifestOf('neon-hud', compatibility: {'game': 'neon-dungeon', 'gameVersion': '>=1.4.0 <2.0.0'});

    test('passes for a matching game.json', () {
      final r = ModResolver.resolve(
        profile: profileOf('p', ['neon-hud']),
        library: lib([compat]),
        target: game('neon-dungeon', '1.4.2'),
      );
      expect(r.issues, isEmpty);
    });

    test('fails for another game', () {
      final r = ModResolver.resolve(
        profile: profileOf('p', ['neon-hud']),
        library: lib([compat]),
        target: game('space-miner', '1.4.2'),
      );
      expect(codes(r), [ResolutionCode.incompatibleGame]);
      expect(r.errors.single.message, contains('made for neon-dungeon'));
    });

    test('fails for an out-of-range version', () {
      final r = ModResolver.resolve(
        profile: profileOf('p', ['neon-hud']),
        library: lib([compat]),
        target: game('neon-dungeon', '2.0.0'),
      );
      expect(codes(r), [ResolutionCode.incompatibleGameVersion]);
    });

    test('unknown target is a warning, not silence', () {
      final r = ModResolver.resolve(profile: profileOf('p', ['neon-hud']), library: lib([compat]));
      expect(codes(r), [ResolutionCode.unknownTarget]);
      expect(r.warnings.single.message, contains('Unknown target'));
      expect(r.canApply, isTrue);
    });

    test('known game but unknown version is a warning', () {
      final r = ModResolver.resolve(profile: profileOf('p', ['neon-hud']), library: lib([compat]), target: neonDungeon);
      expect(codes(r), [ResolutionCode.unknownTarget]);
    });

    test('target notes become warnings', () {
      final r = ModResolver.resolve(
        profile: profileOf('p', ['core-patch']),
        library: lib([core]),
        target: const TargetGame(notes: ['game.json could not be read']),
      );
      expect(codes(r), [ResolutionCode.targetNote]);
    });
  });

  test('overlaps name the winner (last applied) and are warnings', () {
    final r = ModResolver.resolve(
      profile: profileOf('conflict-demo', ['core-patch', 'hardcore-balance', 'brutal-mode']),
      library: lib([core, hardcore, brutal]),
    );
    expect(r.hasErrors, isFalse);
    expect(r.overlaps, hasLength(1));
    final o = r.overlaps.single;
    expect(o.target, 'config/balance.toml');
    expect(o.providers, ['hardcore-balance', 'brutal-mode']);
    expect(o.winner, 'brutal-mode');
    expect(o.losers, ['hardcore-balance']);
    expect(r.issues.single.code, ResolutionCode.overlap);
    expect(r.issues.single.message, contains('brutal-mode wins'));
    expect(r.warnings, isEmpty, reason: 'overlaps are listed separately from warnings');
    expect(r.hasWarnings, isTrue);
  });

  test('overlap detection is case-insensitive', () {
    final a = manifestOf('a-mod', targets: ['Data/X.txt']);
    final b = manifestOf('b-mod', targets: ['data/x.TXT']);
    final r = ModResolver.resolve(profile: profileOf('p', ['a-mod', 'b-mod']), library: lib([a, b]));
    expect(r.overlaps.single.winner, 'b-mod');
  });

  test('empty profile warns', () {
    final r = ModResolver.resolve(
      profile: const ModProfile(id: 'e', name: 'E'),
      library: const {},
    );
    expect(codes(r), [ResolutionCode.emptyProfile]);
    expect(r.canApply, isFalse);
  });
}
