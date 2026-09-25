import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../theme/effects.dart';
import '../theme/j3_colors.dart';
import '../theme/j3_typography.dart';
import '../utils/format.dart';
import '../utils/safe_path.dart';
import '../workspace/workspace.dart';
import 'neon_button.dart';
import 'status.dart';

enum BrowseMode { pickFile, pickFolder }

/// Minimal in-app browser for choosing a file or folder inside a workspace.
/// Navigation is restricted to the workspace root.
Future<String?> showWorkspaceBrowser(
  BuildContext context, {
  required Workspace workspace,
  BrowseMode mode = BrowseMode.pickFile,
  List<String>? extensions,
  String? title,
  String? initialDir,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _WorkspaceBrowser(
      workspace: workspace,
      mode: mode,
      initialDir: initialDir,
      extensions: extensions?.map((e) => e.toLowerCase().replaceFirst('.', '')).toSet(),
      title: title ?? (mode == BrowseMode.pickFile ? 'Choose a file' : 'Choose a folder'),
    ),
  );
}

class _WorkspaceBrowser extends StatefulWidget {
  const _WorkspaceBrowser({
    required this.workspace,
    required this.mode,
    required this.initialDir,
    required this.extensions,
    required this.title,
  });

  final Workspace workspace;
  final BrowseMode mode;
  final String? initialDir;
  final Set<String>? extensions;
  final String title;

  @override
  State<_WorkspaceBrowser> createState() => _WorkspaceBrowserState();
}

class _WorkspaceBrowserState extends State<_WorkspaceBrowser> {
  late String _dir =
      widget.initialDir != null &&
          SafePath.isWithin(widget.workspace.rootPath, widget.initialDir!) &&
          Directory(widget.initialDir!).existsSync()
      ? widget.initialDir!
      : widget.workspace.rootPath;
  List<FileSystemEntity>? _entries;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _entries = null;
      _error = null;
    });
    try {
      final list = await Directory(_dir).list(followLinks: false).toList();
      list.sort((a, b) {
        final ad = a is Directory ? 0 : 1;
        final bd = b is Directory ? 0 : 1;
        if (ad != bd) return ad - bd;
        return p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
      });
      if (!mounted) return;
      setState(() => _entries = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  bool _matches(File f) {
    final ext = widget.extensions;
    if (ext == null) return true;
    return ext.contains(p.extension(f.path).toLowerCase().replaceFirst('.', ''));
  }

  void _open(String dir) {
    if (!SafePath.isWithin(widget.workspace.rootPath, dir)) return;
    _dir = dir;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final rel = p.relative(_dir, from: widget.workspace.rootPath);
    final atRoot = p.equals(_dir, widget.workspace.rootPath);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 560,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Up one folder',
                  onPressed: atRoot ? null : () => _open(p.dirname(_dir)),
                  icon: const Icon(Icons.arrow_upward),
                ),
                Expanded(
                  child: Text(
                    '${widget.workspace.name}/${rel == '.' ? '' : rel.replaceAll('\\', '/')}',
                    style: J3Type.codeSmall.copyWith(color: fx.accentText),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const Divider(),
            Expanded(
              child: _error != null
                  ? ErrorPanel(title: 'Cannot list folder', error: _error!, onRetry: _load)
                  : _entries == null
                  ? const Center(child: CircularProgressIndicator())
                  : _entries!.isEmpty
                  ? const EmptyState(title: 'Empty folder', glyph: '[ ]')
                  : ListView.builder(
                      itemCount: _entries!.length,
                      itemBuilder: (context, i) {
                        final e = _entries![i];
                        final name = p.basename(e.path);
                        if (e is Directory) {
                          return ListTile(
                            dense: true,
                            leading: Icon(Icons.folder, color: fx.accentText),
                            title: Text(name, style: J3Type.code),
                            onTap: () => _open(e.path),
                            trailing: widget.mode == BrowseMode.pickFolder
                                ? TextButton(
                                    onPressed: () => Navigator.of(context).pop(e.path),
                                    child: const Text('Select'),
                                  )
                                : const Icon(Icons.chevron_right),
                          );
                        }
                        if (e is File && widget.mode == BrowseMode.pickFile) {
                          final ok = _matches(e);
                          int? size;
                          try {
                            size = e.lengthSync();
                          } catch (_) {
                            size = null;
                          }
                          return ListTile(
                            dense: true,
                            enabled: ok,
                            leading: const Icon(Icons.description_outlined),
                            title: Text(name, style: J3Type.code),
                            subtitle: size == null ? null : Text(Fmt.bytes(size), style: J3Type.caption),
                            onTap: ok ? () => Navigator.of(context).pop(e.path) : null,
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        NeonButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop(), dense: true),
        if (widget.mode == BrowseMode.pickFolder)
          NeonButton(label: 'Use this folder', onPressed: () => Navigator.of(context).pop(_dir), dense: true),
      ],
      backgroundColor: J3Colors.surface,
    );
  }
}
