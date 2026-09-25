import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/platform/file_access.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/workspace.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../data/search_service.dart';
import '../../domain/file_types.dart';
import '../../domain/name_query.dart';
import '../shared/requests.dart';
import '../shared/scope_folder.dart';
import '../shared/ws_widgets.dart';

class FindFilesState {
  const FindFilesState({
    this.workspaceId,
    this.dir = '',
    this.mode = NameMatchMode.glob,
    this.caseSensitive = false,
    this.includeHidden = false,
    this.includeFolders = false,
    this.opId,
    this.result,
    this.error,
  });

  final String? workspaceId;
  final String dir;
  final NameMatchMode mode;
  final bool caseSensitive;
  final bool includeHidden;
  final bool includeFolders;
  final String? opId;
  final FindFilesResult? result;
  final Object? error;

  FindFilesState copyWith({
    String? workspaceId,
    String? dir,
    NameMatchMode? mode,
    bool? caseSensitive,
    bool? includeHidden,
    bool? includeFolders,
    String? opId,
    bool clearOp = false,
    FindFilesResult? result,
    bool clearResult = false,
    Object? error,
    bool clearError = false,
  }) => FindFilesState(
    workspaceId: workspaceId ?? this.workspaceId,
    dir: dir ?? this.dir,
    mode: mode ?? this.mode,
    caseSensitive: caseSensitive ?? this.caseSensitive,
    includeHidden: includeHidden ?? this.includeHidden,
    includeFolders: includeFolders ?? this.includeFolders,
    opId: clearOp ? null : (opId ?? this.opId),
    result: clearResult ? null : (result ?? this.result),
    error: clearError ? null : (error ?? this.error),
  );
}

class FindFilesController extends Notifier<FindFilesState> {
  @override
  FindFilesState build() => const FindFilesState();

  void update(FindFilesState Function(FindFilesState s) f) => state = f(state);

  /// Validates, then runs the search as a cancellable activity operation.
  Future<void> run(Workspace ws, String pattern, int maxResults) async {
    NameQuery query;
    try {
      query = NameQuery.compile(pattern, state.mode, caseSensitive: state.caseSensitive);
    } on FormatException catch (e) {
      state = state.copyWith(error: e, clearResult: true);
      return;
    }
    final root = scopePath(ws, state.dir);
    state = state.copyWith(clearError: true, clearResult: true, workspaceId: ws.id);
    try {
      final r = await ref
          .read(activityProvider.notifier)
          .run<FindFilesResult>(
            toolId: WsTools.findFiles,
            title: 'Find "$pattern" in ${state.dir.isEmpty ? ws.name : state.dir}',
            workspaceId: ws.id,
            cancellable: true,
            notify: false,
            body: (op) {
              state = state.copyWith(opId: op.id);
              return FindFilesService.run(
                root: root,
                query: query,
                includeHidden: state.includeHidden,
                includeFolders: state.includeFolders,
                maxResults: maxResults,
                token: op.token,
                onProgress: (scanned, found) => op.progress(null, '$scanned scanned, $found found'),
              );
            },
            summary: (r) => '${Fmt.count(r.hits.length, 'match', 'matches')} in ${r.scanned} entries',
            counts: (r) => {'matches': r.hits.length, 'scanned': r.scanned},
          );
      state = state.copyWith(result: r, clearOp: true);
    } catch (e) {
      state = state.copyWith(error: e, clearOp: true);
    }
  }
}

final findFilesProvider = NotifierProvider<FindFilesController, FindFilesState>(FindFilesController.new);

class FindFilesPage extends ConsumerStatefulWidget {
  const FindFilesPage({super.key});

  @override
  ConsumerState<FindFilesPage> createState() => _FindFilesPageState();
}

class _FindFilesPageState extends ConsumerState<FindFilesPage> {
  @override
  void initState() {
    super.initState();
    final max = ref.read(draftTextProvider('${WsTools.findFiles}/max'));
    if (max.text.isEmpty) max.text = '5000';
  }

  @override
  Widget build(BuildContext context) {
    final ws = ref.watch(activeWorkspaceProvider);
    if (ws == null) {
      return const ToolScaffold(
        toolId: WsTools.findFiles,
        children: [WorkspaceRequired(purpose: 'File search looks through the active workspace.')],
      );
    }
    final s = ref.watch(findFilesProvider);
    final ctrl = ref.read(findFilesProvider.notifier);
    final pattern = ref.watch(draftTextProvider('${WsTools.findFiles}/pattern'));
    final max = ref.watch(draftTextProvider('${WsTools.findFiles}/max'));
    if (s.workspaceId != null && s.workspaceId != ws.id && s.opId == null) {
      // Another workspace became active: its folder and results no longer apply.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => ctrl.update((x) => x.copyWith(dir: '', workspaceId: ws.id, clearResult: true, clearError: true)),
      );
    }
    final running = s.opId != null;

    void search() {
      final limit = int.tryParse(max.text.trim());
      if (limit == null || limit < 1 || limit > 100000) {
        ctrl.update((x) => x.copyWith(error: const FormatException('Max results must be between 1 and 100000')));
        return;
      }
      ctrl.run(ws, pattern.text, limit);
    }

    return ToolScaffold(
      toolId: WsTools.findFiles,
      inputs: [
        NeonPanel(
          kicker: 'Query',
          title: 'Find by name',
          icon: Icons.manage_search,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: pattern,
                style: J3Type.code,
                decoration: InputDecoration(labelText: 'Pattern', hintText: s.mode.hint),
                onSubmitted: (_) => running ? null : search(),
              ),
              const SizedBox(height: J3Space.md),
              ChoiceRow<NameMatchMode>(
                label: 'Match mode',
                options: NameMatchMode.values,
                selected: s.mode,
                labelOf: (m) => m.label,
                onSelected: (m) => ctrl.update((x) => x.copyWith(mode: m)),
              ),
              const SizedBox(height: J3Space.xs),
              Text(s.mode.hint, style: J3Type.caption),
              WsSwitch(
                label: 'Match case',
                value: s.caseSensitive,
                onChanged: (v) => ctrl.update((x) => x.copyWith(caseSensitive: v)),
              ),
              WsSwitch(
                label: 'Include hidden files and folders',
                description: 'Names starting with a dot',
                value: s.includeHidden,
                onChanged: (v) => ctrl.update((x) => x.copyWith(includeHidden: v)),
              ),
              WsSwitch(
                label: 'Match folders too',
                value: s.includeFolders,
                onChanged: (v) => ctrl.update((x) => x.copyWith(includeFolders: v)),
              ),
              const SizedBox(height: J3Space.sm),
              NumberField(controller: max, label: 'Max results', min: 1, max: 100000),
              const SizedBox(height: J3Space.md),
              ScopeFolderRow(
                workspace: ws,
                relDir: s.dir,
                label: 'Search in',
                onChanged: (d) => ctrl.update((x) => x.copyWith(dir: d, workspaceId: ws.id)),
              ),
              const SizedBox(height: J3Space.lg),
              ButtonWrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                children: [
                  NeonButton(label: 'Search', icon: Icons.search, busy: running, onPressed: running ? null : search),
                  if (running)
                    NeonButton.secondary(
                      label: 'Cancel',
                      icon: Icons.stop_circle_outlined,
                      onPressed: () => ref.read(activityProvider.notifier).cancel(s.opId!),
                    ),
                ],
              ),
              const SizedBox(height: J3Space.sm),
              Text('Symbolic links are never followed, so link loops cannot hang the search.', style: J3Type.caption),
            ],
          ),
        ),
      ],
      results: [
        if (s.error != null) WsErrorBanner(error: s.error!, action: 'The search'),
        if (running) OperationProgress(operationId: s.opId!, label: 'Searching file names'),
        if (s.result == null && s.error == null && !running)
          const NeonPanel(
            emphasis: PanelEmphasis.subtle,
            child: EmptyState(glyph: '[ *.* ]', title: 'No search yet', message: 'Results appear here.'),
          ),
        if (s.result != null) _Results(result: s.result!, workspace: ws),
      ],
    );
  }
}

enum _HitAction { editor, hex, browser, copy }

class _Results extends ConsumerWidget {
  const _Results({required this.result, required this.workspace});
  final FindFilesResult result;
  final Workspace workspace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = result;
    return NeonPanel(
      kicker: 'Results',
      title: '${Fmt.count(r.hits.length, 'match', 'matches')}${r.truncated ? ' (limit reached)' : ''}',
      icon: Icons.list_alt,
      actions: [
        NeonIconButton(
          icon: Icons.copy_rounded,
          tooltip: 'Copy result list',
          onPressed: r.hits.isEmpty
              ? null
              : () async {
                  await ref.read(fileAccessProvider).copyText(r.toReport());
                  ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Copied ${r.hits.length} paths');
                },
        ),
        NeonIconButton(
          icon: Icons.save_alt_rounded,
          tooltip: 'Export result list',
          onPressed: r.hits.isEmpty
              ? null
              : () => saveOutput(
                  context,
                  ref,
                  suggestedName: 'find-results.txt',
                  bytes: Uint8List.fromList(utf8.encode(r.toReport())),
                  mimeType: 'text/plain',
                  toolId: WsTools.findFiles,
                ),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${r.scanned} entries scanned in ${Fmt.duration(r.elapsed)}'
            '${r.skippedLinks > 0 ? '  |  ${r.skippedLinks} links not followed' : ''}'
            '${r.unreadable.isNotEmpty ? '  |  ${r.unreadable.length} unreadable folders' : ''}',
            style: J3Type.caption,
          ),
          if (r.truncated)
            const Padding(
              padding: EdgeInsets.only(top: J3Space.sm),
              child: WsBanner(
                kind: StatusKind.warning,
                title: 'Result limit reached',
                message: 'More files may match. Narrow the pattern or folder, or raise "Max results".',
              ),
            ),
          if (r.unreadable.isNotEmpty) ...[
            const SizedBox(height: J3Space.sm),
            WsBanner(kind: StatusKind.warning, title: 'Some folders could not be read', details: r.unreadable),
          ],
          const SizedBox(height: J3Space.sm),
          if (r.hits.isEmpty)
            const EmptyState(glyph: '[ 0 ]', title: 'No matches')
          else
            BoundedList(
              fraction: 0.55,
              itemCount: r.hits.length,
              itemBuilder: (context, i) {
                final h = r.hits[i];
                return ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: [
                      Icon(
                        iconForCategory(h.isDirectory ? FileCategory.folder : FileTypes.categoryOf(h.relative)),
                        size: 18,
                        color: J3Colors.textSecondary,
                      ),
                      const SizedBox(width: J3Space.sm),
                      Expanded(
                        child: InkWell(
                          onTap: h.isDirectory
                              ? () => ref.showInBrowser(context, h.path)
                              : () => ref.openInEditor(context, h.path),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: J3Space.xs),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                PathText(h.relative),
                                if (!h.isDirectory) Text(Fmt.bytes(h.size), style: J3Type.caption),
                              ],
                            ),
                          ),
                        ),
                      ),
                      PopupMenuButton<_HitAction>(
                        tooltip: 'Actions for ${h.relative}',
                        icon: const Icon(Icons.more_vert, size: 18),
                        onSelected: (a) async {
                          switch (a) {
                            case _HitAction.editor:
                              ref.openInEditor(context, h.path);
                            case _HitAction.hex:
                              ref.openInHex(context, h.path);
                            case _HitAction.browser:
                              ref.showInBrowser(context, h.path);
                            case _HitAction.copy:
                              await ref.read(fileAccessProvider).copyText(h.path);
                              ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Path copied');
                          }
                        },
                        itemBuilder: (_) => [
                          if (!h.isDirectory) ...[
                            const PopupMenuItem(value: _HitAction.editor, child: Text('Open in Text Editor')),
                            const PopupMenuItem(value: _HitAction.hex, child: Text('Open in Hex Viewer')),
                          ],
                          const PopupMenuItem(value: _HitAction.browser, child: Text('Show in File Browser')),
                          const PopupMenuItem(value: _HitAction.copy, child: Text('Copy path')),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
