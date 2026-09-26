import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/live_mod_ai.dart';

class LiveModPage extends ConsumerStatefulWidget {
  const LiveModPage({super.key});
  static const id = 'frida.livemod';

  @override
  ConsumerState<LiveModPage> createState() => _LiveModPageState();
}

class _LiveModPageState extends ConsumerState<LiveModPage> {
  final _targetController = TextEditingController();
  final _promptController = TextEditingController();
  final _valueController = TextEditingController();
  AiModAction _action = AiModAction.scan;
  String? _generatedScript;
  List<String> _discoveredClasses = [];
  List<String> _discoveredModules = [];
  String? _selectedClass;

  @override
  void dispose() {
    _targetController.dispose();
    _promptController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  void _startSession() {
    if (_targetController.text.isEmpty) return;
    ref.read(liveModProvider.notifier).startSession(_targetController.text);
    _generateScript();
  }

  void _generateScript() {
    final session = ref.read(liveModProvider).session;
    if (session == null) return;

    final request = AiModRequest(
      action: _action,
      description: _promptController.text.isNotEmpty ? _promptController.text : _action.name,
      target: _selectedClass ?? _targetController.text,
      value: _valueController.text.isNotEmpty ? _valueController.text : null,
    );

    setState(() => _generatedScript = session.generateModScript(request));
  }

  @override
  Widget build(BuildContext context) {
    final modState = ref.watch(liveModProvider);

    return ToolScaffold(
      toolId: LiveModPage.id,
      scrollable: false,
      body: Row(
        children: [
          SizedBox(width: 320, child: _buildControlPanel(modState)),
          const VerticalDivider(width: 1, color: J3Colors.border),
          Expanded(child: _buildMainArea(modState)),
        ],
      ),
    );
  }

  Widget _buildControlPanel(LiveModState modState) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(J3Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NeonPanel(
            kicker: 'TARGET',
            icon: Icons.gps_fixed,
            emphasis: modState.session != null ? PanelEmphasis.success : PanelEmphasis.normal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _targetController,
                  style: J3Type.mono.copyWith(fontSize: 12),
                  decoration: _inputDecor('Package name (e.g. com.game.app)'),
                ),
                const SizedBox(height: J3Space.sm),
                NeonButton(
                  label: modState.session != null ? 'Connected' : 'Start Session',
                  icon: modState.session != null ? Icons.check : Icons.play_arrow,
                  dense: true,
                  expand: true,
                  onPressed: modState.session != null ? null : _startSession,
                ),
              ],
            ),
          ),
          const SizedBox(height: J3Space.md),
          NeonPanel(
            kicker: 'AI MOD ENGINE',
            icon: Icons.auto_awesome,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('What do you want to do?', style: J3Type.caption),
                const SizedBox(height: J3Space.sm),
                Wrap(
                  spacing: J3Space.xs,
                  runSpacing: J3Space.xs,
                  children: AiModAction.values.map((a) => ChoiceChip(
                    label: Text(_actionLabel(a), style: J3Type.mono.copyWith(fontSize: 10)),
                    selected: _action == a,
                    onSelected: (_) => setState(() { _action = a; _generateScript(); }),
                    selectedColor: J3Colors.darkRed,
                    visualDensity: VisualDensity.compact,
                  )).toList(),
                ),
                const SizedBox(height: J3Space.md),
                TextField(
                  controller: _promptController,
                  style: J3Type.mono.copyWith(fontSize: 11),
                  maxLines: 3,
                  decoration: _inputDecor('Describe what to mod (e.g. "infinite coins", "god mode", "unlock all levels")'),
                  onChanged: (_) => _generateScript(),
                ),
                if (_action == AiModAction.modify) ...[
                  const SizedBox(height: J3Space.sm),
                  TextField(
                    controller: _valueController,
                    style: J3Type.mono.copyWith(fontSize: 12),
                    decoration: _inputDecor('New value (e.g. 999999)'),
                    onChanged: (_) => _generateScript(),
                  ),
                ],
                const SizedBox(height: J3Space.md),
                NeonButton(
                  label: 'Generate Script',
                  icon: Icons.auto_fix_high,
                  dense: true,
                  expand: true,
                  onPressed: _generateScript,
                ),
              ],
            ),
          ),
          const SizedBox(height: J3Space.md),
          if (modState.discoveredClasses.isNotEmpty)
            NeonPanel(
              kicker: 'DISCOVERED',
              icon: Icons.explore,
              emphasis: PanelEmphasis.subtle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${modState.discoveredClasses.length} game classes found', style: J3Type.caption),
                  const SizedBox(height: J3Space.sm),
                  SizedBox(
                    height: 200,
                    child: ListView.builder(
                      itemCount: modState.discoveredClasses.length,
                      itemBuilder: (ctx, i) {
                        final cls = modState.discoveredClasses[i];
                        return ListTile(
                          dense: true,
                          title: Text(cls, style: J3Type.mono.copyWith(fontSize: 10)),
                          selected: _selectedClass == cls,
                          selectedTileColor: J3Colors.surfaceRaised,
                          onTap: () {
                            setState(() => _selectedClass = cls);
                            _generateScript();
                          },
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.search, size: 14),
                                tooltip: 'Analyze',
                                onPressed: () {
                                  setState(() { _selectedClass = cls; _action = AiModAction.analyze; });
                                  _generateScript();
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.link, size: 14),
                                tooltip: 'Hook',
                                onPressed: () {
                                  setState(() { _selectedClass = cls; _action = AiModAction.hook; });
                                  _generateScript();
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMainArea(LiveModState modState) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(J3Space.sm),
          child: Row(
            children: [
              Text('// GENERATED SCRIPT', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
              const Spacer(),
              NeonButton.ghost(label: 'Copy', icon: Icons.copy, dense: true, onPressed: _generatedScript != null ? () {
                // Copy to clipboard
              } : null),
              const SizedBox(width: J3Space.xs),
              NeonButton.secondary(label: 'Execute', icon: Icons.play_arrow, dense: true, onPressed: _generatedScript != null ? () {
                ref.read(liveModProvider.notifier).addOutput('[*] Executing generated script...');
                ref.read(liveModProvider.notifier).setRunning(true);
              } : null),
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
              border: Border.all(color: _generatedScript != null ? J3Colors.neon.withValues(alpha: 0.3) : J3Colors.border),
            ),
            padding: const EdgeInsets.all(J3Space.sm),
            child: SelectableText(
              _generatedScript ?? '// AI mod engine ready\n// Select an action and describe your mod to generate a Frida script',
              style: J3Type.mono.copyWith(fontSize: 11, color: _generatedScript != null ? J3Colors.text : J3Colors.textMuted),
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
              if (modState.isRunning)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: J3Colors.neon)),
                    const SizedBox(width: J3Space.sm),
                    Text('Running...', style: J3Type.caption.copyWith(color: J3Colors.success)),
                  ],
                ),
              NeonButton.ghost(label: 'Clear', icon: Icons.delete, dense: true, onPressed: () => ref.read(liveModProvider.notifier).clearOutput()),
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
            child: modState.output.isEmpty
                ? Center(child: Text('Output will appear here', style: J3Type.caption))
                : ListView.builder(
                    itemCount: modState.output.length,
                    itemBuilder: (ctx, i) {
                      final line = modState.output[i];
                      final color = line.startsWith('[!]') ? J3Colors.error
                          : line.startsWith('[*]') ? J3Colors.info
                          : line.startsWith('[+]') ? J3Colors.success
                          : line.startsWith('[>]') ? J3Colors.neonText
                          : J3Colors.text;
                      return SelectableText(line, style: J3Type.mono.copyWith(fontSize: 11, color: color));
                    },
                  ),
          ),
        ),
      ],
    );
  }

  String _actionLabel(AiModAction a) => switch (a) {
    AiModAction.scan => 'Scan Game',
    AiModAction.hook => 'Hook',
    AiModAction.modify => 'Modify Value',
    AiModAction.watch => 'Watch',
    AiModAction.analyze => 'Analyze',
  };

  InputDecoration _inputDecor(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: J3Type.mono.copyWith(fontSize: 11, color: J3Colors.textMuted),
    isDense: true,
    contentPadding: const EdgeInsets.all(J3Space.sm),
    filled: true,
    fillColor: J3Colors.inputFill,
    border: OutlineInputBorder(borderRadius: J3Radius.small, borderSide: BorderSide(color: J3Colors.border)),
  );
}
