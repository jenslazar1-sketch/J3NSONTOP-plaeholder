import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final _scrollController = ScrollController();
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _checkFrida();
  }

  @override
  void dispose() {
    _session?.cancel();
    ref.read(fridaServiceProvider).killActive();
    _scriptController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _checkFrida() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final frida = ref.read(fridaServiceProvider);
      final available = await frida.isAvailable();
      if (!available) {
        setState(() {
          _error = 'Frida not found. Install: pip install frida-tools';
          _loading = false;
        });
        return;
      }
      final version = await frida.version();
      setState(() {
        _fridaVersion = version;
        _loading = false;
      });
      unawaited(_loadDevices());
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final procs = await ref.read(fridaServiceProvider).listProcesses(device: _selectedDevice?.id);
      setState(() {
        _processes = procs;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _attachToProcess(FridaProcess proc) {
    _session?.cancel();
    _output.clear();
    _output.add('[*] Attaching to ${proc.name} (PID: ${proc.pid})...');
    final defaultScript =
        '''
// Attached to ${proc.name} (PID: ${proc.pid})
send({type: 'attached', pid: ${proc.pid}, name: '${proc.name}'});

// List loaded modules
var mods = Process.enumerateModules();
send({type: 'info', message: mods.length + ' modules loaded'});
''';
    _scriptController.text = defaultScript;
    setState(() {});
  }

  Future<void> _testConnection() async {
    final conn = ref.read(fridaConnectionProvider);
    ref.read(fridaConnectionProvider.notifier).setTesting(true);
    _addOutput('[*] Testing connection to ${conn.address}...');

    try {
      final frida = ref.read(fridaServiceProvider);
      final ok = await frida.testRemoteConnection(conn.host, conn.port);
      if (ok) {
        ref.read(fridaConnectionProvider.notifier).setConnected(true);
        _addOutput('[+] Connected to Frida server at ${conn.address}');
        try {
          final procs = await frida.listRemoteProcesses(conn.host, conn.port);
          _addOutput('[+] ${procs.length} processes found on remote host');
        } catch (_) {}
      } else {
        ref.read(fridaConnectionProvider.notifier).setConnected(false);
        _addOutput('[!] Cannot connect to ${conn.address} — is the gadget running?');
        _addOutput('[*] Try: adb forward tcp:${conn.port} tcp:${conn.port}');
      }
    } catch (e) {
      ref.read(fridaConnectionProvider.notifier).setConnected(false);
      _addOutput('[!] Connection failed: $e');
    } finally {
      ref.read(fridaConnectionProvider.notifier).setTesting(false);
    }
  }

  Future<void> _setupAdbForward() async {
    final conn = ref.read(fridaConnectionProvider);
    _addOutput('[*] Setting up ADB port forward tcp:${conn.port}...');
    try {
      final msg = await FridaService.setupAdbForward(localPort: conn.port, remotePort: conn.port);
      _addOutput('[+] $msg');
    } catch (e) {
      _addOutput('[!] ADB forward failed: $e');
    }
  }

  void _runScript() {
    if (_scriptController.text.isEmpty) return;
    final conn = ref.read(fridaConnectionProvider);
    if (!conn.connected) {
      _addOutput('[!] Not connected. Click "Test" to verify the connection first.');
      return;
    }

    _stopScript();
    setState(() => _running = true);
    _addOutput('[*] Executing script on ${conn.target}@${conn.address}...');

    final frida = ref.read(fridaServiceProvider);
    final stream = frida.executeOnRemote(
      host: conn.host,
      port: conn.port,
      target: conn.target,
      jsCode: _scriptController.text,
    );

    _session = stream.listen(
      (line) => _addOutput(line),
      onError: (e) {
        _addOutput('[!] Error: $e');
        setState(() => _running = false);
      },
      onDone: () {
        _addOutput('[*] Script session ended.');
        setState(() => _running = false);
      },
    );
  }

  void _stopScript() {
    _session?.cancel();
    _session = null;
    ref.read(fridaServiceProvider).killActive();
    if (_running) {
      _addOutput('[*] Session stopped.');
      setState(() => _running = false);
    }
  }

  void _addOutput(String line) {
    setState(() {
      _output.add(line);
      if (_output.length > 5000) _output.removeRange(0, _output.length - 5000);
    });
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
    final conn = ref.watch(fridaConnectionProvider);
    return ToolScaffold(
      toolId: FridaConsolePage.id,
      scrollable: false,
      body: Column(
        children: [
          _buildStatusBar(),
          _buildConnectionBar(conn),
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
          Text(_fridaVersion != null ? 'Frida v$_fridaVersion' : (_error ?? 'Checking...'), style: J3Type.codeSmall),
          const Spacer(),
          if (_devices.isNotEmpty) ...[
            DropdownButton<FridaDevice>(
              value: _selectedDevice,
              dropdownColor: J3Colors.surface,
              style: J3Type.codeSmall,
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

  Widget _buildConnectionBar(FridaConnectionConfig conn) {
    return NeonPanel(
      emphasis: conn.connected ? PanelEmphasis.success : PanelEmphasis.normal,
      padding: const EdgeInsets.symmetric(horizontal: J3Space.md, vertical: J3Space.sm),
      brackets: false,
      child: Row(
        children: [
          Icon(
            conn.connected ? Icons.link : Icons.link_off,
            size: 16,
            color: conn.connected ? J3Colors.success : J3Colors.textMuted,
          ),
          const SizedBox(width: J3Space.sm),
          SizedBox(
            width: 120,
            child: TextField(
              style: J3Type.codeSmall,
              decoration: _compactInput('Host'),
              controller: TextEditingController(text: conn.host),
              onChanged: (v) => ref.read(fridaConnectionProvider.notifier).setHost(v),
            ),
          ),
          const SizedBox(width: J3Space.xs),
          const Text(':', style: TextStyle(color: J3Colors.textMuted)),
          const SizedBox(width: J3Space.xs),
          SizedBox(
            width: 64,
            child: TextField(
              style: J3Type.codeSmall,
              decoration: _compactInput('Port'),
              controller: TextEditingController(text: '${conn.port}'),
              keyboardType: TextInputType.number,
              onChanged: (v) {
                final p = int.tryParse(v);
                if (p != null) ref.read(fridaConnectionProvider.notifier).setPort(p);
              },
            ),
          ),
          const SizedBox(width: J3Space.sm),
          SizedBox(
            width: 100,
            child: TextField(
              style: J3Type.codeSmall,
              decoration: _compactInput('Target'),
              controller: TextEditingController(text: conn.target),
              onChanged: (v) => ref.read(fridaConnectionProvider.notifier).setTarget(v),
            ),
          ),
          const SizedBox(width: J3Space.sm),
          NeonButton.ghost(
            label: conn.testing ? '...' : 'Test',
            icon: Icons.wifi_tethering,
            dense: true,
            onPressed: conn.testing ? null : _testConnection,
          ),
          const SizedBox(width: J3Space.xs),
          NeonButton.ghost(label: 'ADB Fwd', icon: Icons.swap_horiz, dense: true, onPressed: _setupAdbForward),
        ],
      ),
    );
  }

  InputDecoration _compactInput(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: J3Type.codeSmall.copyWith(color: J3Colors.textMuted, fontSize: 10),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: J3Space.xs, vertical: J3Space.xs),
    filled: true,
    fillColor: J3Colors.inputFill,
    border: OutlineInputBorder(
      borderRadius: J3Radius.small,
      borderSide: BorderSide(color: J3Colors.border),
    ),
  );

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
          child: NeonButton.secondary(
            label: 'Load Processes',
            icon: Icons.list,
            dense: true,
            onPressed: _loadProcesses,
          ),
        ),
        const SizedBox(height: J3Space.sm),
        if (_loading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(J3Space.lg),
              child: CircularProgressIndicator(color: J3Colors.neon),
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: _processes.length,
            itemBuilder: (ctx, i) {
              final proc = _processes[i];
              return ListTile(
                dense: true,
                leading: Text('${proc.pid}', style: J3Type.codeSmall.copyWith(fontSize: 10, color: J3Colors.textMuted)),
                title: Text(proc.name, style: J3Type.codeSmall),
                subtitle: proc.identifier != null
                    ? Text(proc.identifier!, style: J3Type.codeSmall.copyWith(fontSize: 9, color: J3Colors.textMuted))
                    : null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.attach_file, size: 14),
                      tooltip: 'Attach',
                      onPressed: () => _attachToProcess(proc),
                    ),
                    if (proc.identifier != null)
                      IconButton(
                        icon: const Icon(Icons.rocket_launch, size: 14),
                        tooltip: 'Spawn',
                        onPressed: () => _spawnApp(proc.identifier!),
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
              if (_running) ...[
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2, color: J3Colors.neon),
                ),
                const SizedBox(width: J3Space.xs),
                NeonButton.ghost(label: 'Stop', icon: Icons.stop, dense: true, onPressed: _stopScript),
                const SizedBox(width: J3Space.xs),
              ] else ...[
                NeonButton(label: 'Execute', icon: Icons.play_arrow, dense: true, onPressed: _runScript),
                const SizedBox(width: J3Space.xs),
              ],
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
                icon: Icons.delete,
                dense: true,
                onPressed: () => setState(() => _output.clear()),
              ),
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
              border: Border.all(color: _running ? J3Colors.neon.withValues(alpha: 0.5) : J3Colors.border),
            ),
            child: TextField(
              controller: _scriptController,
              style: J3Type.codeSmall,
              maxLines: null,
              expands: true,
              decoration: InputDecoration(
                hintText: '// Write your Frida script here...\n// Click Execute to push to the remote Frida session',
                hintStyle: J3Type.codeSmall.copyWith(color: J3Colors.textMuted),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.all(J3Space.sm),
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
              Text('${_output.length} lines', style: J3Type.caption),
            ],
          ),
        ),
        const SizedBox(height: J3Space.xs),
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
              controller: _scrollController,
              itemCount: _output.length,
              itemBuilder: (ctx, i) {
                final line = _output[i];
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
}
