import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/platform/file_access.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/workspace.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../data/search_service.dart';
import '../../domain/glob.dart';
import '../../domain/text_pattern.dart';
import '../shared/requests.dart';
import '../shared/scope_folder.dart';
import '../shared/ws_widgets.dart';

class SearchTextState {
  const SearchTextState({
    this.workspaceId,
    this.dir = '',
    this.isRegex = false,
    this.caseSensitive = false,
    this.wholeWord = false,
    this.includeHidden = false,
    this.opId,
    this.result,
    this.error,
    this.collapsed = const {},
  });

  final String? workspaceId;
  final String dir;
  final bool isRegex;
  final bool caseSensitive;
  final bool wholeWord;
  final bool includeHidden;
  final String? opId;
  final TextSearchResult? result;
  final Object? error;
  final Set<String> collapsed;

  SearchTextState copyWith({
    String? workspaceId,
    String? dir,
    bool? isRegex,
    bool? caseSensitive,
    bool? wholeWord,
    bool? includeHidden,
    String? opId,
    bool clearOp = false,
    TextSearchResult? result,
    bool clearResult = false,
    Object? error,
    bool clearError = false,
    Set<String>? collapsed,
  }) => SearchTextState(
    workspaceId: workspaceId ?? this.workspaceId,
    dir: dir ?? this.dir,
    isRegex: isRegex ?? this.isRegex,
    caseSensitive: caseSensitive ?? this.caseSensitive,
    wholeWord: wholeWord ?? this.wholeWord,
    includeHidden: includeHidden ?? this.includeHidden,
    opId: clearOp ? null : (opId ?? this.opId),
    result: clearResult ? null : (result ?? this.result),
    error: clearError ? null : (error ?? this.error),
    collapsed: collapsed ?? this.collapsed,
  );
}

class SearchTextController extends Notifier<SearchTextState> {
  @override
  SearchTextState build() => const SearchTextState();

  void update(SearchTextState Function(SearchTextState s) f) => state = f(state);

  void toggle(String file) {
    final next = {...state.collapsed};
    if (!next.remove(file)) next.add(file);
    state = state.copyWith(collapsed: next);
  }

  Future<void> run(Workspace ws, String pattern, String glob, {Duration? timeout}) async {
    final find = FindSpec(
      pattern: pattern,
      isRegex: state.isRegex,
      caseSensitive: state.caseSensitive,
      wholeWord: state.wholeWord,
    );
    // Validate first: a bad pattern or glob never starts a scan.
    final invalid = find.validate();
    if (invalid != null) {
      state = state.copyWith(error: FormatException(invalid), clearResult: true);
      return;
    }
    if (glob.trim().isNotEmpty) {
      try {
        Glob(glob.trim());
      } on FormatException catch (e) {
        state = state.copyWith(error: e, clearResult: true);
        return;
      }
    }
    final options = TextSearchOptions(
      find: find,
      includeGlob: glob,
      includeHidden: state.includeHidden,
      batchTimeout: timeout ?? const Duration(seconds: 10),
    );
    final dir = state.workspaceId == ws.id ? state.dir : '';
    state = state.copyWith(clearError: true, clearResult: true, workspaceId: ws.id, dir: dir, collapsed: const {});
    try {
      final r = await ref
          .read(activityProvider.notifier)
          .run<TextSearchResult>(
            toolId: WsTools.searchText,
            title: 'Search text "$pattern"',
            workspaceId: ws.id,
            cancellable: true,
            notify: false,
            body: (op) {
              state = state.copyWith(opId: op.id);
              return TextSearchService.run(
                root: scopePath(ws, dir),
                options: options,
                token: op.token,
                onProgress: (files, matches, current) =>
                    op.progress(null, '${Fmt.count(files, 'file')} searched, $matches matches - $current'),
              );
            },
            summary: (r) => '${r.totalMatches} matches in ${Fmt.count(r.files.length, 'file')}',
            counts: (r) => {'matches': r.totalMatches, 'files': r.files.length, 'scanned': r.filesScanned},
          );
      state = state.copyWith(result: r, clearOp: true);
    } catch (e) {
      state = state.copyWith(error: e, clearOp: true);
    }
  }
}

final searchTextProvider = NotifierProvider<SearchTextController, SearchTextState>(SearchTextController.new);

class SearchTextPage extends ConsumerWidget {
  const SearchTextPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ws = ref.watch(activeWorkspaceProvider);
    if (ws == null) {
      return const ToolScaffold(
        toolId: WsTools.searchText,
        children: [WorkspaceRequired(purpose: 'Text search looks inside the files of the active workspace.')],
      );
    }
    final s = ref.watch(searchTextProvider);
    final ctrl = ref.read(searchTextProvider.notifier);
    final pattern = ref.watch(draftTextProvider('${WsTools.searchText}/pattern'));
    final glob = ref.watch(draftTextProvider('${WsTools.searchText}/glob'));
    if (s.workspaceId != null && s.workspaceId != ws.id && s.opId == null) {
      // Another workspace became active: its folder and results no longer apply.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => ctrl.update((x) => x.copyWith(dir: '', workspaceId: ws.id, clearResult: true, clearError: true)),
      );
    }
    final running = s.opId != null;
    void search() => ctrl.run(ws, pattern.text, glob.text);

    return ToolScaffold(
      toolId: WsTools.searchText,
      inputs: [
        NeonPanel(
          kicker: 'Query',
          title: 'Search inside files',
          icon: Icons.find_in_page_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: pattern,
                style: J3Type.code,
                decoration: InputDecoration(
                  labelText: s.isRegex ? 'Regular expression' : 'Text',
                  hintText: s.isRegex ? r'e.g. max_hp\s*=\s*(\d+)' : 'e.g. max_hp',
                ),
                onSubmitted: (_) => running ? null : search(),
              ),
              const SizedBox(height: J3Space.sm),
              TextField(
                controller: glob,
                style: J3Type.code,
                decoration: const InputDecoration(
                  labelText: 'Only files matching (glob, optional)',
                  hintText: '*.json  or  game/config/*.{ini,toml}',
                ),
              ),
              WsSwitch(
                label: 'Regular expression',
                description: 'Checked before searching; runs in a worker with a time limit',
                value: s.isRegex,
                onChanged: (v) => ctrl.update((x) => x.copyWith(isRegex: v)),
              ),
              WsSwitch(
                label: 'Match case',
                value: s.caseSensitive,
                onChanged: (v) => ctrl.update((x) => x.copyWith(caseSensitive: v)),
              ),
              WsSwitch(
                label: 'Whole word',
                value: s.wholeWord,
                onChanged: (v) => ctrl.update((x) => x.copyWith(wholeWord: v)),
              ),
              WsSwitch(
                label: 'Include hidden files',
                value: s.includeHidden,
                onChanged: (v) => ctrl.update((x) => x.copyWith(includeHidden: v)),
              ),
              const SizedBox(height: J3Space.sm),
              ScopeFolderRow(
                workspace: ws,
                relDir: s.workspaceId == ws.id ? s.dir : '',
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
              Text(
                'Binary files and files over 10 MiB are skipped (and counted). Matches are found within a line.',
                style: J3Type.caption,
              ),
            ],
          ),
        ),
      ],
      results: [
        if (s.error != null) WsErrorBanner(error: s.error!, action: 'The search'),
        if (running) OperationProgress(operationId: s.opId!, label: 'Searching file contents'),
        if (s.result == null && s.error == null && !running)
          const NeonPanel(
            emphasis: PanelEmphasis.subtle,
            child: EmptyState(
              glyph: '[ grep ]',
              title: 'No search yet',
              message: 'Matches appear here, grouped by file.',
            ),
          ),
        if (s.result != null) _SearchResults(result: s.result!, collapsed: s.collapsed),
      ],
    );
  }
}

sealed class _Item {}

class _FileItem extends _Item {
  _FileItem(this.hits);
  final FileHits hits;
}

class _LineItem extends _Item {
  _LineItem(this.hits, this.match);
  final FileHits hits;
  final LineMatch match;
}

class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.result, required this.collapsed});
  final TextSearchResult result;
  final Set<String> collapsed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = result;
    final fx = context.effects;
    final items = <_Item>[
      for (final f in r.files) ...[
        _FileItem(f),
        if (!collapsed.contains(f.relative))
          for (final m in f.matches) _LineItem(f, m),
      ],
    ];
    return NeonPanel(
      kicker: 'Results',
      title: '${Fmt.count(r.totalMatches, 'match', 'matches')} in ${Fmt.count(r.files.length, 'file')}',
      icon: Icons.list_alt,
      actions: [
        NeonIconButton(
          icon: Icons.copy_rounded,
          tooltip: 'Copy results',
          onPressed: r.files.isEmpty
              ? null
              : () async {
                  await ref.read(fileAccessProvider).copyText(r.toReport());
                  ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Results copied');
                },
        ),
        NeonIconButton(
          icon: Icons.save_alt_rounded,
          tooltip: 'Export results',
          onPressed: r.files.isEmpty
              ? null
              : () => saveOutput(
                  context,
                  ref,
                  suggestedName: 'search-results.txt',
                  bytes: Uint8List.fromList(utf8.encode(r.toReport())),
                  mimeType: 'text/plain',
                  toolId: WsTools.searchText,
                ),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ButtonWrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.xs,
            children: [
              CountChip(label: 'Searched', value: '${r.filesScanned}'),
              CountChip(label: 'Binary skipped', value: '${r.skippedBinary}'),
              CountChip(label: 'Over 10 MiB', value: '${r.skippedLarge}'),
              if (r.skippedFilter > 0) CountChip(label: 'Filtered out', value: '${r.skippedFilter}'),
              CountChip(label: 'Time', value: Fmt.duration(r.elapsed)),
            ],
          ),
          if (r.truncated)
            const Padding(
              padding: EdgeInsets.only(top: J3Space.sm),
              child: WsBanner(
                kind: StatusKind.warning,
                title: 'Result limit reached',
                message: 'Only the first 10000 matching lines are listed. Narrow the search.',
              ),
            ),
          if (r.unreadable.isNotEmpty) ...[
            const SizedBox(height: J3Space.sm),
            WsBanner(kind: StatusKind.warning, title: 'Unreadable files', details: r.unreadable),
          ],
          const SizedBox(height: J3Space.sm),
          if (r.files.isEmpty)
            const EmptyState(glyph: '[ 0 ]', title: 'No matches')
          else
            BoundedList(
              itemCount: items.length,
              itemBuilder: (context, i) => switch (items[i]) {
                _FileItem(:final hits) => InkWell(
                  onTap: () => ref.read(searchTextProvider.notifier).toggle(hits.relative),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Padding(
                      padding: const EdgeInsets.only(top: J3Space.sm),
                      child: Row(
                        children: [
                          Icon(
                            collapsed.contains(hits.relative) ? Icons.chevron_right : Icons.expand_more,
                            size: 18,
                            semanticLabel: collapsed.contains(hits.relative) ? 'Expand' : 'Collapse',
                          ),
                          const SizedBox(width: J3Space.xs),
                          Expanded(
                            child: PathText(hits.relative, style: J3Type.code.copyWith(color: fx.accentText)),
                          ),
                          Text('${hits.matchCount}', style: J3Type.codeSmall),
                        ],
                      ),
                    ),
                  ),
                ),
                _LineItem(:final hits, :final match) => InkWell(
                  onTap: () => ref.openInEditor(context, hits.path, line: match.line, column: match.column),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(J3Space.xl, J3Space.xs, 0, J3Space.xs),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 56,
                            child: Text(
                              '${match.line}',
                              style: J3Type.codeSmall.copyWith(color: J3Colors.textMuted),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Expanded(
                            child: HighlightedSnippet(text: match.snippet, ranges: match.ranges),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              },
            ),
          const SizedBox(height: J3Space.xs),
          Text('Tap a line to open it in the Text Editor at that line.', style: J3Type.caption),
        ],
      ),
    );
  }
}
