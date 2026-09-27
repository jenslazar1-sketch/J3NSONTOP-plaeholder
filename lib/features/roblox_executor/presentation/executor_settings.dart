import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/executor_service.dart';

class ExecutorSettingsDialog extends ConsumerStatefulWidget {
  const ExecutorSettingsDialog({super.key});

  @override
  ConsumerState<ExecutorSettingsDialog> createState() => _ExecutorSettingsDialogState();
}

class _ExecutorSettingsDialogState extends ConsumerState<ExecutorSettingsDialog> {
  late DllBackend _backend;
  // DLL controllers
  final _dllPathController = TextEditingController();
  final _isAttachedController = TextEditingController();
  final _attachController = TextEditingController();
  final _executeController = TextEditingController();
  final _settingsController = TextEditingController();
  // Process controllers
  final _exePathController = TextEditingController();
  final _injectArgsController = TextEditingController();
  final _executeArgsController = TextEditingController();
  final _autoexecDirController = TextEditingController();

  Map<String, bool>? _testResults;

  @override
  void initState() {
    super.initState();
    _backend = ref.read(executorProvider).activeBackend;
    _syncControllers();
  }

  void _syncControllers() {
    _dllPathController.text = _backend.customDllPath ?? '';
    _isAttachedController.text = _backend.isAttachedFn;
    _attachController.text = _backend.attachFn;
    _executeController.text = _backend.executeFn;
    _settingsController.text = _backend.settingsFn;
    _exePathController.text = _backend.exePath ?? '';
    _injectArgsController.text = _backend.injectArgs;
    _executeArgsController.text = _backend.executeArgsTemplate;
    _autoexecDirController.text = _backend.autoexecDir ?? '';
  }

  @override
  void dispose() {
    _dllPathController.dispose();
    _isAttachedController.dispose();
    _attachController.dispose();
    _executeController.dispose();
    _settingsController.dispose();
    _exePathController.dispose();
    _injectArgsController.dispose();
    _executeArgsController.dispose();
    _autoexecDirController.dispose();
    super.dispose();
  }

  DllBackend _buildBackend() => _backend.copyWith(
    customDllPath: _dllPathController.text.isEmpty ? null : _dllPathController.text,
    isAttachedFn: _isAttachedController.text,
    attachFn: _attachController.text,
    executeFn: _executeController.text,
    settingsFn: _settingsController.text,
    exePath: _exePathController.text.isEmpty ? null : _exePathController.text,
    injectArgs: _injectArgsController.text,
    executeArgsTemplate: _executeArgsController.text,
    autoexecDir: _autoexecDirController.text.isEmpty ? null : _autoexecDirController.text,
  );

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(executorProvider);

    return Dialog(
      backgroundColor: J3Colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: J3Radius.medium,
        side: const BorderSide(color: J3Colors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: J3Space.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: J3Space.sm),
                    _backendPicker(),
                    const SizedBox(height: J3Space.sm),
                    _modeBadge(),
                    const SizedBox(height: J3Space.md),
                    ..._modeFields(),
                    const SizedBox(height: J3Space.md),
                    _testBindingsSection(state),
                    const SizedBox(height: J3Space.md),
                    _diagnosticsSection(state),
                    const SizedBox(height: J3Space.md),
                  ],
                ),
              ),
            ),
            _actions(),
          ],
        ),
      ),
    );
  }

  List<Widget> _modeFields() {
    return switch (_backend.mode) {
      BackendMode.dll => [_dllPathField(), const SizedBox(height: J3Space.md), _functionFields()],
      BackendMode.process => [
        _exePathField(),
        const SizedBox(height: J3Space.md),
        _processFields(),
        const SizedBox(height: J3Space.md),
        _autoexecField(),
      ],
      BackendMode.cloudy => [_cloudyDllPathField(), const SizedBox(height: J3Space.md), _cloudyDepsInfo()],
      BackendMode.cloudyPipe => [_cloudyPipeExeField(), const SizedBox(height: J3Space.md), _cloudyPipeInfo()],
      BackendMode.xeno => [_xenoDllPathField(), const SizedBox(height: J3Space.md), _xenoDepsInfo()],
    };
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.all(J3Space.md),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: J3Colors.border)),
      ),
      child: Row(
        children: [
          const Icon(Icons.settings, color: J3Colors.neonText, size: 20),
          const SizedBox(width: J3Space.sm),
          Text('EXECUTOR SETTINGS', style: J3Type.kicker.copyWith(color: J3Colors.neonText, letterSpacing: 2)),
          const Spacer(),
          IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => Navigator.pop(context)),
        ],
      ),
    );
  }

  Widget _backendPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('API BACKEND', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
        const SizedBox(height: J3Space.xs),
        Wrap(
          spacing: J3Space.xs,
          runSpacing: J3Space.xs,
          children: builtInBackends.map((b) {
            final selected = _backend.name == b.name;
            return ChoiceChip(
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (b.mode == BackendMode.process) ...[
                    const Icon(Icons.terminal, size: 10, color: J3Colors.neonText),
                    const SizedBox(width: 3),
                  ],
                  if (b.mode == BackendMode.cloudy || b.mode == BackendMode.cloudyPipe) ...[
                    const Icon(Icons.cloud, size: 10, color: J3Colors.info),
                    const SizedBox(width: 3),
                  ],
                  if (b.mode == BackendMode.xeno) ...[
                    const Icon(Icons.memory, size: 10, color: J3Colors.success),
                    const SizedBox(width: 3),
                  ],
                  Text(b.name, style: J3Type.codeSmall.copyWith(fontSize: 11)),
                ],
              ),
              selected: selected,
              selectedColor: J3Colors.darkRed,
              visualDensity: VisualDensity.compact,
              onSelected: (_) {
                setState(() {
                  _backend = b.copyWith(
                    customDllPath: _backend.customDllPath,
                    exePath: _backend.exePath,
                    autoexecDir: _backend.autoexecDir,
                  );
                  _syncControllers();
                  _testResults = null;
                });
              },
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _modeBadge() {
    final (IconData icon, Color color, String label, String desc) = switch (_backend.mode) {
      BackendMode.dll => (
        Icons.extension,
        J3Colors.neonText,
        'DLL MODE',
        'Loads a DLL via FFI and calls exported functions',
      ),
      BackendMode.process => (
        Icons.terminal,
        J3Colors.info,
        'PROCESS MODE',
        'Launches an EXE to inject and writes scripts to files',
      ),
      BackendMode.cloudy => (
        Icons.cloud,
        J3Colors.info,
        'CLOUDY DLL',
        'Loads Cloudy.dll — Initialize, GetClients, ExecuteAsync',
      ),
      BackendMode.cloudyPipe => (
        Icons.swap_horiz,
        J3Colors.warning,
        'CLOUDY PIPE',
        'Injects via EXE, executes scripts through named pipe',
      ),
      BackendMode.xeno => (
        Icons.memory,
        J3Colors.success,
        'XENO DLL',
        'Loads Xeno.dll — Initialize, Attach, Execute, Version',
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: J3Space.sm, vertical: J3Space.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: J3Radius.small,
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: J3Space.xs),
          Text(label, style: J3Type.kicker.copyWith(color: color, letterSpacing: 1)),
          const SizedBox(width: J3Space.sm),
          Expanded(child: Text(desc, style: J3Type.caption)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // DLL mode fields
  // ---------------------------------------------------------------------------

  Widget _dllPathField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('DLL PATH', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
        const SizedBox(height: J3Space.xs),
        Text('Leave blank to auto-search near the app executable, or set a custom path.', style: J3Type.caption),
        const SizedBox(height: J3Space.xs),
        _inputField(_dllPathController, 'C:\\path\\to\\exploit.dll'),
        if (_backend.dllFileName.isNotEmpty) ...[
          const SizedBox(height: J3Space.xs),
          Text('Auto-search filename: ${_backend.dllFileName}', style: J3Type.caption),
        ],
      ],
    );
  }

  Widget _functionFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('FUNCTION NAMES', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
        const SizedBox(height: J3Space.xs),
        Text(
          'Configure the exported function names your DLL uses. '
          'Different APIs export different names.',
          style: J3Type.caption,
        ),
        const SizedBox(height: J3Space.sm),
        _labeledField('IsAttached', _isAttachedController, 'IsAttached'),
        const SizedBox(height: J3Space.xs),
        _labeledField('Attach', _attachController, 'Attach'),
        const SizedBox(height: J3Space.xs),
        _labeledField('Execute *', _executeController, 'Execute'),
        const SizedBox(height: J3Space.xs),
        _labeledField('SetSettings', _settingsController, 'SetSettings'),
        const SizedBox(height: J3Space.xs),
        Text('* Execute is required. Others are optional.', style: J3Type.caption),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Process mode fields
  // ---------------------------------------------------------------------------

  Widget _exePathField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('INJECTOR EXE PATH', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
        const SizedBox(height: J3Space.xs),
        Text(
          'Path to the injector executable (e.g. DLLLoader64.exe). '
          'Leave blank if injection is handled by another app.',
          style: J3Type.caption,
        ),
        const SizedBox(height: J3Space.xs),
        _inputField(_exePathController, 'C:\\path\\to\\injector.exe'),
      ],
    );
  }

  Widget _processFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('PROCESS ARGUMENTS', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
        const SizedBox(height: J3Space.xs),
        Text(
          'Configure command-line arguments for injection and execution. '
          'Use {script_path} as a placeholder for the script file path.',
          style: J3Type.caption,
        ),
        const SizedBox(height: J3Space.sm),
        _labeledField('Inject args', _injectArgsController, '--inject'),
        const SizedBox(height: J3Space.xs),
        _labeledField('Execute args', _executeArgsController, '{script_path}'),
      ],
    );
  }

  Widget _autoexecField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('AUTOEXEC FOLDER', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
        const SizedBox(height: J3Space.xs),
        Text(
          'Drop scripts into this folder for automatic execution. '
          'Many executors watch a folder for new .lua files.',
          style: J3Type.caption,
        ),
        const SizedBox(height: J3Space.xs),
        _inputField(_autoexecDirController, 'C:\\path\\to\\autoexec'),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Cloudy DLL mode fields
  // ---------------------------------------------------------------------------

  Widget _cloudyDllPathField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('CLOUDY.DLL PATH', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
        const SizedBox(height: J3Space.xs),
        Text(
          'Path to Cloudy.dll. Auto-searches in the bin\\ subfolder next to the app. '
          'Set a custom path if your Cloudy.dll is elsewhere.',
          style: J3Type.caption,
        ),
        const SizedBox(height: J3Space.xs),
        _inputField(_dllPathController, 'C:\\path\\to\\bin\\Cloudy.dll'),
        const SizedBox(height: J3Space.xs),
        Text('Auto-search: Cloudy.dll (app dir, bin\\, data\\)', style: J3Type.caption),
      ],
    );
  }

  Widget _cloudyDepsInfo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('CLOUDY API INFO', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
        const SizedBox(height: J3Space.xs),
        Container(
          padding: const EdgeInsets.all(J3Space.sm),
          decoration: BoxDecoration(
            color: J3Colors.info.withValues(alpha: 0.05),
            borderRadius: J3Radius.small,
            border: Border.all(color: J3Colors.info.withValues(alpha: 0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Functions (auto-bound):', style: J3Type.codeSmall.copyWith(color: J3Colors.info)),
              const SizedBox(height: J3Space.xs),
              Text('  Initialize()  — starts the API', style: J3Type.caption),
              Text('  GetClients()  — lists connected Roblox processes', style: J3Type.caption),
              Text('  ExecuteAsync() — sends script to client(s)', style: J3Type.caption),
              const SizedBox(height: J3Space.sm),
              Text(
                'Required dependency DLLs (same folder):',
                style: J3Type.codeSmall.copyWith(color: J3Colors.warning),
              ),
              const SizedBox(height: J3Space.xs),
              Text('  libcrypto-3-x64.dll', style: J3Type.caption),
              Text('  libssl-3-x64.dll', style: J3Type.caption),
              Text('  xxhash.dll', style: J3Type.caption),
              Text('  zstd.dll', style: J3Type.caption),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Cloudy Pipe mode fields
  // ---------------------------------------------------------------------------

  Widget _cloudyPipeExeField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('INJECTOR.EXE PATH', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
        const SizedBox(height: J3Space.xs),
        Text(
          'Path to the Cloudy Injector.exe. This injects the Cloudy module into Roblox. '
          'Leave blank if injection is handled externally.',
          style: J3Type.caption,
        ),
        const SizedBox(height: J3Space.xs),
        _inputField(_exePathController, 'C:\\path\\to\\Injector.exe'),
      ],
    );
  }

  Widget _cloudyPipeInfo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('CLOUDY PIPE INFO', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
        const SizedBox(height: J3Space.xs),
        Container(
          padding: const EdgeInsets.all(J3Space.sm),
          decoration: BoxDecoration(
            color: J3Colors.warning.withValues(alpha: 0.05),
            borderRadius: J3Radius.small,
            border: Border.all(color: J3Colors.warning.withValues(alpha: 0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('How it works:', style: J3Type.codeSmall.copyWith(color: J3Colors.warning)),
              const SizedBox(height: J3Space.xs),
              Text('1. Attach launches Injector.exe to inject into Roblox', style: J3Type.caption),
              Text('2. Execute sends scripts through a Windows named pipe', style: J3Type.caption),
              Text(r'3. Pipe name: \\.\pipe\CLDYexecution', style: J3Type.caption),
              const SizedBox(height: J3Space.sm),
              Text('Required files (next to Injector.exe):', style: J3Type.codeSmall.copyWith(color: J3Colors.warning)),
              const SizedBox(height: J3Space.xs),
              Text('  Module.dll', style: J3Type.caption),
              Text('  fmt.dll', style: J3Type.caption),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Xeno DLL mode fields
  // ---------------------------------------------------------------------------

  Widget _xenoDllPathField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('XENO.DLL PATH', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
        const SizedBox(height: J3Space.xs),
        Text(
          'Path to Xeno.dll. Auto-searches in the bin\\ subfolder next to the app. '
          'Set a custom path if your Xeno files are elsewhere.',
          style: J3Type.caption,
        ),
        const SizedBox(height: J3Space.xs),
        _inputField(_dllPathController, 'C:\\path\\to\\Xeno\\Xeno.dll'),
        const SizedBox(height: J3Space.xs),
        Text('Auto-search: Xeno.dll (app dir, bin\\, data\\)', style: J3Type.caption),
      ],
    );
  }

  Widget _xenoDepsInfo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('XENO API INFO', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
        const SizedBox(height: J3Space.xs),
        Container(
          padding: const EdgeInsets.all(J3Space.sm),
          decoration: BoxDecoration(
            color: J3Colors.success.withValues(alpha: 0.05),
            borderRadius: J3Radius.small,
            border: Border.all(color: J3Colors.success.withValues(alpha: 0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Functions (auto-bound):', style: J3Type.codeSmall.copyWith(color: J3Colors.success)),
              const SizedBox(height: J3Space.xs),
              Text('  Initialize()  — starts the Xeno runtime', style: J3Type.caption),
              Text('  Attach()      — hooks into Roblox process', style: J3Type.caption),
              Text('  Execute()     — sends Lua script (UTF-8)', style: J3Type.caption),
              Text('  GetClients()  — lists connected clients', style: J3Type.caption),
              Text('  SetSetting()  — configures key/value pair', style: J3Type.caption),
              Text('  Version()     — returns API version string', style: J3Type.caption),
              const SizedBox(height: J3Space.sm),
              Text(
                'Required dependency DLLs (same folder):',
                style: J3Type.codeSmall.copyWith(color: J3Colors.warning),
              ),
              const SizedBox(height: J3Space.xs),
              Text('  libcurl.dll', style: J3Type.caption),
              Text('  libcrypto-3-x64.dll', style: J3Type.caption),
              Text('  libssl-3-x64.dll', style: J3Type.caption),
              Text('  xxhash.dll', style: J3Type.caption),
              Text('  zstd.dll', style: J3Type.caption),
              Text('  zlib1.dll', style: J3Type.caption),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Shared widgets
  // ---------------------------------------------------------------------------

  Widget _labeledField(String label, TextEditingController ctrl, String hint) {
    return Row(
      children: [
        SizedBox(
          width: 100,
          child: Text(label, style: J3Type.codeSmall.copyWith(color: J3Colors.textMuted)),
        ),
        Expanded(child: _inputField(ctrl, hint)),
        if (_testResults != null && ctrl.text.isNotEmpty) ...[
          const SizedBox(width: J3Space.xs),
          Icon(
            _testResults![ctrl.text] == true ? Icons.check_circle : Icons.cancel,
            size: 16,
            color: _testResults![ctrl.text] == true ? J3Colors.success : J3Colors.error,
          ),
        ],
      ],
    );
  }

  Widget _inputField(TextEditingController ctrl, String hint) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: J3Colors.inputFill,
        borderRadius: J3Radius.small,
        border: Border.all(color: J3Colors.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: J3Space.sm),
      child: TextField(
        controller: ctrl,
        style: J3Type.codeSmall,
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: hint,
          hintStyle: J3Type.codeSmall.copyWith(color: J3Colors.textMuted),
          isDense: true,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }

  Widget _testBindingsSection(ExecutorState state) {
    final testLabel = switch (_backend.mode) {
      BackendMode.dll => 'TEST BINDINGS',
      BackendMode.process => 'TEST PATHS',
      BackendMode.cloudy => 'TEST CLOUDY API',
      BackendMode.cloudyPipe => 'TEST PIPE SETUP',
      BackendMode.xeno => 'TEST XENO API',
    };

    final testHint = switch (_backend.mode) {
      BackendMode.dll => 'Click Test to load the DLL and check function bindings.',
      BackendMode.process => 'Click Test to verify paths and folder access.',
      BackendMode.cloudy => 'Click Test to load Cloudy.dll and verify API exports.',
      BackendMode.cloudyPipe => 'Click Test to verify kernel32 and Injector.exe.',
      BackendMode.xeno => 'Click Test to load Xeno.dll and verify all 6 exports.',
    };

    final okLabel = switch (_backend.mode) {
      BackendMode.dll || BackendMode.xeno => 'BOUND',
      _ => 'OK',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(testLabel, style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
            const Spacer(),
            NeonButton(
              label: 'Test',
              icon: Icons.science,
              dense: true,
              onPressed: () {
                final backend = _buildBackend();
                ref.read(executorProvider.notifier).setBackend(backend);
                ref.read(executorProvider.notifier).loadDll();
                setState(() {
                  _testResults = ref.read(executorProvider.notifier).testBindings();
                });
              },
            ),
          ],
        ),
        const SizedBox(height: J3Space.xs),
        if (_testResults == null)
          Text(testHint, style: J3Type.caption)
        else ...[
          for (final entry in _testResults!.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    entry.value ? Icons.check_circle : Icons.cancel,
                    size: 14,
                    color: entry.value ? J3Colors.success : J3Colors.error,
                  ),
                  const SizedBox(width: J3Space.xs),
                  Text(
                    entry.key,
                    style: J3Type.codeSmall.copyWith(color: entry.value ? J3Colors.success : J3Colors.error),
                  ),
                  const SizedBox(width: J3Space.sm),
                  Text(
                    entry.value ? okLabel : 'NOT FOUND',
                    style: J3Type.caption.copyWith(color: entry.value ? J3Colors.success : J3Colors.error),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  Widget _diagnosticsSection(ExecutorState state) {
    if (state.diagnostics.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('DIAGNOSTICS', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
        const SizedBox(height: J3Space.xs),
        for (final d in state.diagnostics)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  d.passed ? Icons.check_circle : Icons.warning,
                  size: 14,
                  color: d.passed ? J3Colors.success : J3Colors.warning,
                ),
                const SizedBox(width: J3Space.xs),
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(text: '${d.label}: ', style: J3Type.codeSmall),
                        TextSpan(text: d.detail ?? (d.passed ? 'OK' : 'FAIL'), style: J3Type.caption),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _actions() {
    return Container(
      padding: const EdgeInsets.all(J3Space.md),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: J3Colors.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          NeonButton.ghost(label: 'Cancel', onPressed: () => Navigator.pop(context)),
          const SizedBox(width: J3Space.sm),
          NeonButton(
            label: 'Apply & Load',
            icon: Icons.check,
            onPressed: () {
              final backend = _buildBackend();
              final ctrl = ref.read(executorProvider.notifier);
              ctrl.setBackend(backend);
              ctrl.loadDll();
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }
}
