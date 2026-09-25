import '../../../core/utils/safe_path.dart';
import 'file_names.dart';
import 'text_pattern.dart';

enum RenameCase {
  keep('Keep'),
  lower('lower'),
  upper('UPPER'),
  title('Title');

  const RenameCase(this.label);
  final String label;
}

enum ExtensionMode {
  keep('Keep'),
  change('Change to'),
  remove('Remove');

  const ExtensionMode(this.label);
  final String label;
}

/// The rule set of a batch rename, applied in this order:
/// 1. find/replace on the name without extension (or the full name when
///    [includeExtension]),
/// 2. [template] (default `{name}`), wrapped by [prefix] and [suffix],
/// 3. [caseTransform] on the resulting name,
/// 4. extension keep/change/remove.
///
/// Tokens in prefix, suffix and template: `{n}` counter, `{n:3}` zero
/// padded counter, `{name}` name after find/replace, `{ext}` original
/// extension, `{parent}` parent folder, `{date}` modified date yyyy-MM-dd.
class RenameRules {
  const RenameRules({
    this.find = '',
    this.replace = '',
    this.useRegex = false,
    this.caseSensitive = true,
    this.includeExtension = false,
    this.prefix = '',
    this.suffix = '',
    this.template = '',
    this.startNumber = 1,
    this.step = 1,
    this.caseTransform = RenameCase.keep,
    this.extensionMode = ExtensionMode.keep,
    this.newExtension = '',
  });

  final String find;
  final String replace;
  final bool useRegex;
  final bool caseSensitive;
  final bool includeExtension;
  final String prefix;
  final String suffix;
  final String template;
  final int startNumber;
  final int step;
  final RenameCase caseTransform;
  final ExtensionMode extensionMode;
  final String newExtension;

  /// True when evaluating the rules may run user regex code (evaluate it
  /// inside `runBounded`).
  bool get needsBoundedEvaluation => useRegex && find.isNotEmpty;
}

/// A file considered for renaming.
class RenameItem {
  const RenameItem({required this.dir, required this.name, required this.modified, this.parentName = ''});

  /// Folder relative to the workspace root, forward slashes, '' for root.
  final String dir;
  final String name;
  final DateTime modified;

  /// Name of the containing folder (for `{parent}`).
  final String parentName;

  String get relativePath => dir.isEmpty ? name : '$dir/$name';
}

enum RenameStatus {
  unchanged('Unchanged'),
  ok('OK'),
  caseOnly('Case-only change'),
  collision('Collision'),
  duplicate('Duplicate in batch'),
  invalid('Invalid name');

  const RenameStatus(this.label);
  final String label;

  /// Statuses that must be fixed before applying.
  bool get blocks => this == collision || this == duplicate || this == invalid;
}

class RenameRow {
  const RenameRow({required this.item, required this.newName, required this.status, this.message});
  final RenameItem item;
  final String newName;
  final RenameStatus status;
  final String? message;

  bool get changes => newName != item.name;
  String get newRelativePath => item.dir.isEmpty ? newName : '${item.dir}/$newName';
}

class RenamePlan {
  const RenamePlan({required this.rows, this.error});

  /// Rows in numbering order (natural sort of relative paths).
  final List<RenameRow> rows;

  /// A rule error (bad regex, unknown token) that blocks the whole plan.
  final String? error;

  int count(RenameStatus s) => rows.where((r) => r.status == s).length;
  List<RenameRow> get changes => rows.where((r) => r.changes).toList();
  bool get hasBlocking => rows.any((r) => r.status.blocks);
  bool get canApply => error == null && !hasBlocking && rows.any((r) => r.changes);
}

final RegExp _tokenRe = RegExp(r'\{([^{}:]*)(?::([^{}]*))?\}');
const Set<String> _tokens = {'n', 'name', 'ext', 'parent', 'date'};

/// Returns an error message for unknown or malformed tokens in [template].
String? validateTemplate(String template) {
  for (final m in _tokenRe.allMatches(template)) {
    final name = m.group(1)!;
    final arg = m.group(2);
    if (!_tokens.contains(name)) {
      return 'Unknown token {$name}. Use {n}, {n:3}, {name}, {ext}, {parent} or {date}.';
    }
    if (arg != null) {
      if (name != 'n') return 'Only {n} takes a width, e.g. {n:3}';
      final w = int.tryParse(arg);
      if (w == null || w < 1 || w > 12) return 'Counter width in {n:$arg} must be 1-12';
    }
  }
  return null;
}

String _two(int v) => v.toString().padLeft(2, '0');

String _expand(String template, {required int n, required String name, required String ext, required RenameItem item}) {
  return template.replaceAllMapped(_tokenRe, (m) {
    switch (m.group(1)) {
      case 'n':
        final width = int.tryParse(m.group(2) ?? '') ?? 0;
        final digits = n.abs().toString().padLeft(width, '0');
        return n < 0 ? '-$digits' : digits;
      case 'name':
        return name;
      case 'ext':
        return ext.startsWith('.') ? ext.substring(1) : ext;
      case 'parent':
        return item.parentName;
      case 'date':
        final d = item.modified.toLocal();
        return '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';
    }
    return m.group(0)!;
  });
}

String applyCase(String s, RenameCase c) {
  switch (c) {
    case RenameCase.keep:
      return s;
    case RenameCase.lower:
      return s.toLowerCase();
    case RenameCase.upper:
      return s.toUpperCase();
    case RenameCase.title:
      final out = StringBuffer();
      var startOfWord = true;
      for (final ch in s.split('')) {
        final isSep = ch == ' ' || ch == '_' || ch == '-' || ch == '.';
        if (isSep) {
          out.write(ch);
          startOfWord = true;
        } else {
          out.write(startOfWord ? ch.toUpperCase() : ch.toLowerCase());
          startOfWord = false;
        }
      }
      return out.toString();
  }
}

/// Computes the new name of every item and its status. [existing] maps each
/// involved folder (same keys as [RenameItem.dir]) to the names of ALL
/// entries currently in it, including files outside the batch and folders.
/// Collisions are detected case-insensitively (portable to Windows/macOS).
RenamePlan planRenames({
  required List<RenameItem> items,
  required RenameRules rules,
  required Map<String, List<String>> existing,
}) {
  final sorted = [...items]..sort((a, b) => FileNames.compareNatural(a.relativePath, b.relativePath));
  RegExp? re;
  FindSpec? spec;
  if (rules.find.isNotEmpty) {
    spec = FindSpec(pattern: rules.find, isRegex: rules.useRegex, caseSensitive: rules.caseSensitive);
    try {
      re = spec.compile();
    } on FormatException catch (e) {
      return RenamePlan(rows: _unchangedRows(sorted), error: e.message);
    }
  }
  for (final (label, t) in [('Prefix', rules.prefix), ('Suffix', rules.suffix), ('Template', rules.template)]) {
    final err = validateTemplate(t);
    if (err != null) return RenamePlan(rows: _unchangedRows(sorted), error: '$label: $err');
  }
  if (rules.extensionMode == ExtensionMode.change) {
    final ext = rules.newExtension.trim().replaceFirst(RegExp(r'^\.+'), '');
    if (ext.isEmpty) {
      return RenamePlan(rows: _unchangedRows(sorted), error: 'Enter the new extension (or choose Keep/Remove)');
    }
    final err = FileNames.validate('x.$ext');
    if (err != null) return RenamePlan(rows: _unchangedRows(sorted), error: 'Extension: $err');
  }

  String replaceIn(String s) {
    if (re == null) return s;
    final out = StringBuffer();
    var last = 0;
    for (final m in re.allMatches(s)) {
      out
        ..write(s.substring(last, m.start))
        ..write(spec!.isRegex ? expandReplacement(m, rules.replace) : rules.replace);
      last = m.end;
    }
    out.write(s.substring(last));
    return out.toString();
  }

  final newNames = <String>[];
  for (var i = 0; i < sorted.length; i++) {
    final item = sorted[i];
    var (stem, ext) = FileNames.split(item.name);
    final originalExt = ext;
    if (rules.includeExtension) {
      (stem, ext) = FileNames.split(replaceIn(item.name));
    } else {
      stem = replaceIn(stem);
    }
    final n = rules.startNumber + i * rules.step;
    String expand(String t) => _expand(t, n: n, name: stem, ext: originalExt, item: item);
    final base = rules.template.isEmpty ? stem : expand(rules.template);
    final newStem = applyCase('${expand(rules.prefix)}$base${expand(rules.suffix)}', rules.caseTransform);
    final newExt = switch (rules.extensionMode) {
      ExtensionMode.keep => ext,
      ExtensionMode.remove => '',
      ExtensionMode.change => '.${rules.newExtension.trim().replaceFirst(RegExp(r'^\.+'), '')}',
    };
    newNames.add('$newStem$newExt');
  }
  return RenamePlan(rows: classify(sorted, newNames, existing));
}

List<RenameRow> _unchangedRows(List<RenameItem> items) => [
  for (final i in items) RenameRow(item: i, newName: i.name, status: RenameStatus.unchanged),
];

String _key(String dir, String name) => SafePath.collisionKey(dir.isEmpty ? name : '$dir/$name');

/// Assigns statuses to proposed [newNames] (parallel to [items]).
List<RenameRow> classify(List<RenameItem> items, List<String> newNames, Map<String, List<String>> existing) {
  // How many entries currently hold each (case-folded) name. Counting,
  // not a set, because case-sensitive file systems can hold "a" and "A".
  final occupied = <String, int>{};
  final displayName = <String, String>{};
  existing.forEach((dir, names) {
    for (final n in names) {
      final k = _key(dir, n);
      occupied[k] = (occupied[k] ?? 0) + 1;
      displayName[k] = n;
    }
  });
  for (final item in items) {
    final k = _key(item.dir, item.name);
    if (!occupied.containsKey(k)) {
      occupied[k] = 1;
      displayName[k] = item.name;
    }
  }
  // Files that change name vacate their old name.
  for (var i = 0; i < items.length; i++) {
    if (newNames[i] != items[i].name) {
      final k = _key(items[i].dir, items[i].name);
      occupied[k] = (occupied[k] ?? 1) - 1;
    }
  }
  // Duplicates are counted among renamed files only; clashing with a file
  // that keeps its name is reported as a collision instead.
  final targets = <String, int>{};
  for (var i = 0; i < items.length; i++) {
    if (newNames[i] == items[i].name) continue;
    final k = _key(items[i].dir, newNames[i]);
    targets[k] = (targets[k] ?? 0) + 1;
  }
  final rows = <RenameRow>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    final next = newNames[i];
    if (next == item.name) {
      rows.add(RenameRow(item: item, newName: next, status: RenameStatus.unchanged));
      continue;
    }
    final invalid = FileNames.validate(next);
    if (invalid != null) {
      rows.add(RenameRow(item: item, newName: next, status: RenameStatus.invalid, message: invalid));
      continue;
    }
    final k = _key(item.dir, next);
    if ((targets[k] ?? 0) > 1) {
      rows.add(
        RenameRow(
          item: item,
          newName: next,
          status: RenameStatus.duplicate,
          message: '${targets[k]} files would be named "$next" (names are compared ignoring case)',
        ),
      );
      continue;
    }
    if ((occupied[k] ?? 0) > 0) {
      rows.add(
        RenameRow(
          item: item,
          newName: next,
          status: RenameStatus.collision,
          message: '"${displayName[k] ?? next}" already exists in this folder',
        ),
      );
      continue;
    }
    final caseOnly = next.toLowerCase() == item.name.toLowerCase();
    rows.add(RenameRow(item: item, newName: next, status: caseOnly ? RenameStatus.caseOnly : RenameStatus.ok));
  }
  return rows;
}
