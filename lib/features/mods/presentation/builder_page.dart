import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/activity/activity_controller.dart';
import '../../../core/archive/safe_zip.dart';
import '../../../core/drafts/drafts.dart';
import '../../../core/platform/app_paths.dart';
import '../../../core/platform/file_access.dart';
import '../../../core/theme/effects.dart';
import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/safe_path.dart';
import '../../../core/widgets/widgets.dart';
import '../../../core/workspace/workspace_controller.dart';
import '../domain/issues.dart';
import '../domain/manifest.dart';
import '../domain/package_inspector.dart';
import '../domain/profile.dart';
import 'mods_controller.dart';
import 'mods_flows.dart';
import 'mods_widgets.dart';

/// Maximum number of files one built package may contain.
const int kBuilderMaxFiles = 2000;

/// A file chosen for the package.
@immutable
class BuilderFile {
  const BuilderFile({
    required this.path,
    required this.label,
    required this.size,
    required this.target,
    this.include = true,
    this.baseRel,
    this.rev = 0,
  });

  /// Absolute, readable path.
  final String path;
  final String label;
  final int size;

  /// Target path inside the game/project folder (editable).
  final String target;
  final bool include;

  /// Path relative to the chosen base folder (for re-mapping with a prefix).
  final String? baseRel;

  /// Bumped when [target] is changed programmatically (refreshes the field).
  final int rev;

  BuilderFile copyWith({String? target, bool? include, bool bump = false}) => BuilderFile(
    path: path,
    label: label,
    size: size,
    target: target ?? this.target,
    include: include ?? this.include,
    baseRel: baseRel,
    rev: bump ? rev + 1 : rev,
  );
}

@immutable
class BuilderState {
  const BuilderState({
    this.files = const [],
    this.baseFolder,
    this.addToLibrary = true,
    this.exportCopy = false,
    this.busy = false,
    this.result,
  });

  final List<BuilderFile> files;
  final String? baseFolder;
  final bool addToLibrary;
  final bool exportCopy;
  final bool busy;
  final ResultNote? result;

  List<BuilderFile> get included => files.where((f) => f.include).toList();

  BuilderState copyWith({
    List<BuilderFile>? files,
    String? baseFolder,
    bool clearBase = false,
    bool? addToLibrary,
    bool? exportCopy,
    bool? busy,
    ResultNote? result,
    bool clearResult = false,
  }) => BuilderState(
    files: files ?? this.files,
    baseFolder: clearBase ? null : (baseFolder ?? this.baseFolder),
    addToLibrary: addToLibrary ?? this.addToLibrary,
    exportCopy: exportCopy ?? this.exportCopy,
    busy: busy ?? this.busy,
    result: clearResult ? null : (result ?? this.result),
  );
}

/// Joins an optional prefix and a relative path into a target.
String builderTarget(String prefix, String rel) {
  final pre = prefix.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '');
  return pre.isEmpty ? rel : '$pre/$rel';
}

/// Form fields of the builder (text as typed).
class BuilderFields {
  const BuilderFields({
    required this.id,
    required this.name,
    required this.version,
    this.description = '',
    this.author = '',
    this.license = '',
    this.game = '',
    this.gameVersion = '',
    this.dependencies = '',
    this.optional = '',
    this.conflicts = '',
    this.tags = '',
  });

  final String id;
  final String name;
  final String version;
  final String description;
  final String author;
  final String license;
  final String game;
  final String gameVersion;

  /// One `id [constraint]` per line.
  final String dependencies;
  final String optional;

  /// One `id [constraint] [# reason]` per line.
  final String conflicts;

  /// Comma separated.
  final String tags;
}

List<String> _lines(String s) => [
  for (final l in s.split('\n'))
    if (l.trim().isNotEmpty) l.trim(),
];

List<Map<String, dynamic>> _refs(String text) => [
  for (final l in _lines(text))
    () {
      final sp = l.indexOf(RegExp(r'\s'));
      return sp < 0 ? {'id': l} : {'id': l.substring(0, sp), 'version': l.substring(sp).trim()};
    }(),
];

/// Builds the manifest map exactly as it will be written, so the shared
/// validator reports the same issues the importer would.
Map<String, dynamic> builderManifestMap(BuilderFields f, List<BuilderFile> files) {
  final conflicts = <Map<String, dynamic>>[];
  for (final l in _lines(f.conflicts)) {
    final hash = l.indexOf('#');
    final left = (hash < 0 ? l : l.substring(0, hash)).trim();
    final reason = hash < 0 ? null : l.substring(hash + 1).trim();
    final sp = left.indexOf(RegExp(r'\s'));
    conflicts.add({
      'id': sp < 0 ? left : left.substring(0, sp),
      if (sp >= 0) 'version': left.substring(sp).trim(),
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    });
  }
  final tags = [
    for (final t in f.tags.split(','))
      if (t.trim().isNotEmpty) t.trim(),
  ];
  return {
    'format': 'j3mod',
    'formatVersion': kManifestFormatVersion,
    'id': f.id.trim(),
    'name': f.name.trim(),
    'version': f.version.trim(),
    if (f.description.trim().isNotEmpty) 'description': f.description.trim(),
    if (f.author.trim().isNotEmpty) 'author': f.author.trim(),
    if (f.license.trim().isNotEmpty) 'license': f.license.trim(),
    if (f.game.trim().isNotEmpty || f.gameVersion.trim().isNotEmpty)
      'compatibility': {
        if (f.game.trim().isNotEmpty) 'game': f.game.trim(),
        if (f.gameVersion.trim().isNotEmpty) 'gameVersion': f.gameVersion.trim(),
      },
    'files': [
      for (final file in files)
        if (file.include) {'source': builderSource(file.target), 'target': file.target},
    ],
    if (_lines(f.dependencies).isNotEmpty) 'dependencies': _refs(f.dependencies),
    if (_lines(f.optional).isNotEmpty) 'optionalDependencies': _refs(f.optional),
    if (conflicts.isNotEmpty) 'conflicts': conflicts,
    if (tags.isNotEmpty) 'tags': tags,
  };
}

/// Archive path for a payload file: `files/<target>` (safe fallback when the
/// target itself is invalid, so only the target is reported).
String builderSource(String target) {
  try {
    return 'files/${SafePath.normalizeRelative(target)}';
  } on UnsafePathException {
    return 'files/invalid-target';
  }
}

class BuilderController extends Notifier<BuilderState> {
  @override
  BuilderState build() => const BuilderState();

  void setBase(String folder, List<BuilderFile> files) =>
      state = state.copyWith(baseFolder: folder, files: files, clearResult: true);

  void addFiles(List<BuilderFile> files) {
    final known = {for (final f in state.files) f.path};
    state = state.copyWith(files: [...state.files, ...files.where((f) => !known.contains(f.path))], clearResult: true);
  }

  void setTarget(int i, String target) => state = state.copyWith(
    files: [
      for (var j = 0; j < state.files.length; j++) j == i ? state.files[j].copyWith(target: target) : state.files[j],
    ],
  );

  void toggle(int i, bool include) => state = state.copyWith(
    files: [
      for (var j = 0; j < state.files.length; j++) j == i ? state.files[j].copyWith(include: include) : state.files[j],
    ],
  );

  void remove(int i) => state = state.copyWith(files: [...state.files]..removeAt(i));

  void clearFiles() => state = state.copyWith(files: const [], clearBase: true, clearResult: true);

  /// Re-maps base-folder files to `<prefix>/<relative path>`.
  void applyPrefix(String prefix) => state = state.copyWith(
    files: [
      for (final f in state.files)
        f.baseRel == null ? f : f.copyWith(target: builderTarget(prefix, f.baseRel!), bump: true),
    ],
  );

  void setOptions({bool? addToLibrary, bool? exportCopy}) =>
      state = state.copyWith(addToLibrary: addToLibrary, exportCopy: exportCopy);

  void setResult(ResultNote? note) =>
      state = note == null ? state.copyWith(clearResult: true) : state.copyWith(result: note);

  /// Packs and re-validates the package. Returns the built file path.
  Future<String> buildPackage({required ModManifest manifest, required String readme}) async {
    final files = state.included;
    state = state.copyWith(busy: true, clearResult: true);
    try {
      return await ref
          .read(activityProvider.notifier)
          .run<String>(
            toolId: kModsBuilderId,
            title: 'Build ${manifest.id} ${manifest.version}',
            cancellable: true,
            summary: (path) => 'Built ${p.basename(path)} (${Fmt.count(files.length, 'file')})',
            body: (op) async {
              for (final f in files) {
                if (!await File(f.path).exists()) throw StateError('Source file is gone: ${f.label}');
              }
              final dir = p.join(
                ref.read(appPathsProvider).exportStagingDir,
                'builder-${DateTime.now().microsecondsSinceEpoch}',
              );
              await Directory(dir).create(recursive: true);
              final out = p.join(dir, SafePath.sanitizeFileName('${manifest.id}-${manifest.version}.j3mod'));
              await SafeZip.create(
                out,
                [
                  ZipSource.bytes(kManifestFileName, utf8.encode('${manifest.toPrettyJson()}\n')),
                  if (readme.trim().isNotEmpty) ZipSource.bytes('README.md', utf8.encode(readme)),
                  for (final f in files) ZipSource.file(builderSource(f.target), f.path),
                ],
                token: op.token,
                onProgress: (fr) => op.progress(fr * 0.85, 'Packing'),
              );
              op.progress(0.9, 'Verifying with the package validator');
              final report = await inspectPackageInBackground(out);
              if (!report.isValid) {
                throw StateError('The built package failed validation: ${report.issues.errors.join('; ')}');
              }
              return out;
            },
          );
    } finally {
      if (ref.mounted) state = state.copyWith(busy: false);
    }
  }
}

final builderProvider = NotifierProvider<BuilderController, BuilderState>(BuilderController.new);

const _fieldKeys = [
  'id',
  'name',
  'version',
  'description',
  'author',
  'license',
  'game',
  'gameVersion',
  'deps',
  'optional',
  'conflicts',
  'tags',
  'prefix',
  'readme',
];

/// `mods.builder`: create a .j3mod from workspace or device files.
class ModBuilderPage extends ConsumerStatefulWidget {
  const ModBuilderPage({super.key});

  @override
  ConsumerState<ModBuilderPage> createState() => _ModBuilderPageState();
}

class _ModBuilderPageState extends ConsumerState<ModBuilderPage> {
  late final Map<String, TextEditingController> _c = {
    for (final k in _fieldKeys) k: ref.read(draftTextProvider('$kModsBuilderId/$k')),
  };

  @override
  void initState() {
    super.initState();
    // Sensible default for a new package (the draft keeps later edits).
    if (_c['version']!.text.isEmpty) _c['version']!.text = '1.0.0';
  }

  BuilderFields get _fields => BuilderFields(
    id: _c['id']!.text,
    name: _c['name']!.text,
    version: _c['version']!.text,
    description: _c['description']!.text,
    author: _c['author']!.text,
    license: _c['license']!.text,
    game: _c['game']!.text,
    gameVersion: _c['gameVersion']!.text,
    dependencies: _c['deps']!.text,
    optional: _c['optional']!.text,
    conflicts: _c['conflicts']!.text,
    tags: _c['tags']!.text,
  );

  Future<void> _chooseBase() async {
    final ws = ref.read(activeWorkspaceProvider);
    if (ws == null) return;
    final folder = await showWorkspaceBrowser(
      context,
      workspace: ws,
      mode: BrowseMode.pickFolder,
      title: 'Base folder (its files become the package)',
    );
    if (folder == null || !mounted) return;
    final files = <BuilderFile>[];
    try {
      await for (final e in Directory(folder).list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        if (files.length >= kBuilderMaxFiles) {
          throw StateError('The folder has more than $kBuilderMaxFiles files; choose a smaller base folder');
        }
        final rel = p.relative(e.path, from: folder).replaceAll('\\', '/');
        files.add(
          BuilderFile(
            path: e.path,
            label: rel,
            size: await e.length(),
            target: builderTarget(_c['prefix']!.text, rel),
            baseRel: rel,
          ),
        );
      }
    } catch (e) {
      ref.read(activityProvider.notifier).notify(NoticeKind.error, 'Could not read the folder: $e');
      return;
    }
    files.sort((a, b) => a.label.compareTo(b.label));
    ref.read(builderProvider.notifier).setBase(folder, files);
    if (_c['id']!.text.trim().isEmpty) _c['id']!.text = slugifyId(p.basename(folder), fallback: 'my-mod');
    if (_c['name']!.text.trim().isEmpty) _c['name']!.text = p.basename(folder);
  }

  Future<void> _addWorkspaceFile() async {
    final ws = ref.read(activeWorkspaceProvider);
    if (ws == null) return;
    final path = await showWorkspaceBrowser(context, workspace: ws, title: 'Add a file');
    if (path == null) return;
    final base = ref.read(builderProvider).baseFolder;
    final rel = base != null && SafePath.isWithin(base, path)
        ? p.relative(path, from: base).replaceAll('\\', '/')
        : p.basename(path);
    ref.read(builderProvider.notifier).addFiles([
      BuilderFile(
        path: path,
        label: p.relative(path, from: ws.rootPath).replaceAll('\\', '/'),
        size: await File(path).length(),
        target: builderTarget(_c['prefix']!.text, rel),
      ),
    ]);
  }

  Future<void> _pickDeviceFiles() async {
    try {
      final picked = await ref.read(fileAccessProvider).pickFiles(multiple: true);
      if (picked.isEmpty) return;
      ref.read(builderProvider.notifier).addFiles([
        for (final f in picked)
          BuilderFile(
            path: f.path,
            label: f.name,
            size: f.size,
            target: builderTarget(_c['prefix']!.text, SafePath.sanitizeFileName(f.name)),
          ),
      ]);
    } catch (e) {
      ref.read(activityProvider.notifier).notify(NoticeKind.error, 'Could not open the file picker: $e');
    }
  }

  Future<void> _build(ModManifest manifest) async {
    final ctrl = ref.read(builderProvider.notifier);
    final st = ref.read(builderProvider);
    final hasWs = ref.read(activeWorkspaceProvider) != null;
    try {
      final out = await ctrl.buildPackage(manifest: manifest, readme: _c['readme']!.text);
      if (!mounted) return;
      final done = <String>['Built ${p.basename(out)}'];
      if (st.addToLibrary && hasWs) {
        final imported = await importPackageFlow(context, ref, path: out);
        done.add('library: ${imported ?? 'import cancelled'}');
      }
      if (st.exportCopy) {
        final bytes = await File(out).readAsBytes();
        if (!mounted) return;
        final where = await saveOutput(
          context,
          ref,
          suggestedName: p.basename(out),
          bytes: bytes,
          mimeType: 'application/zip',
          toolId: kModsBuilderId,
        );
        done.add(where == null ? 'export cancelled' : 'exported to $where');
      }
      ctrl.setResult(
        ResultNote(
          kind: StatusKind.success,
          title: 'Package built',
          message: '${manifest.name} ${manifest.version}: ${Fmt.count(manifest.files.length, 'file')}',
          details: done,
        ),
      );
    } catch (e) {
      ctrl.setResult(ResultNote(kind: StatusKind.error, title: 'Build failed', message: e.toString()));
    }
  }

  String? _fieldError(List<ModIssue> issues, bool Function(String field) match) {
    final hits = issues.where((i) => i.isError && match(i.field)).toList();
    if (hits.isEmpty) return null;
    return hits.map((i) => i.message).join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(builderProvider);
    final ws = ref.watch(activeWorkspaceProvider);
    final fx = context.effects;
    return ListenableBuilder(
      listenable: Listenable.merge(_c.values.toList()),
      builder: (context, _) {
        final result = ManifestParser.fromMap(builderManifestMap(_fields, st.files));
        final issues = result.issues;
        final manifest = result.manifest;
        final canBuild = manifest != null && !st.busy && (st.addToLibrary && ws != null || st.exportCopy);

        Widget field(String key, String label, {String? hint, int lines = 1, bool mono = false, String? error}) =>
            Padding(
              padding: const EdgeInsets.only(bottom: J3Space.sm),
              child: TextField(
                controller: _c[key],
                minLines: lines,
                maxLines: lines == 1 ? 1 : lines + 3,
                style: mono ? J3Type.code : J3Type.body,
                decoration: InputDecoration(labelText: label, hintText: hint, errorText: error, errorMaxLines: 4),
              ),
            );

        return ToolScaffold(
          toolId: kModsBuilderId,
          inputs: [
            NeonPanel(
              kicker: 'PAYLOAD',
              title: 'Files (${st.included.length}/${st.files.length})',
              icon: Icons.folder_zip_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Choose a base folder whose layout mirrors the target (e.g. a folder containing data/ui/hud.json), '
                    'or add single files and type their target paths.',
                    style: J3Type.caption,
                  ),
                  const SizedBox(height: J3Space.sm),
                  field('prefix', 'Target prefix (optional)', hint: 'e.g. data/ui', mono: true),
                  Wrap(
                    spacing: J3Space.sm,
                    runSpacing: J3Space.sm,
                    children: [
                      if (ws != null)
                        NeonButton(
                          label: 'Choose base folder',
                          icon: Icons.folder_open,
                          onPressed: st.busy ? null : _chooseBase,
                        ),
                      if (ws != null)
                        NeonButton.secondary(
                          label: 'Add workspace file',
                          icon: Icons.note_add_outlined,
                          onPressed: st.busy ? null : _addWorkspaceFile,
                        ),
                      NeonButton.secondary(
                        label: 'Pick files from device',
                        icon: Icons.upload_file_outlined,
                        onPressed: st.busy ? null : _pickDeviceFiles,
                      ),
                      if (st.files.any((f) => f.baseRel != null))
                        NeonButton.ghost(
                          label: 'Apply prefix',
                          icon: Icons.drive_file_move_outline,
                          onPressed: st.busy
                              ? null
                              : () => ref.read(builderProvider.notifier).applyPrefix(_c['prefix']!.text),
                        ),
                      if (st.files.isNotEmpty)
                        NeonButton.ghost(
                          label: 'Clear files',
                          icon: Icons.clear_all,
                          onPressed: st.busy ? null : () => ref.read(builderProvider.notifier).clearFiles(),
                        ),
                    ],
                  ),
                  if (ws == null) ...[
                    const SizedBox(height: J3Space.sm),
                    Text('Open a workspace to use its folders as the package source.', style: J3Type.caption),
                  ],
                  if (st.baseFolder != null && ws != null) ...[
                    const SizedBox(height: J3Space.sm),
                    Text(
                      'Base: ${p.relative(st.baseFolder!, from: ws.rootPath).replaceAll('\\', '/')}/',
                      style: J3Type.codeSmall.copyWith(color: fx.accentText),
                    ),
                  ],
                  const SizedBox(height: J3Space.md),
                  if (st.files.isEmpty)
                    const EmptyState(title: 'No files yet', glyph: '[ files/ ]')
                  else
                    for (var i = 0; i < st.files.length; i++) _FileRow(index: i, file: st.files[i], busy: st.busy),
                  _FieldIssues(issues: issues.where((i) => i.field.startsWith('files')).toList()),
                ],
              ),
            ),
            NeonPanel(
              kicker: 'MANIFEST',
              title: 'Package details',
              icon: Icons.badge_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  field('id', 'Id', hint: 'neon-hud', mono: true, error: _fieldError(issues, (f) => f == 'id')),
                  field('name', 'Name', hint: 'Neon HUD', error: _fieldError(issues, (f) => f == 'name')),
                  field(
                    'version',
                    'Version',
                    hint: '1.0.0',
                    mono: true,
                    error: _fieldError(issues, (f) => f == 'version'),
                  ),
                  field(
                    'description',
                    'Description (optional)',
                    lines: 2,
                    error: _fieldError(issues, (f) => f == 'description'),
                  ),
                  field('author', 'Author (optional)', error: _fieldError(issues, (f) => f == 'author')),
                  field(
                    'license',
                    'License (optional)',
                    hint: 'CC0-1.0',
                    error: _fieldError(issues, (f) => f == 'license'),
                  ),
                  field(
                    'game',
                    'Compatible game id (optional)',
                    hint: 'neon-dungeon',
                    mono: true,
                    error: _fieldError(issues, (f) => f.startsWith('compatibility.game') && !f.endsWith('Version')),
                  ),
                  field(
                    'gameVersion',
                    'Game version constraint (optional)',
                    hint: '>=1.4.0 <2.0.0',
                    mono: true,
                    error: _fieldError(issues, (f) => f == 'compatibility.gameVersion'),
                  ),
                  field(
                    'deps',
                    'Dependencies: one "id [constraint]" per line',
                    hint: 'core-patch ^1.0.0',
                    lines: 2,
                    mono: true,
                    error: _fieldError(issues, (f) => f.startsWith('dependencies')),
                  ),
                  field(
                    'optional',
                    'Optional dependencies: one "id [constraint]" per line',
                    hint: 'hd-icons >=2.0.0',
                    lines: 2,
                    mono: true,
                    error: _fieldError(issues, (f) => f.startsWith('optionalDependencies')),
                  ),
                  field(
                    'conflicts',
                    'Conflicts: one "id [constraint] # reason" per line',
                    hint: 'classic-hud # both replace the HUD',
                    lines: 2,
                    mono: true,
                    error: _fieldError(issues, (f) => f.startsWith('conflicts')),
                  ),
                  field(
                    'tags',
                    'Tags (comma separated)',
                    hint: 'ui, balance',
                    error: _fieldError(issues, (f) => f.startsWith('tags')),
                  ),
                  field('readme', 'README.md (optional)', lines: 3),
                ],
              ),
            ),
          ],
          results: [
            NeonPanel(
              kicker: 'VALIDATION',
              title: manifest != null
                  ? 'Ready to build${issues.warnings.isNotEmpty ? ' (${issues.warnings.length} warning(s))' : ''}'
                  : '${issues.errors.length} problem(s) to fix',
              emphasis: manifest != null ? PanelEmphasis.success : PanelEmphasis.danger,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Live check with the same validator the importer uses.', style: J3Type.caption),
                  const SizedBox(height: J3Space.sm),
                  PackageIssuesInline(issues: issues),
                  const SizedBox(height: J3Space.md),
                  // Own transparent Material so the switch tiles' ink is not
                  // painted beneath the panel background.
                  Material(
                    type: MaterialType.transparency,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        OptionSwitch(
                          label: 'Add to the workspace library',
                          description: ws == null
                              ? 'Needs an active workspace'
                              : 'Validated again on import; never replaces silently',
                          value: st.addToLibrary && ws != null,
                          onChanged: ws == null || st.busy
                              ? null
                              : (v) => ref.read(builderProvider.notifier).setOptions(addToLibrary: v),
                        ),
                        OptionSwitch(
                          label: 'Export a copy',
                          description: 'Save, export or share the .j3mod file',
                          value: st.exportCopy,
                          onChanged: st.busy
                              ? null
                              : (v) => ref.read(builderProvider.notifier).setOptions(exportCopy: v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: J3Space.sm),
                  if (st.result != null) ...[
                    ModBanner.note(st.result!, onDismiss: () => ref.read(builderProvider.notifier).setResult(null)),
                    const SizedBox(height: J3Space.sm),
                  ],
                  Wrap(
                    spacing: J3Space.sm,
                    runSpacing: J3Space.sm,
                    children: [
                      NeonButton(
                        label: 'Build package',
                        icon: Icons.construction,
                        busy: st.busy,
                        onPressed: canBuild ? () => _build(manifest) : null,
                        tooltip: manifest == null
                            ? 'Fix the problems listed above first'
                            : (!st.addToLibrary && !st.exportCopy ? 'Choose library and/or export' : null),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            ResultPanel(
              text: const JsonEncoder.withIndent('  ').convert(builderManifestMap(_fields, st.files)),
              title: 'j3mod.json preview',
              kicker: 'OUTPUT',
              fileName: 'j3mod.json',
              mimeType: 'application/json',
              toolId: kModsBuilderId,
              maxHeight: 360,
            ),
          ],
        );
      },
    );
  }
}

/// Issues list used by the builder (all severities, flat).
class PackageIssuesInline extends StatelessWidget {
  const PackageIssuesInline({super.key, required this.issues});
  final List<ModIssue> issues;

  @override
  Widget build(BuildContext context) {
    if (issues.isEmpty) {
      return const IssueLine(severity: IssueSeverity.info, message: 'No problems: the manifest is valid.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final i in issues.take(40)) IssueLine.of(i)],
    );
  }
}

class _FieldIssues extends StatelessWidget {
  const _FieldIssues({required this.issues});
  final List<ModIssue> issues;

  @override
  Widget build(BuildContext context) {
    if (issues.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: J3Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final i in issues.take(20)) IssueLine.of(i)],
      ),
    );
  }
}

class _FileRow extends ConsumerWidget {
  const _FileRow({required this.index, required this.file, required this.busy});
  final int index;
  final BuilderFile file;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(builderProvider.notifier);
    return Container(
      margin: const EdgeInsets.only(bottom: J3Space.sm),
      padding: const EdgeInsets.fromLTRB(J3Space.xs, J3Space.xs, J3Space.sm, J3Space.sm),
      decoration: BoxDecoration(
        color: J3Colors.surfaceRaised,
        borderRadius: J3Radius.small,
        border: Border.all(color: file.include ? J3Colors.borderStrong : J3Colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Checkbox(
                value: file.include,
                onChanged: busy ? null : (v) => ctrl.toggle(index, v ?? false),
                semanticLabel: 'Include ${file.label}',
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(file.label, style: J3Type.code, maxLines: 2, overflow: TextOverflow.ellipsis),
                    Text(Fmt.bytes(file.size), style: J3Type.caption),
                  ],
                ),
              ),
              NeonIconButton(
                icon: Icons.close,
                tooltip: 'Remove ${file.label}',
                onPressed: busy ? null : () => ctrl.remove(index),
              ),
            ],
          ),
          TextFormField(
            key: ValueKey('${file.path}#${file.rev}'),
            initialValue: file.target,
            enabled: file.include && !busy,
            style: J3Type.code,
            decoration: const InputDecoration(labelText: 'Target path'),
            onChanged: (v) => ctrl.setTarget(index, v),
          ),
        ],
      ),
    );
  }
}
