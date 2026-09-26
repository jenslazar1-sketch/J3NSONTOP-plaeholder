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
    final isProcess = _backend.mode == BackendMode.process;

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
                    if (isProcess) ...[
                      _exePathField(),
                      const SizedBox(height: J3Space.md),
                      _processFields(),
                      const SizedBox(height: J3Space.md),
                      _autoexecField(),
                    ] else ...[
                      _dllPathField(),
                      const SizedBox(height: J3Space.md),
                      _functionFields(),
                    ],
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
    final isProcess = _backend.mode == BackendMode.process;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: J3Space.sm, vertical: J3Space.xs),
      decoration: BoxDecoration(
        color: isProcess ? J3Colors.info.withValues(alpha: 0.1) : J3Colors.neon.withValues(alpha: 0.1),
        borderRadius: J3Radius.small,
        border: Border.all(
          color: isProcess ? J3Colors.info.withValues(alpha: 0.3) : J3Colors.neon.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isProcess ? Icons.terminal : Icons.extension,
            size: 14,
            color: isProcess ? J3Colors.info : J3Colors.neonText,
          ),
          const SizedBox(width: J3Space.xs),
          Text(
            isProcess ? 'PROCESS MODE' : 'DLL MODE',
            style: J3Type.kicker.copyWith(
              color: isProcess ? J3Colors.info : J3Colors.neonText,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(width: J3Space.sm),
          Expanded(
            child: Text(
              isProcess
                  ? 'Launches an EXE to inject and writes scripts to files'
                  : 'Loads a DLL via FFI and calls exported functions',
              style: J3Type.caption,
            ),
          ),
        ],
      ),
    );
  }

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
    final isProcess = _backend.mode == BackendMode.process;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              isProcess ? 'TEST PATHS' : 'TEST BINDINGS',
              style: J3Type.kicker.copyWith(color: J3Colors.neonText),
            ),
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
          Text(
            isProcess
                ? 'Click Test to verify paths and folder access.'
                : 'Click Test to load the DLL and check function bindings.',
            style: J3Type.caption,
          )
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
                    entry.value ? (isProcess ? 'OK' : 'BOUND') : 'NOT FOUND',
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
