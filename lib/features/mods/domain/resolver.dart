import 'package:pub_semver/pub_semver.dart';

import '../../../core/utils/safe_path.dart';
import 'issues.dart';
import 'manifest.dart';
import 'profile.dart';

/// Where the target game's identity came from.
enum TargetGameSource {
  gameJson('game.json'),
  profile('profile'),
  unknown('unknown');

  const TargetGameSource(this.label);
  final String label;
}

/// Identity of the game in a profile's target folder.
class TargetGame {
  const TargetGame({this.id, this.name, this.version, this.source = TargetGameSource.unknown, this.notes = const []});

  static const TargetGame unknown = TargetGame();

  final String? id;
  final String? name;
  final Version? version;
  final TargetGameSource source;

  /// Problems found while identifying the target (e.g. unreadable game.json).
  final List<String> notes;

  bool get isKnown => id != null;

  @override
  String toString() {
    if (!isKnown) return 'unknown target';
    return '${name ?? id}${version != null ? ' $version' : ''} (from ${source.label})';
  }
}

/// Machine-readable reason of a resolution finding.
enum ResolutionCode {
  missingPackage,
  invalidPackage,
  duplicateEntry,
  missingDependency,
  dependencyNotEnabled,
  dependencyVersionMismatch,
  dependencyOrder,
  optionalVersionMismatch,
  optionalOrder,
  optionalAbsent,
  cycle,
  conflict,
  incompatibleGame,
  incompatibleGameVersion,
  unknownTarget,
  targetNote,
  overlap,
  emptyProfile,
}

class ResolutionIssue {
  const ResolutionIssue({
    required this.severity,
    required this.code,
    required this.packageId,
    required this.message,
    this.relatedId,
    this.path = const [],
  });

  final IssueSeverity severity;
  final ResolutionCode code;

  /// The package the finding is about (empty for profile-wide findings).
  final String packageId;
  final String? relatedId;
  final String message;

  /// Full cycle path for [ResolutionCode.cycle], e.g. `[a, b, a]`.
  final List<String> path;

  bool get isError => severity == IssueSeverity.error;

  @override
  String toString() => '${severity.label} $message';
}

/// Several enabled packages write the same target file; the last one wins.
class FileOverlap {
  const FileOverlap({required this.target, required this.providers});

  /// Target path as written by the winning package.
  final String target;

  /// Providing packages in application order.
  final List<String> providers;

  String get winner => providers.last;
  List<String> get losers => providers.sublist(0, providers.length - 1);
}

/// Result of resolving a profile against the library.
class ResolutionReport {
  const ResolutionReport({
    required this.order,
    required this.issues,
    required this.overlaps,
    required this.cycles,
    required this.target,
  });

  /// Enabled package ids in application order.
  final List<String> order;
  final List<ResolutionIssue> issues;
  final List<FileOverlap> overlaps;
  final List<List<String>> cycles;
  final TargetGame target;

  List<ResolutionIssue> get errors => issues.where((i) => i.severity == IssueSeverity.error).toList();

  /// Warnings except overlaps (listed separately).
  List<ResolutionIssue> get warnings =>
      issues.where((i) => i.severity == IssueSeverity.warning && i.code != ResolutionCode.overlap).toList();
  List<ResolutionIssue> get notes => issues.where((i) => i.severity == IssueSeverity.info).toList();

  bool get hasErrors => issues.any((i) => i.isError);

  /// Warnings (including overlaps) the user must acknowledge before applying.
  bool get hasWarnings => issues.any((i) => i.severity == IssueSeverity.warning);

  bool get canApply => !hasErrors && order.isNotEmpty;

  /// True when the "sort by dependencies" fix would help.
  bool get hasOrderProblems =>
      issues.any((i) => i.code == ResolutionCode.dependencyOrder || i.code == ResolutionCode.optionalOrder);

  List<ResolutionIssue> forPackage(String id) => issues.where((i) => i.packageId == id).toList();
}

class SortResult {
  const SortResult({required this.mods, required this.changed, required this.unsortable});
  final List<ProfileMod> mods;
  final bool changed;

  /// Enabled packages that could not be ordered because of a cycle.
  final List<String> unsortable;
}

/// Profile resolution (docs/MOD_FORMAT.md "Resolution"). Pure and
/// synchronous: all inputs are in memory.
abstract final class ModResolver {
  /// [library] maps ids to valid manifests; [invalid] lists ids present in
  /// the library whose package failed validation.
  static ResolutionReport resolve({
    required ModProfile profile,
    required Map<String, ModManifest> library,
    Set<String> invalid = const {},
    TargetGame target = TargetGame.unknown,
  }) {
    final issues = <ResolutionIssue>[];
    void add(
      IssueSeverity s,
      ResolutionCode code,
      String pkg,
      String message, {
      String? related,
      List<String> path = const [],
    }) => issues.add(
      ResolutionIssue(severity: s, code: code, packageId: pkg, message: message, relatedId: related, path: path),
    );

    // 1. Enabled entries exist.
    final order = <String>[];
    final seen = <String>{};
    for (final m in profile.mods) {
      if (!m.enabled) continue;
      if (!seen.add(m.id)) {
        add(
          IssueSeverity.error,
          ResolutionCode.duplicateEntry,
          m.id,
          '${m.id} is listed more than once in the profile',
        );
        continue;
      }
      order.add(m.id);
    }
    if (order.isEmpty) {
      add(IssueSeverity.warning, ResolutionCode.emptyProfile, '', 'No packages are enabled in this profile');
    }
    final index = {for (var i = 0; i < order.length; i++) order[i]: i};
    final active = <String, ModManifest>{};
    for (final id in order) {
      final man = library[id];
      if (man != null) {
        active[id] = man;
      } else if (invalid.contains(id)) {
        add(
          IssueSeverity.error,
          ResolutionCode.invalidPackage,
          id,
          'Package $id in the library failed validation; open it in the library to see why',
        );
      } else {
        add(IssueSeverity.error, ResolutionCode.missingPackage, id, 'Missing package: $id is not in the library');
      }
    }

    // 3. Cycles among enabled packages (required + enabled optional edges).
    final edges = <String, List<String>>{
      for (final e in active.entries)
        e.key: [
          for (final d in [...e.value.dependencies, ...e.value.optionalDependencies])
            if (active.containsKey(d.id)) d.id,
        ],
    };
    final cycles = _findCycles(order.where(active.containsKey).toList(), edges);
    for (final c in cycles) {
      add(
        IssueSeverity.error,
        ResolutionCode.cycle,
        c.first,
        'Dependency cycle: ${c.join(' -> ')}',
        related: c.length > 1 ? c[1] : null,
        path: c,
      );
    }
    bool sameCycle(String a, String b) => cycles.any((c) => c.contains(a) && c.contains(b));

    // 2. Dependencies.
    for (final id in order) {
      final man = active[id];
      if (man == null) continue;
      for (final dep in man.dependencies) {
        final depMan = library[dep.id];
        if (depMan == null && !invalid.contains(dep.id)) {
          add(
            IssueSeverity.error,
            ResolutionCode.missingDependency,
            id,
            'Missing dependency: $id requires ${dep.id}${dep.isAny ? '' : ' ${dep.constraintText}'}, which is not in the library',
            related: dep.id,
          );
          continue;
        }
        if (!index.containsKey(dep.id)) {
          add(
            IssueSeverity.error,
            ResolutionCode.dependencyNotEnabled,
            id,
            'Missing dependency: $id requires ${dep.id}, which is not enabled in this profile',
            related: dep.id,
          );
          continue;
        }
        if (depMan == null) continue; // invalid package already reported
        if (!dep.allows(depMan.version)) {
          add(
            IssueSeverity.error,
            ResolutionCode.dependencyVersionMismatch,
            id,
            'Version mismatch: $id requires ${dep.id} ${dep.constraintText}, but the library has ${depMan.version}',
            related: dep.id,
          );
        }
        if (index[dep.id]! > index[id]! && !sameCycle(id, dep.id)) {
          add(
            IssueSeverity.error,
            ResolutionCode.dependencyOrder,
            id,
            'Ordered after dependent: ${dep.id} must be applied before $id (use "Sort by dependencies")',
            related: dep.id,
          );
        }
      }
      for (final opt in man.optionalDependencies) {
        final optMan = active[opt.id];
        if (optMan == null) {
          add(
            IssueSeverity.info,
            ResolutionCode.optionalAbsent,
            id,
            '$id can use ${opt.id}${opt.isAny ? '' : ' ${opt.constraintText}'} (optional, not enabled)',
            related: opt.id,
          );
          continue;
        }
        if (!opt.allows(optMan.version)) {
          add(
            IssueSeverity.warning,
            ResolutionCode.optionalVersionMismatch,
            id,
            'Optional dependency mismatch: $id works with ${opt.id} ${opt.constraintText}, but ${optMan.version} is enabled',
            related: opt.id,
          );
        }
        if (index[opt.id]! > index[id]! && !sameCycle(id, opt.id)) {
          add(
            IssueSeverity.warning,
            ResolutionCode.optionalOrder,
            id,
            'Optional dependency ${opt.id} should be applied before $id (use "Sort by dependencies")',
            related: opt.id,
          );
        }
      }
    }

    // 4. Declared conflicts.
    final reported = <String>{};
    for (final id in order) {
      final man = active[id];
      if (man == null) continue;
      for (final c in man.conflicts) {
        final other = active[c.id];
        if (other == null || !c.allows(other.version)) continue;
        final key = ([id, c.id]..sort()).join('|');
        if (!reported.add(key)) continue;
        add(
          IssueSeverity.error,
          ResolutionCode.conflict,
          id,
          'Conflict: $id cannot be enabled together with ${c.id}'
          '${c.reason != null && c.reason!.isNotEmpty ? ' (${c.reason})' : ''}',
          related: c.id,
        );
      }
    }

    // 5. Compatibility with the target game.
    for (final note in target.notes) {
      add(IssueSeverity.warning, ResolutionCode.targetNote, '', note);
    }
    for (final id in order) {
      final man = active[id];
      if (man == null) continue;
      final compat = man.compatibility;
      if (compat.isEmpty) continue;
      if (!target.isKnown) {
        add(
          IssueSeverity.warning,
          ResolutionCode.unknownTarget,
          id,
          'Unknown target: $id is made for ${compat.toString()}, but the target has no game.json and the profile '
          'declares no game, so compatibility cannot be checked',
        );
        continue;
      }
      if (compat.game != null && compat.game != target.id) {
        add(
          IssueSeverity.error,
          ResolutionCode.incompatibleGame,
          id,
          'Incompatible: $id is made for ${compat.game}, but the target is ${target.id}',
        );
        continue;
      }
      final range = compat.gameVersion;
      if (range != null) {
        if (target.version == null) {
          add(
            IssueSeverity.warning,
            ResolutionCode.unknownTarget,
            id,
            'Unknown target version: $id needs ${compat.game ?? target.id} ${compat.gameVersionText}, but the '
            'target version is unknown',
          );
        } else if (!range.allows(target.version!)) {
          add(
            IssueSeverity.error,
            ResolutionCode.incompatibleGameVersion,
            id,
            'Incompatible: $id needs ${compat.game ?? target.id} ${compat.gameVersionText}, but the target is '
            '${target.version}',
          );
        }
      }
    }

    // 6. Overlaps (last one wins).
    final providers = <String, List<String>>{};
    final display = <String, String>{};
    for (final id in order) {
      final man = active[id];
      if (man == null) continue;
      for (final f in man.files) {
        final key = SafePath.collisionKey(f.target);
        (providers[key] ??= []).add(id);
        display[key] = f.target;
      }
    }
    final overlaps = <FileOverlap>[];
    for (final e in providers.entries) {
      if (e.value.length < 2) continue;
      final o = FileOverlap(target: display[e.key]!, providers: e.value);
      overlaps.add(o);
      add(
        IssueSeverity.warning,
        ResolutionCode.overlap,
        o.winner,
        'Overlap: ${o.target} is written by ${o.providers.join(', ')}; ${o.winner} wins (applied last)',
        related: o.losers.last,
      );
    }
    overlaps.sort((a, b) => a.target.compareTo(b.target));

    // Stable output: errors first, then warnings, then notes.
    final sorted = [for (final s in IssueSeverity.values) ...issues.where((i) => i.severity == s)];
    return ResolutionReport(order: order, issues: sorted, overlaps: overlaps, cycles: cycles, target: target);
  }

  /// Stable topological fix: dependencies (and enabled optional
  /// dependencies) move before their dependents; otherwise the existing
  /// order is kept. Disabled entries keep their relative place. Packages in
  /// a cycle keep their order and are reported as [SortResult.unsortable].
  static SortResult sortByDependencies(ModProfile profile, Map<String, ModManifest> library) {
    final mods = profile.mods;
    final enabledIndex = <String, int>{};
    for (var i = 0; i < mods.length; i++) {
      if (mods[i].enabled) enabledIndex.putIfAbsent(mods[i].id, () => i);
    }
    // indegree[i] = number of unsatisfied prerequisites of entry i.
    final prereqs = List<Set<int>>.generate(mods.length, (_) => <int>{});
    for (var i = 0; i < mods.length; i++) {
      final m = mods[i];
      if (!m.enabled) continue;
      final man = library[m.id];
      if (man == null) continue;
      for (final d in [...man.dependencies, ...man.optionalDependencies]) {
        final j = enabledIndex[d.id];
        if (j != null && j != i) prereqs[i].add(j);
      }
    }
    final placed = List<bool>.filled(mods.length, false);
    final result = <ProfileMod>[];
    while (true) {
      var pick = -1;
      for (var i = 0; i < mods.length; i++) {
        if (placed[i]) continue;
        if (prereqs[i].every((j) => placed[j])) {
          pick = i;
          break;
        }
      }
      if (pick < 0) break;
      placed[pick] = true;
      result.add(mods[pick]);
    }
    final unsortable = <String>[];
    for (var i = 0; i < mods.length; i++) {
      if (!placed[i]) {
        result.add(mods[i]);
        unsortable.add(mods[i].id);
      }
    }
    var changed = false;
    for (var i = 0; i < mods.length; i++) {
      if (mods[i].id != result[i].id) {
        changed = true;
        break;
      }
    }
    return SortResult(mods: result, changed: changed, unsortable: unsortable);
  }

  /// Finds dependency cycles among [nodes] (in profile order). Each cycle is
  /// returned once as a closed path starting and ending at its earliest
  /// member, e.g. `[cycle-a, cycle-b, cycle-a]`.
  static List<List<String>> _findCycles(List<String> nodes, Map<String, List<String>> edges) {
    // Tarjan's strongly connected components.
    var counter = 0;
    final idx = <String, int>{};
    final low = <String, int>{};
    final onStack = <String>{};
    final stack = <String>[];
    final sccs = <Set<String>>[];

    void strongConnect(String v) {
      idx[v] = counter;
      low[v] = counter;
      counter++;
      stack.add(v);
      onStack.add(v);
      for (final w in edges[v] ?? const <String>[]) {
        if (!idx.containsKey(w)) {
          strongConnect(w);
          low[v] = low[v]! < low[w]! ? low[v]! : low[w]!;
        } else if (onStack.contains(w)) {
          low[v] = low[v]! < idx[w]! ? low[v]! : idx[w]!;
        }
      }
      if (low[v] == idx[v]) {
        final scc = <String>{};
        String w;
        do {
          w = stack.removeLast();
          onStack.remove(w);
          scc.add(w);
        } while (w != v);
        if (scc.length > 1) sccs.add(scc);
      }
    }

    for (final n in nodes) {
      if (!idx.containsKey(n)) strongConnect(n);
    }

    final position = {for (var i = 0; i < nodes.length; i++) nodes[i]: i};
    final cycles = <List<String>>[];
    for (final scc in sccs) {
      final start = scc.reduce((a, b) => position[a]! <= position[b]! ? a : b);
      // DFS inside the component back to the start.
      List<String>? found;
      final visited = <String>{};
      bool dfs(String v, List<String> path) {
        for (final w in edges[v] ?? const <String>[]) {
          if (!scc.contains(w)) continue;
          if (w == start) {
            found = [...path, w];
            return true;
          }
          if (visited.add(w) && dfs(w, [...path, w])) return true;
        }
        return false;
      }

      visited.add(start);
      dfs(start, [start]);
      cycles.add(found ?? [start, start]);
    }
    cycles.sort((a, b) => position[a.first]!.compareTo(position[b.first]!));
    return cycles;
  }
}
