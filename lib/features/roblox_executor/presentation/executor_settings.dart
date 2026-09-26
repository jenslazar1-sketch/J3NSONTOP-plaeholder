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
  final _dllPathController = TextEditingController();
  final _isAttachedController = TextEditingController();
  final _attachController = TextEditingController();
  final _executeController = TextEditingController();
  final _settingsController = TextEditingController();
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
  }

  @override
  void dispose() {
    _dllPathController.dispose();
    _isAttachedController.dispose();
    _attachController.dispose();
    _executeController.dispose();
    _settingsController.dispose();
    super.dispose();
  }

  DllBackend _buildBackend() => _backend.copyWith(
    customDllPath: _dllPathController.text.isEmpty ? null : _dllPathController.text,
    isAttachedFn: _isAttachedController.text,
    attachFn: _attachController.text,
    executeFn: _executeController.text,
    settingsFn: _settingsController.text,
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
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
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
                    const SizedBox(height: J3Space.md),
                    _dllPathField(),
                    const SizedBox(height: J3Space.md),
                    _functionFields(),
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
              label: Text(b.name, style: J3Type.codeSmall.copyWith(fontSize: 11)),
              selected: selected,
              selectedColor: J3Colors.darkRed,
              visualDensity: VisualDensity.compact,
              onSelected: (_) {
                setState(() {
                  _backend = b.copyWith(customDllPath: _backend.customDllPath);
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('TEST BINDINGS', style: J3Type.kicker.copyWith(color: J3Colors.neonText)),
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
          Text('Click Test to load the DLL and check function bindings.', style: J3Type.caption)
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
                    entry.value ? 'BOUND' : 'NOT FOUND',
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
