import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/frida_service.dart';

class FridaConsolePage extends ConsumerStatefulWidget {
  const FridaConsolePage({super.key});
  static const id = 'frida.console';

  @override
  ConsumerState<FridaConsolePage> createState() => _FridaConsolePageState();
}

class _FridaConsolePageState extends ConsumerState<FridaConsolePage> {
  List<FridaProcess> _processes = [];
  List<FridaDevice> _devices = [];
  FridaDevice? _selectedDevice;
  bool _loading = false;
  String? _error;
  String? _fridaVersion;
  final List<String> _output = [];
  StreamSubscription<String>? _session;
  final _scriptController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _checkFrida();
  }

  @override
  void dispose() {
    _session?.cancel();
    _scriptController.dispose();
    super.dispose();
  }

  Future<void> _checkFrida() async {
    setState(() { _loading = true; _error = null; });
    try {
      final frida = ref.read(fridaServiceProvider);
      final available = await frida.isAvailable();
      if (!available) {
        setState(() { _error = 'Frida not found. Install: pip install frida-tools'; _loading = false; });
        return;
      }
      final version = await frida.version();
      setState(() { _fridaVersion = version; _loading = false; });
      _loadDevices();
    } catch (e) {
      setState(() { _error = '$e'; _loading = false; });
    }
  }

  Future<void> _loadDevices() async {
    try {
      final devices = await ref.read(fridaServiceProvider).listDevices();
      setState(() {
        _devices = devices;
        if (_selectedDevice == null && devices.isNotEmpty) _selectedDevice = devices.first;
      });
    } catch (_) {}
  }

  Future<void> _loadProcesses() async {
    setState(() { _loading = true; _error = null; });
    try {
      final procs = await ref.read(fridaServiceProvider).listProcesses(device: _selectedDevice?.id);
      setState(() { _processes = procs; _loading = false; });
    } catch (e) {
      setState(() { _error = '$e'; _loading = false; });
    }
  }

  void _attachToProcess(FridaProcess proc) {
    _session?.cancel();
    _output.clear();
    _output.add('[*] Attaching to ${proc.name} (PID: ${proc.pid})...');
    final defaultScript = '''
// Attached to ${proc.name} (PID: ${proc.pid})
send({type: 'attached', pid: ${proc.pid}, name: '${proc.name}'});

// List loaded modules
var mods = Process.enumerateModules();
send({type: 'info', message: mods.length + ' modules loaded'});
''';
    _scriptController.text = defaultScript;
    setState(() {});
  }

  void _runScript() {
    if (_scriptController.text.isEmpty) return;
    _session?.cancel();
    setState(() => _output.add('[*] Running script...'));
  }

  void _spawnApp(String identifier) {
    _session?.cancel();
    _output.clear();
    setState(() {
      _output.add('[*] Spawning $identifier with Frida...');
      _output.add('[*] Waiting for process...');
    });
  }

  @override
  Widget build(BuildContext context) {
    return ToolScaffold(
      toolId: FridaConsolePage.id,
      scrollable: false,
      body: Column(
        children: [
          _buildStatusBar(),
          Expanded(
            child: Row(
              children: [
                SizedBox(width: 280, child: _buildProcessList()),
                const VerticalDivider(width: 1, color: J3Colors.border),
                Expanded(child: _buildConsole()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    return NeonPanel(
      emphasis: PanelEmphasis.subtle,
      padding: const EdgeInsets.symmetric(horizontal: J3Space.md, vertical: J3Space.sm),
      brackets: false,
      child: Row(
        children: [
          Icon(Icons.memory, size: 16, color: _fridaVersion != null ? J3Colors.success : J3Colors.error),
          const SizedBox(width: J3Space.sm),
          Text(_fridaVersion != null ? 'Frida v$_fridaVersion' : (_error ?? 'Checking...'), style: J3Type.mono.copyWith(fontSize: 12)),
          const Spacer(),
          if (_devices.isNotEmpty) ...[
            DropdownButton<FridaDevice>(
              value: _selectedDevice,
              dropdownColor: J3Colors.surface,
              style: J3Type.mono.copyWith(fontSize: 11),
              underline: const SizedBox.shrink(),
              items: _devices.map((d) => DropdownMenuItem(value: d, child: Text('${d.name} (${d.type})'))).toList(),
              onChanged: (d) => setState(() => _selectedDevice = d),
            ),
            const SizedBox(width: J3Space.sm),
          ],
          NeonButton.ghost(label: 'Refresh', icon: Icons.refresh, dense: true, onPressed: _loadProcesses),
        ],
      ),
    );
  }

  Widget _buildProcessList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(J3Space.sm),
          child: Text('// PROCESSES', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: J3Space.sm),
          child: NeonButton.secondary(label: 'Load Processes', icon: Icons.list, dense: true, onPressed: _loadProcesses),
        ),
        const SizedBox(height: J3Space.sm),
        if (_loading) const Center(child: Padding(padding: EdgeInsets.all(J3Space.lg), child: CircularProgressIndicator(color: J3Colors.neon))),
        Expanded(
          child: ListView.builder(
            itemCount: _processes.length,
            itemBuilder: (ctx, i) {
              final proc = _processes[i];
              return ListTile(
                dense: true,
                leading: Text('${proc.pid}', style: J3Type.mono.copyWith(fontSize: 10, color: J3Colors.textMuted)),
                title: Text(proc.name, style: J3Type.mono.copyWith(fontSize: 11)),
                subtitle: proc.identifier != null ? Text(proc.identifier!, style: J3Type.mono.copyWith(fontSize: 9, color: J3Colors.textMuted)) : null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(icon: const Icon(Icons.attach_file, size: 14), tooltip: 'Attach', onPressed: () => _attachToProcess(proc)),
                    if (proc.identifier != null)
                      IconButton(icon: const Icon(Icons.rocket_launch, size: 14), tooltip: 'Spawn', onPressed: () => _spawnApp(proc.identifier!)),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildConsole() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(J3Space.sm),
          child: Row(
            children: [
              Text('// CONSOLE', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
              const Spacer(),
              NeonButton.ghost(label: 'Run', icon: Icons.play_arrow, dense: true, onPressed: _runScript),
              const SizedBox(width: J3Space.xs),
              NeonButton.ghost(label: 'Clear', icon: Icons.delete, dense: true, onPressed: () => setState(() => _output.clear())),
            ],
          ),
        ),
        Expanded(
          flex: 2,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: J3Space.sm),
            decoration: BoxDecoration(
              color: J3Colors.inputFill,
              borderRadius: J3Radius.small,
              border: Border.all(color: J3Colors.border),
            ),
            child: TextField(
              controller: _scriptController,
              style: J3Type.mono.copyWith(fontSize: 11),
              maxLines: null,
              expands: true,
              decoration: const InputDecoration(
                hintText: '// Write your Frida script here...',
                hintStyle: TextStyle(color: J3Colors.textMuted, fontSize: 11, fontFamily: 'JetBrains Mono'),
                border: InputBorder.none,
                contentPadding: EdgeInsets.all(J3Space.sm),
              ),
            ),
          ),
        ),
        const SizedBox(height: J3Space.sm),
        Expanded(
          flex: 3,
          child: Container(
            margin: const EdgeInsets.all(J3Space.sm),
            decoration: BoxDecoration(
              color: J3Colors.background,
              borderRadius: J3Radius.small,
              border: Border.all(color: J3Colors.border),
            ),
            padding: const EdgeInsets.all(J3Space.sm),
            child: ListView.builder(
              itemCount: _output.length,
              itemBuilder: (ctx, i) {
                final line = _output[i];
                final color = line.startsWith('[!]') ? J3Colors.error
                    : line.startsWith('[*]') ? J3Colors.info
                    : line.startsWith('[+]') ? J3Colors.success
                    : J3Colors.text;
                return SelectableText(line, style: J3Type.mono.copyWith(fontSize: 11, color: color));
              },
            ),
          ),
        ),
      ],
    );
  }
}
