import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/executor_service.dart';
import '../domain/script_library.dart';

class ExecutorPage extends ConsumerStatefulWidget {
  const ExecutorPage({super.key});
  static const id = 'dev.roblox_executor';

  @override
  ConsumerState<ExecutorPage> createState() => _ExecutorPageState();
}

class _ExecutorPageState extends ConsumerState<ExecutorPage> {
  final _scriptController = TextEditingController();
  final _scrollController = ScrollController();
  String _selectedCategory = 'All';

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(executorProvider.notifier).loadDll();
      });
    }
  }

  @override
  void dispose() {
    _scriptController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(executorProvider);

    ref.listen(executorProvider.select((s) => s.output.length), (_, _) => _autoScroll());

    if (!Platform.isWindows) {
      return ToolScaffold(
        toolId: ExecutorPage.id,
        scrollable: false,
        body: Center(
          child: NeonPanel(
            emphasis: PanelEmphasis.danger,
            child: Padding(
              padding: const EdgeInsets.all(J3Space.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.desktop_windows, size: 48, color: J3Colors.error),
                  const SizedBox(height: J3Space.md),
                  Text('Windows Only', style: J3Type.headline.copyWith(color: J3Colors.error)),
                  const SizedBox(height: J3Space.sm),
                  Text(
                    'The Roblox Executor requires Windows and the WeAreDevs API DLL.',
                    style: J3Type.caption,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return ToolScaffold(
      toolId: ExecutorPage.id,
      scrollable: false,
      body: Column(
        children: [
          _buildStatusBar(state),
          Expanded(
            child: Row(
              children: [
                SizedBox(width: 280, child: _buildScriptLibrary(state)),
                const VerticalDivider(width: 1, color: J3Colors.border),
                Expanded(child: _buildMainArea(state)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(ExecutorState state) {
    final Color statusColor;
    final String statusText;
    final IconData statusIcon;

    switch (state.status) {
      case ExecutorStatus.unloaded:
        statusColor = J3Colors.textMuted;
        statusText = 'DLL not loaded';
        statusIcon = Icons.circle_outlined;
      case ExecutorStatus.ready:
        statusColor = J3Colors.warning;
        statusText = 'Ready — click Attach to connect to Roblox';
        statusIcon = Icons.circle_outlined;
      case ExecutorStatus.attaching:
        statusColor = J3Colors.info;
        statusText = 'Attaching to RobloxPlayerBeta.exe...';
        statusIcon = Icons.sync;
      case ExecutorStatus.attached:
        statusColor = J3Colors.success;
        statusText = 'Attached to Roblox — execute scripts below';
        statusIcon = Icons.check_circle;
      case ExecutorStatus.error:
        statusColor = J3Colors.error;
        statusText = state.error ?? 'Unknown error';
        statusIcon = Icons.error;
    }

    return NeonPanel(
      emphasis: state.status == ExecutorStatus.attached ? PanelEmphasis.success : PanelEmphasis.normal,
      padding: const EdgeInsets.symmetric(horizontal: J3Space.md, vertical: J3Space.sm),
      brackets: false,
      child: Row(
        children: [
          Icon(statusIcon, size: 16, color: statusColor),
          const SizedBox(width: J3Space.sm),
          Expanded(
            child: Text(statusText, style: J3Type.codeSmall.copyWith(color: statusColor)),
          ),
          if (state.status == ExecutorStatus.error && state.error != null && state.error!.contains('not found'))
            NeonButton.ghost(label: 'Setup Guide', icon: Icons.help_outline, dense: true, onPressed: _showSetupGuide),
          if (state.status == ExecutorStatus.unloaded || state.status == ExecutorStatus.error)
            NeonButton(
              label: 'Load DLL',
              icon: Icons.refresh,
              dense: true,
              onPressed: () => ref.read(executorProvider.notifier).loadDll(),
            ),
          if (state.status == ExecutorStatus.ready)
            NeonButton(
              label: 'Attach',
              icon: Icons.link,
              dense: true,
              onPressed: () => ref.read(executorProvider.notifier).attach(),
            ),
          if (state.status == ExecutorStatus.attached)
            Text('LIVE', style: J3Type.kicker.copyWith(color: J3Colors.success, letterSpacing: 2)),
        ],
      ),
    );
  }

  Widget _buildScriptLibrary(ExecutorState state) {
    final categories = ['All', ...scriptCategories];
    final scripts = _selectedCategory == 'All' ? builtInScripts : scriptsByCategory(_selectedCategory);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(J3Space.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('SCRIPT HUB', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
              const SizedBox(height: J3Space.sm),
              Wrap(
                spacing: J3Space.xs,
                runSpacing: J3Space.xs,
                children: categories
                    .map(
                      (c) => ChoiceChip(
                        label: Text(c, style: J3Type.codeSmall.copyWith(fontSize: 10)),
                        selected: _selectedCategory == c,
                        onSelected: (_) => setState(() => _selectedCategory = c),
                        selectedColor: J3Colors.darkRed,
                        visualDensity: VisualDensity.compact,
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: J3Colors.border),
        Expanded(
          child: ListView.builder(
            itemCount: scripts.length,
            itemBuilder: (ctx, i) {
              final script = scripts[i];
              return ListTile(
                dense: true,
                title: Text(script.name, style: J3Type.codeSmall),
                subtitle: Text(script.description, style: J3Type.caption.copyWith(fontSize: 10)),
                leading: Icon(_categoryIcon(script.category), size: 16, color: J3Colors.neonText),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.content_paste, size: 14),
                      tooltip: 'Load into editor',
                      onPressed: () {
                        _scriptController.text = script.code.trim();
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.play_arrow, size: 14),
                      tooltip: 'Execute now',
                      color: J3Colors.success,
                      onPressed: state.status == ExecutorStatus.attached
                          ? () {
                              _scriptController.text = script.code.trim();
                              ref.read(executorProvider.notifier).execute(script.code.trim());
                            }
                          : null,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMainArea(ExecutorState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(J3Space.sm),
          child: Row(
            children: [
              Text('// LUA EDITOR', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
              const Spacer(),
              NeonButton.ghost(
                label: 'Copy',
                icon: Icons.copy,
                dense: true,
                onPressed: _scriptController.text.isNotEmpty
                    ? () {
                        Clipboard.setData(ClipboardData(text: _scriptController.text));
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Script copied')));
                      }
                    : null,
              ),
              const SizedBox(width: J3Space.xs),
              NeonButton.ghost(
                label: 'Clear',
                icon: Icons.delete_outline,
                dense: true,
                onPressed: () => _scriptController.clear(),
              ),
              const SizedBox(width: J3Space.xs),
              NeonButton(
                label: 'Execute',
                icon: Icons.play_arrow,
                dense: true,
                onPressed: state.status == ExecutorStatus.attached
                    ? () => ref.read(executorProvider.notifier).execute(_scriptController.text)
                    : null,
              ),
            ],
          ),
        ),
        Expanded(
          flex: 3,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: J3Space.sm),
            decoration: BoxDecoration(
              color: J3Colors.inputFill,
              borderRadius: J3Radius.small,
              border: Border.all(
                color: state.status == ExecutorStatus.attached ? J3Colors.neon.withValues(alpha: 0.3) : J3Colors.border,
              ),
            ),
            padding: const EdgeInsets.all(J3Space.sm),
            child: TextField(
              controller: _scriptController,
              style: J3Type.codeSmall,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: InputDecoration.collapsed(
                hintText:
                    '-- Paste or write your Lua script here\n'
                    '-- Or pick one from the Script Hub on the left\n'
                    '\nprint("[J3] Hello from J3NSONTOP!")',
                hintStyle: J3Type.codeSmall.copyWith(color: J3Colors.textMuted),
              ),
            ),
          ),
        ),
        const SizedBox(height: J3Space.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: J3Space.sm),
          child: Row(
            children: [
              Text('// OUTPUT', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
              const Spacer(),
              Text('${state.output.length} lines', style: J3Type.caption),
              const SizedBox(width: J3Space.sm),
              NeonButton.ghost(
                label: 'Clear',
                icon: Icons.delete,
                dense: true,
                onPressed: () => ref.read(executorProvider.notifier).clearOutput(),
              ),
            ],
          ),
        ),
        Expanded(
          flex: 2,
          child: Container(
            margin: const EdgeInsets.all(J3Space.sm),
            decoration: BoxDecoration(
              color: J3Colors.background,
              borderRadius: J3Radius.small,
              border: Border.all(color: J3Colors.border),
            ),
            padding: const EdgeInsets.all(J3Space.sm),
            child: state.output.isEmpty
                ? Center(child: Text('Output appears here when you execute scripts', style: J3Type.caption))
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: state.output.length,
                    itemBuilder: (ctx, i) {
                      final line = state.output[i];
                      final color = line.startsWith('[!]')
                          ? J3Colors.error
                          : line.startsWith('[*]')
                          ? J3Colors.info
                          : line.startsWith('[+]')
                          ? J3Colors.success
                          : line.startsWith('[>]')
                          ? J3Colors.neonText
                          : J3Colors.text;
                      return SelectableText(line, style: J3Type.codeSmall.copyWith(color: color));
                    },
                  ),
          ),
        ),
      ],
    );
  }

  void _showSetupGuide() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: J3Colors.surface,
        title: Text('Roblox Executor Setup', style: J3Type.title.copyWith(color: J3Colors.neonText)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _step('1', 'Download wearedevs_exploit_api.dll'),
            _step('2', 'Place it next to j3nsontop_multitool.exe'),
            _step('3', 'Launch Roblox and join a game'),
            _step('4', 'Click "Load DLL" then "Attach"'),
            _step('5', 'Write or pick a script and Execute'),
            const SizedBox(height: J3Space.md),
            Text(
              'The DLL must be in the same folder as the app executable, '
              'or in a "bin" or "data" subfolder.',
              style: J3Type.caption,
            ),
          ],
        ),
        actions: [NeonButton.ghost(label: 'Got it', onPressed: () => Navigator.pop(ctx))],
      ),
    );
  }

  Widget _step(String num, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: J3Space.xs),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(color: J3Colors.darkRed, borderRadius: J3Radius.small),
            alignment: Alignment.center,
            child: Text(
              num,
              style: J3Type.codeSmall.copyWith(color: J3Colors.neonText, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: J3Space.sm),
          Expanded(child: Text(text, style: J3Type.codeSmall)),
        ],
      ),
    );
  }

  IconData _categoryIcon(String category) => switch (category) {
    'Movement' => Icons.directions_run,
    'Visual' => Icons.visibility,
    'Utility' => Icons.build,
    _ => Icons.code,
  };
}
