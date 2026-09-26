import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/adb_service.dart';

class AdbManagerPage extends ConsumerStatefulWidget {
  const AdbManagerPage({super.key});
  static const id = 'frida.adb';

  @override
  ConsumerState<AdbManagerPage> createState() => _AdbManagerPageState();
}

class _AdbManagerPageState extends ConsumerState<AdbManagerPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  List<AdbDevice> _devices = [];
  AdbDevice? _selected;
  List<InstalledPackage> _packages = [];
  final List<String> _logLines = [];
  StreamSubscription<String>? _logSub;
  final _shellController = TextEditingController();
  String _shellOutput = '';
  bool _loading = false;
  String? _error;
  Map<String, String> _deviceInfo = {};

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    _refreshDevices();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _logSub?.cancel();
    _shellController.dispose();
    super.dispose();
  }

  Future<void> _refreshDevices() async {
    setState(() { _loading = true; _error = null; });
    try {
      final adb = ref.read(adbServiceProvider);
      final available = await adb.isAvailable();
      if (!available) {
        setState(() { _error = 'ADB not found. Install Android SDK platform-tools and add to PATH.'; _loading = false; });
        return;
      }
      final devices = await adb.devices();
      setState(() {
        _devices = devices;
        if (_selected == null && devices.isNotEmpty) _selected = devices.first;
        _loading = false;
      });
      if (_selected != null) unawaited(_loadDeviceInfo());
    } catch (e) {
      setState(() { _error = '$e'; _loading = false; });
    }
  }

  Future<void> _loadDeviceInfo() async {
    if (_selected == null) return;
    try {
      final info = await ref.read(adbServiceProvider).deviceInfo(_selected!.serial);
      setState(() => _deviceInfo = info);
    } catch (_) {}
  }

  Future<void> _loadPackages() async {
    if (_selected == null) return;
    setState(() => _loading = true);
    try {
      final pkgs = await ref.read(adbServiceProvider).listPackages(_selected!.serial);
      setState(() { _packages = pkgs; _loading = false; });
    } catch (e) {
      setState(() { _error = '$e'; _loading = false; });
    }
  }

  void _startLogcat() {
    if (_selected == null) return;
    _logSub?.cancel();
    _logLines.clear();
    _logSub = ref.read(adbServiceProvider).logcat(_selected!.serial).listen(
      (line) => setState(() {
        _logLines.add(line);
        if (_logLines.length > 2000) _logLines.removeRange(0, _logLines.length - 2000);
      }),
      onError: (e) => setState(() => _logLines.add('ERROR: $e')),
    );
  }

  void _stopLogcat() {
    _logSub?.cancel();
    _logSub = null;
  }

  Future<void> _runShell() async {
    if (_selected == null || _shellController.text.isEmpty) return;
    try {
      final out = await ref.read(adbServiceProvider).shell(_selected!.serial, _shellController.text);
      setState(() => _shellOutput = '> ${_shellController.text}\n$out\n\n$_shellOutput');
    } catch (e) {
      setState(() => _shellOutput = '> ${_shellController.text}\nERROR: $e\n\n$_shellOutput');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ToolScaffold(
      toolId: AdbManagerPage.id,
      scrollable: false,
      body: Column(
        children: [
          _buildDeviceBar(),
          TabBar(
            controller: _tabs,
            tabs: const [
              Tab(text: 'DEVICE', icon: Icon(Icons.phone_android, size: 16)),
              Tab(text: 'PACKAGES', icon: Icon(Icons.apps, size: 16)),
              Tab(text: 'LOGCAT', icon: Icon(Icons.receipt_long, size: 16)),
              Tab(text: 'SHELL', icon: Icon(Icons.terminal, size: 16)),
            ],
            labelColor: J3Colors.neonText,
            unselectedLabelColor: J3Colors.textMuted,
            indicatorColor: J3Colors.neon,
            dividerHeight: 0,
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [_buildDeviceTab(), _buildPackagesTab(), _buildLogcatTab(), _buildShellTab()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceBar() {
    return NeonPanel(
      emphasis: PanelEmphasis.subtle,
      padding: const EdgeInsets.symmetric(horizontal: J3Space.md, vertical: J3Space.sm),
      brackets: false,
      child: Row(
        children: [
          Icon(Icons.usb, size: 16, color: _devices.isEmpty ? J3Colors.error : J3Colors.success),
          const SizedBox(width: J3Space.sm),
          if (_devices.isEmpty)
            Text(_error ?? 'No devices connected', style: J3Type.caption)
          else
            Expanded(
              child: DropdownButton<AdbDevice>(
                value: _selected,
                dropdownColor: J3Colors.surface,
                style: J3Type.code,
                underline: const SizedBox.shrink(),
                isExpanded: true,
                items: _devices.map((d) => DropdownMenuItem(value: d, child: Text('${d.displayName} (${d.serial})'))).toList(),
                onChanged: (d) => setState(() { _selected = d; _loadDeviceInfo(); }),
              ),
            ),
          const SizedBox(width: J3Space.sm),
          NeonButton.ghost(label: 'Refresh', icon: Icons.refresh, onPressed: _refreshDevices, dense: true),
        ],
      ),
    );
  }

  Widget _buildDeviceTab() {
    if (_selected == null) return const EmptyState(title: 'Connect an Android device via USB or Wi-Fi');
    return SingleChildScrollView(
      padding: J3Space.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NeonPanel(
            title: _selected!.displayName,
            kicker: 'DEVICE INFO',
            icon: Icons.phone_android,
            emphasis: PanelEmphasis.normal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _infoRow('Serial', _selected!.serial),
                _infoRow('State', _selected!.state),
                for (final e in _deviceInfo.entries) _infoRow(e.key, e.value),
              ],
            ),
          ),
          const SizedBox(height: J3Space.md),
          NeonPanel(
            title: 'Quick Actions',
            kicker: 'COMMANDS',
            icon: Icons.bolt,
            child: Wrap(
              spacing: J3Space.sm,
              runSpacing: J3Space.sm,
              children: [
                NeonButton.secondary(label: 'Screenshot', icon: Icons.camera_alt, dense: true, onPressed: () {}),
                NeonButton.secondary(label: 'Reboot', icon: Icons.restart_alt, dense: true, onPressed: () async {
                  try { await ref.read(adbServiceProvider).shell(_selected!.serial, 'reboot'); } catch (_) {}
                }),
                NeonButton.secondary(label: 'Clear Logcat', icon: Icons.delete_sweep, dense: true, onPressed: () async {
                  try { await ref.read(adbServiceProvider).clearLogcat(_selected!.serial); } catch (_) {}
                }),
              ],
            ),
          ),
          const SizedBox(height: J3Space.md),
          NeonPanel(
            title: 'Port Forwarding',
            kicker: 'NETWORK',
            icon: Icons.swap_horiz,
            child: Row(
              children: [
                Expanded(child: Text('Forward TCP 27042 for Frida', style: J3Type.caption)),
                NeonButton.ghost(label: 'Forward', dense: true, onPressed: () async {
                  try {
                    await ref.read(adbServiceProvider).tcpForward(_selected!.serial, 27042, 27042);
                  } catch (_) {}
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: J3Space.xs),
      child: Row(
        children: [
          SizedBox(width: 100, child: Text(label, style: J3Type.caption.copyWith(color: J3Colors.textMuted))),
          Expanded(child: Text(value, style: J3Type.code)),
        ],
      ),
    );
  }

  Widget _buildPackagesTab() {
    if (_selected == null) return const EmptyState(title: 'Connect a device first');
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(J3Space.sm),
          child: Row(
            children: [
              Expanded(child: Text('${_packages.length} packages', style: J3Type.caption)),
              NeonButton.ghost(label: 'Load', icon: Icons.refresh, dense: true, onPressed: _loadPackages),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: J3Colors.neon))
              : _packages.isEmpty
              ? const EmptyState(title: 'Tap Load to list installed packages')
              : ListView.builder(
                  itemCount: _packages.length,
                  itemBuilder: (ctx, i) {
                    final pkg = _packages[i];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.android, size: 18, color: J3Colors.success),
                      title: Text(pkg.packageName, style: J3Type.codeSmall),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.play_arrow, size: 16),
                            tooltip: 'Launch',
                            onPressed: () => ref.read(adbServiceProvider).launchApp(_selected!.serial, pkg.packageName),
                          ),
                          IconButton(
                            icon: const Icon(Icons.stop, size: 16),
                            tooltip: 'Force stop',
                            onPressed: () => ref.read(adbServiceProvider).forceStop(_selected!.serial, pkg.packageName),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy, size: 16),
                            tooltip: 'Copy name',
                            onPressed: () => Clipboard.setData(ClipboardData(text: pkg.packageName)),
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

  Widget _buildLogcatTab() {
    if (_selected == null) return const EmptyState(title: 'Connect a device first');
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(J3Space.sm),
          child: Row(
            children: [
              Expanded(child: Text('${_logLines.length} lines', style: J3Type.caption)),
              NeonButton.ghost(
                label: _logSub != null ? 'Stop' : 'Start',
                icon: _logSub != null ? Icons.stop : Icons.play_arrow,
                dense: true,
                onPressed: () => setState(() => _logSub != null ? _stopLogcat() : _startLogcat()),
              ),
              const SizedBox(width: J3Space.xs),
              NeonButton.ghost(label: 'Clear', icon: Icons.delete, dense: true, onPressed: () => setState(() => _logLines.clear())),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: J3Colors.background,
            padding: const EdgeInsets.all(J3Space.sm),
            child: ListView.builder(
              reverse: true,
              itemCount: _logLines.length,
              itemBuilder: (ctx, i) {
                final line = _logLines[_logLines.length - 1 - i];
                final color = line.contains(' E ') ? J3Colors.error
                    : line.contains(' W ') ? J3Colors.warning
                    : line.contains(' I ') ? J3Colors.info
                    : J3Colors.textMuted;
                return Text(line, style: J3Type.codeSmall.copyWith(fontSize: 10, color: color));
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildShellTab() {
    if (_selected == null) return const EmptyState(title: 'Connect a device first');
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(J3Space.sm),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _shellController,
                  style: J3Type.codeSmall,
                  decoration: InputDecoration(
                    hintText: 'adb shell command...',
                    hintStyle: J3Type.codeSmall.copyWith(color: J3Colors.textMuted),
                    isDense: true,
                    contentPadding: const EdgeInsets.all(J3Space.sm),
                    filled: true,
                    fillColor: J3Colors.inputFill,
                    border: OutlineInputBorder(borderRadius: J3Radius.small, borderSide: BorderSide(color: J3Colors.border)),
                  ),
                  onSubmitted: (_) => _runShell(),
                ),
              ),
              const SizedBox(width: J3Space.sm),
              NeonButton(label: 'Run', icon: Icons.send, dense: true, onPressed: _runShell),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: J3Colors.background,
            padding: const EdgeInsets.all(J3Space.sm),
            child: SingleChildScrollView(
              child: SelectableText(_shellOutput, style: J3Type.codeSmall),
            ),
          ),
        ),
      ],
    );
  }
}
