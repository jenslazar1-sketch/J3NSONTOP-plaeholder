import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/drafts/drafts.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/utils/safe_path.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/workspace.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../data/fs_listing.dart';
import '../../data/fs_walker.dart';
import '../../data/trash_store.dart';
import '../shared/requests.dart';
import '../shared/ws_widgets.dart';
import 'browser_actions.dart';
import 'browser_state.dart';
import 'details_panel.dart';

class FileBrowserPage extends ConsumerStatefulWidget {
  const FileBrowserPage({super.key});

  @override
  ConsumerState<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends ConsumerState<FileBrowserPage> {
  String? _loadedKey;
  List<FsEntry>? _entries;
  Object? _error;
  bool _loading = false;
  List<TrashItem>? _trash;
  Object? _trashError;

  String _absDir(Workspace ws, String dir) => dir.isEmpty ? ws.rootPath : p.joinAll([ws.rootPath, ...dir.split('/')]);

  String? _loadedFolder;

  Future<void> _load(Workspace ws, BrowserState s, String key) async {
    _loadedKey = key;
    final folder = '${ws.id}|${s.dir}';
    setState(() {
      // Never show another folder's (or workspace's) entries while loading.
      if (folder != _loadedFolder) _entries = null;
      _loadedFolder = folder;
      _loading = true;
      _error = null;
    });
    try {
      final entries = await FsListing.list(_absDir(ws, s.dir));
      if (!mounted || _loadedKey != key) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || _loadedKey != key) return;
      setState(() {
        _error = e;
        _entries = null;
        _loading = false;
      });
    }
  }

  Future<void> _loadTrash(BrowserActions a) async {
    try {
      final items = await a.trash.list();
      if (mounted) setState(() => _trash = items);
    } catch (e) {
      if (mounted) setState(() => _trashError = e);
    }
  }

  void _handleRequest(Workspace ws) {
    final req = ref.read(browserRequestProvider.notifier).claim();
    if (req == null || !SafePath.isWithin(ws.rootPath, req.path)) return;
    final type = FileSystemEntity.typeSync(req.path, followLinks: false);
    final ctrl = ref.read(browserStateProvider.notifier);
    final target = type == FileSystemEntityType.directory ? req.path : p.dirname(req.path);
    final rel = FsWalker.relativeOf(ws.rootPath, target);
    ctrl.cd(rel == '.' ? '' : rel);
    if (type != FileSystemEntityType.directory) ctrl.select(req.path);
  }

  @override
  Widget build(BuildContext context) {
    final ws = ref.watch(activeWorkspaceProvider);
    if (ws == null) {
      return const ToolScaffold(
        toolId: WsTools.browser,
        children: [WorkspaceRequired(purpose: 'The browser shows the files of the active workspace.')],
      );
    }
    final state = ref.watch(browserStateProvider);
    ref.watch(browserRequestProvider);
    if (state.workspaceId != ws.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(browserStateProvider.notifier).bind(ws.id);
      });
    }
    if (ref.read(browserRequestProvider.notifier).hasPending && state.workspaceId == ws.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _handleRequest(ws);
      });
    }
    final actions = BrowserActions(context, ref, ws);
    final key = '${ws.id}|${state.dir}|${state.reloadTick}';
    if (state.workspaceId == ws.id && key != _loadedKey && !state.trashView) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && key != _loadedKey) _load(ws, state, key);
      });
    }

    return ToolScaffold(
      toolId: WsTools.browser,
      children: [
        if (state.lastTrashed != null)
          WsBanner(
            kind: StatusKind.info,
            title: 'Moved "${state.lastTrashed!.name}" to trash',
            message: 'It can be restored until the trash is emptied.',
            onDismiss: ref.read(browserStateProvider.notifier).clearUndo,
            actions: [
              NeonButton.secondary(
                label: 'Undo',
                icon: Icons.undo,
                onPressed: () => actions.undoDelete(state.lastTrashed!),
              ),
            ],
          ),
        _Toolbar(
          workspace: ws,
          state: state,
          actions: actions,
          onOpenTrash: () {
            ref.read(browserStateProvider.notifier).setTrashView(true);
            _trash = null;
            _trashError = null;
            _loadTrash(actions);
          },
        ),
        if (state.trashView)
          _TrashView(items: _trash, error: _trashError, actions: actions, onChanged: () => _loadTrash(actions))
        else
          LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth >= J3Breakpoints.medium;
              final list = _EntryList(
                workspace: ws,
                entries: _entries,
                error: _error,
                loading: _loading,
                state: state,
                actions: actions,
                wide: wide,
                onRetry: () => _load(ws, state, key),
                onOpenDetailsSheet: (e) => _showSheet(context, e, actions),
              );
              if (!wide) return list;
              final selected = _entries?.where((e) => e.path == state.selected).firstOrNull;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: list),
                  const SizedBox(width: J3Space.lg),
                  SizedBox(
                    width: 360,
                    child: selected == null
                        ? const NeonPanel(
                            emphasis: PanelEmphasis.subtle,
                            child: EmptyState(
                              glyph: '[ i ]',
                              title: 'No selection',
                              message: 'Select a file to see details.',
                            ),
                          )
                        : EntryDetails(
                            entry: selected,
                            actions: actions,
                            onClose: () => ref.read(browserStateProvider.notifier).select(null),
                          ),
                  ),
                ],
              );
            },
          ),
      ],
    );
  }

  Future<void> _showSheet(BuildContext context, FsEntry e, BrowserActions actions) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => SingleChildScrollView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(J3Space.md, 0, J3Space.md, J3Space.lg),
          child: EntryDetails(entry: e, actions: actions, inSheet: true),
        ),
      ),
    );
  }
}

class _Toolbar extends ConsumerWidget {
  const _Toolbar({required this.workspace, required this.state, required this.actions, required this.onOpenTrash});

  final Workspace workspace;
  final BrowserState state;
  final BrowserActions actions;
  final VoidCallback onOpenTrash;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(browserStateProvider.notifier);
    final filter = ref.watch(draftTextProvider('${WsTools.browser}/filter'));
    final fx = context.effects;
    final parts = state.dir.isEmpty ? <String>[] : state.dir.split('/');
    return NeonPanel(
      padding: const EdgeInsets.all(J3Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              NeonIconButton(
                icon: Icons.arrow_upward,
                tooltip: 'Up one folder',
                onPressed: parts.isEmpty || state.trashView
                    ? null
                    : () => ctrl.cd(parts.sublist(0, parts.length - 1).join('/')),
              ),
              Expanded(
                // Reversed so deep paths show their end; the min-width box
                // keeps short paths left-aligned.
                child: LayoutBuilder(
                  builder: (context, c) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minWidth: c.maxWidth),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _Crumb(
                              label: workspace.name,
                              onTap: () => ctrl.cd(''),
                              current: parts.isEmpty && !state.trashView,
                            ),
                            for (var i = 0; i < parts.length; i++) ...[
                              Text(' / ', style: J3Type.codeSmall.copyWith(color: fx.accentText)),
                              _Crumb(
                                label: parts[i],
                                current: i == parts.length - 1 && !state.trashView,
                                onTap: () => ctrl.cd(parts.sublist(0, i + 1).join('/')),
                              ),
                            ],
                            if (state.trashView) ...[
                              Text(' / ', style: J3Type.codeSmall.copyWith(color: fx.accentText)),
                              const _Crumb(label: 'Trash', current: true),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: J3Space.sm),
          ButtonWrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 220,
                child: TextField(
                  controller: filter,
                  enabled: !state.trashView,
                  decoration: const InputDecoration(
                    labelText: 'Filter names',
                    prefixIcon: Icon(Icons.filter_list, size: 18),
                  ),
                ),
              ),
              PopupMenuButton<SortField>(
                tooltip: 'Sort by',
                onSelected: ctrl.sortBy,
                itemBuilder: (_) => [
                  for (final f in SortField.values)
                    CheckedPopupMenuItem(
                      value: f,
                      checked: f == state.sort,
                      child: Text('Sort by ${f.label.toLowerCase()}'),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: J3Space.sm, vertical: J3Space.md),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.sort, size: 18),
                      const SizedBox(width: J3Space.xs),
                      Text(state.sort.label, style: J3Type.label),
                    ],
                  ),
                ),
              ),
              NeonIconButton(
                icon: state.ascending ? Icons.arrow_downward : Icons.arrow_upward,
                tooltip: state.ascending ? 'Ascending (tap for descending)' : 'Descending (tap for ascending)',
                onPressed: ctrl.toggleAscending,
              ),
              FilterChip(
                label: const Text('Hidden files'),
                selected: state.showHidden,
                onSelected: ctrl.setShowHidden,
                tooltip: 'Show names starting with a dot',
              ),
              NeonIconButton(icon: Icons.refresh, tooltip: 'Refresh', onPressed: ctrl.reload),
              NeonIconButton(
                icon: Icons.create_new_folder_outlined,
                tooltip: 'New folder here',
                onPressed: state.trashView ? null : actions.newFolder,
              ),
              NeonIconButton(
                icon: Icons.upload_file_outlined,
                tooltip: 'Import files here',
                onPressed: state.trashView ? null : actions.importHere,
              ),
              NeonIconButton(
                icon: state.trashView ? Icons.folder_open : Icons.delete_sweep_outlined,
                tooltip: state.trashView ? 'Back to files' : 'Show trash',
                selected: state.trashView,
                onPressed: state.trashView ? () => ctrl.setTrashView(false) : onOpenTrash,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({required this.label, this.onTap, this.current = false});
  final String label;
  final VoidCallback? onTap;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final text = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 200),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: J3Type.code.copyWith(color: current ? J3Colors.text : fx.accentText),
      ),
    );
    if (onTap == null || current) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: J3Space.md),
        child: text,
      );
    }
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: J3Radius.small,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: J3Space.md),
          child: text,
        ),
      ),
    );
  }
}

class _EntryList extends ConsumerWidget {
  const _EntryList({
    required this.workspace,
    required this.entries,
    required this.error,
    required this.loading,
    required this.state,
    required this.actions,
    required this.wide,
    required this.onRetry,
    required this.onOpenDetailsSheet,
  });

  final Workspace workspace;
  final List<FsEntry>? entries;
  final Object? error;
  final bool loading;
  final BrowserState state;
  final BrowserActions actions;
  final bool wide;
  final VoidCallback onRetry;
  final void Function(FsEntry e) onOpenDetailsSheet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(draftTextProvider('${WsTools.browser}/filter'));
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: filter,
      builder: (context, value, _) {
        if (error != null) return WsErrorBanner(error: error!, action: 'Listing the folder', onRetry: onRetry);
        final all = entries;
        if (all == null) return const LoadingState(label: 'Reading folder...');
        final visible = FsListing.sort(
          FsListing.filter(all, query: value.text, showHidden: state.showHidden),
          state.sort,
          ascending: state.ascending,
        );
        final hidden = all.where((e) => e.isHidden).length;
        final summary =
            '${Fmt.count(visible.length, 'item')}${value.text.trim().isNotEmpty ? ' matching' : ''}'
            '${!state.showHidden && hidden > 0 ? '  |  $hidden hidden' : ''}${loading ? '  |  refreshing' : ''}';
        return NeonPanel(
          padding: const EdgeInsets.all(J3Space.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(J3Space.xs, 0, J3Space.xs, J3Space.xs),
                child: Text(summary, style: J3Type.caption),
              ),
              if (visible.isEmpty)
                EmptyState(
                  glyph: '[ ]',
                  title: all.isEmpty ? 'Empty folder' : 'Nothing matches',
                  message: all.isEmpty
                      ? 'Import files here or create a folder.'
                      : 'Change the filter or show hidden files.',
                )
              else
                BoundedList(
                  itemCount: visible.length,
                  itemBuilder: (context, i) => _EntryRow(
                    entry: visible[i],
                    selected: visible[i].path == state.selected,
                    wide: wide,
                    actions: actions,
                    onTap: () {
                      final e = visible[i];
                      final ctrl = ref.read(browserStateProvider.notifier);
                      if (e.isDirectory) {
                        final rel = FsWalker.relativeOf(workspace.rootPath, e.path);
                        ctrl.cd(rel);
                      } else {
                        ctrl.select(e.path);
                        if (!wide) onOpenDetailsSheet(e);
                      }
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

enum _RowAction { details, edit, hex, export, copy, rename, delete }

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.selected,
    required this.wide,
    required this.actions,
    required this.onTap,
  });

  final FsEntry entry;
  final bool selected;
  final bool wide;
  final BrowserActions actions;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final fx = context.effects;
    final meta = [
      if (!e.isDirectory) Fmt.bytes(e.size),
      if (e.modified != null) Fmt.dateTime(e.modified!).substring(0, 16),
      if (e.isLink) 'link (not followed)',
      if (e.statError != null) e.statError!,
    ].join('  |  ');
    return Material(
      color: selected ? J3Colors.selection : Colors.transparent,
      borderRadius: J3Radius.small,
      child: InkWell(
        onTap: e.isLink ? null : onTap,
        borderRadius: J3Radius.small,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: J3Space.sm, vertical: J3Space.xs),
            child: Row(
              children: [
                Icon(
                  iconForCategory(e.category),
                  size: 20,
                  color: e.isDirectory
                      ? fx.accentText
                      : (e.statError != null ? J3Colors.warning : J3Colors.textSecondary),
                ),
                const SizedBox(width: J3Space.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Tooltip(
                        message: e.name,
                        child: Text(
                          e.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: J3Type.code.copyWith(color: e.isHidden ? J3Colors.textMuted : J3Colors.text),
                        ),
                      ),
                      if (meta.isNotEmpty)
                        Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: J3Type.caption),
                    ],
                  ),
                ),
                if (e.isDirectory) const Icon(Icons.chevron_right, size: 18),
                PopupMenuButton<_RowAction>(
                  tooltip: 'Actions for ${e.name}',
                  icon: const Icon(Icons.more_vert, size: 18),
                  onSelected: (a) => switch (a) {
                    _RowAction.details => onTap(),
                    _RowAction.edit => actions.openEditor(e),
                    _RowAction.hex => actions.openHex(e),
                    _RowAction.export => actions.export(e),
                    _RowAction.copy => actions.copyPath(e),
                    _RowAction.rename => actions.rename(e),
                    _RowAction.delete => actions.delete(e),
                  },
                  itemBuilder: (_) => [
                    if (!e.isDirectory && !e.isLink) ...[
                      const PopupMenuItem(value: _RowAction.details, child: Text('Details')),
                      const PopupMenuItem(value: _RowAction.edit, child: Text('Open in Text Editor')),
                      const PopupMenuItem(value: _RowAction.hex, child: Text('Open in Hex Viewer')),
                      const PopupMenuItem(value: _RowAction.export, child: Text('Export / save as...')),
                    ],
                    const PopupMenuItem(value: _RowAction.copy, child: Text('Copy path')),
                    const PopupMenuItem(value: _RowAction.rename, child: Text('Rename...')),
                    const PopupMenuItem(value: _RowAction.delete, child: Text('Move to trash...')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrashView extends StatelessWidget {
  const _TrashView({required this.items, required this.error, required this.actions, required this.onChanged});

  final List<TrashItem>? items;
  final Object? error;
  final BrowserActions actions;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    if (error != null) return WsErrorBanner(error: error!, action: 'Reading the trash', onRetry: onChanged);
    final list = items;
    if (list == null) return const LoadingState(label: 'Reading trash...');
    return NeonPanel(
      kicker: 'Trash',
      title: list.isEmpty ? 'Trash is empty' : '${Fmt.count(list.length, 'item')} in trash',
      icon: Icons.delete_sweep_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Deleted files are kept in app storage (not in your folder) until you delete them permanently.',
            style: J3Type.caption,
          ),
          const SizedBox(height: J3Space.sm),
          if (list.isEmpty)
            const EmptyState(glyph: '[ ]', title: 'Nothing deleted')
          else ...[
            for (final item in list)
              Padding(
                padding: const EdgeInsets.only(bottom: J3Space.sm),
                child: Row(
                  children: [
                    Icon(item.isDirectory ? Icons.folder : Icons.insert_drive_file_outlined, size: 20),
                    const SizedBox(width: J3Space.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          PathText(item.relativePath),
                          Text(
                            '${Fmt.bytes(item.bytes)}  |  deleted ${Fmt.relative(item.deletedAt)}',
                            style: J3Type.caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    NeonIconButton(
                      icon: Icons.restore,
                      tooltip: 'Restore ${item.name}',
                      onPressed: () async {
                        await actions.undoDelete(item);
                        onChanged();
                      },
                    ),
                    NeonIconButton(
                      icon: Icons.delete_forever_outlined,
                      tooltip: 'Delete ${item.name} permanently',
                      onPressed: () async {
                        if (await actions.deleteForever(item)) onChanged();
                      },
                    ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: FitButton(
                NeonButton.danger(
                  label: 'Empty trash',
                  icon: Icons.delete_forever,
                  onPressed: () async {
                    if (await actions.emptyTrash(list)) onChanged();
                  },
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
