import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/gadget_injector.dart';

class GadgetInjectorPage extends ConsumerStatefulWidget {
  const GadgetInjectorPage({super.key});
  static const id = 'frida.gadget';

  @override
  ConsumerState<GadgetInjectorPage> createState() => _GadgetInjectorPageState();
}

class _GadgetInjectorPageState extends ConsumerState<GadgetInjectorPage> {
  final _inputPathController = TextEditingController();
  final _outputPathController = TextEditingController();
  final _gadgetPathController = TextEditingController();
  final _scriptController = TextEditingController();
  final _configController = TextEditingController();
  InjectionTarget _target = InjectionTarget.apk;
  TargetArch _arch = TargetArch.arm64;
  bool _injecting = false;
  InjectionResult? _result;
  final List<InjectionStep> _steps = [];
  bool _hasApktool = false;
  bool _hasZipalign = false;
  bool _hasApksigner = false;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _checkTools();
    _configController.text = '''{
  "interaction": "listen",
  "type": "listen",
  "address": "0.0.0.0",
  "port": 27042,
  "on_load": "resume"
}''';
  }

  @override
  void dispose() {
    _inputPathController.dispose();
    _outputPathController.dispose();
    _gadgetPathController.dispose();
    _scriptController.dispose();
    _configController.dispose();
    super.dispose();
  }

  Future<void> _checkTools() async {
    final injector = ref.read(gadgetInjectorProvider);
    final results = await Future.wait([
      injector.hasApktool(),
      injector.hasZipalign(),
      injector.hasApksigner(),
    ]);
    setState(() {
      _hasApktool = results[0];
      _hasZipalign = results[1];
      _hasApksigner = results[2];
      _checked = true;
    });
  }

  Future<void> _inject() async {
    if (_inputPathController.text.isEmpty || _outputPathController.text.isEmpty) return;
    setState(() { _injecting = true; _result = null; _steps.clear(); });

    final injector = ref.read(gadgetInjectorProvider);
    final config = GadgetConfig(
      inputPath: _inputPathController.text,
      outputPath: _outputPathController.text,
      arch: _arch,
      target: _target,
      gadgetPath: _gadgetPathController.text.isNotEmpty ? _gadgetPathController.text : null,
      autoLoadScript: _scriptController.text.isNotEmpty ? _scriptController.text : null,
      configJson: _configController.text.isNotEmpty ? _configController.text : null,
    );

    InjectionResult result;
    if (_target == InjectionTarget.apk) {
      result = await injector.injectApk(config, onStep: (s) => setState(() => _steps.add(s)));
    } else {
      result = await injector.injectIpa(config, onStep: (s) => setState(() => _steps.add(s)));
    }
    setState(() { _result = result; _injecting = false; });
  }

  @override
  Widget build(BuildContext context) {
    return ToolScaffold(
      toolId: GadgetInjectorPage.id,
      inputs: [
        _buildToolStatus(),
        const SizedBox(height: J3Space.md),
        _buildTargetConfig(),
        const SizedBox(height: J3Space.md),
        _buildGadgetConfig(),
        const SizedBox(height: J3Space.md),
        _buildAutoScript(),
        const SizedBox(height: J3Space.md),
        NeonButton(
          label: _injecting ? 'Injecting...' : 'Inject Gadget',
          icon: Icons.vaccines,
          busy: _injecting,
          onPressed: _injecting ? null : _inject,
          expand: true,
        ),
      ],
      results: [
        _buildProgress(),
        if (_result != null) ...[
          const SizedBox(height: J3Space.md),
          _buildResult(),
        ],
      ],
    );
  }

  Widget _buildToolStatus() {
    if (!_checked) return const SizedBox.shrink();
    return NeonPanel(
      kicker: 'PREREQUISITES',
      emphasis: (_hasApktool && _hasZipalign && _hasApksigner) ? PanelEmphasis.success : PanelEmphasis.danger,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _toolRow('apktool', _hasApktool),
          _toolRow('zipalign', _hasZipalign),
          _toolRow('apksigner', _hasApksigner),
          if (!_hasApktool || !_hasZipalign || !_hasApksigner)
            Padding(
              padding: const EdgeInsets.only(top: J3Space.sm),
              child: Text('Install missing tools for APK injection. IPA injection needs insert_dylib or optool.', style: J3Type.caption),
            ),
        ],
      ),
    );
  }

  Widget _toolRow(String name, bool available) {
    return Padding(
      padding: const EdgeInsets.only(bottom: J3Space.xs),
      child: Row(
        children: [
          Icon(available ? Icons.check_circle : Icons.cancel, size: 14, color: available ? J3Colors.success : J3Colors.error),
          const SizedBox(width: J3Space.sm),
          Text(name, style: J3Type.code),
        ],
      ),
    );
  }

  Widget _buildTargetConfig() {
    return NeonPanel(
      kicker: 'TARGET',
      icon: Icons.file_present,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ChoiceChip(
                label: const Text('APK'),
                selected: _target == InjectionTarget.apk,
                onSelected: (_) => setState(() => _target = InjectionTarget.apk),
                selectedColor: J3Colors.darkRed,
                labelStyle: J3Type.code,
              ),
              const SizedBox(width: J3Space.sm),
              ChoiceChip(
                label: const Text('IPA'),
                selected: _target == InjectionTarget.ipa,
                onSelected: (_) => setState(() => _target = InjectionTarget.ipa),
                selectedColor: J3Colors.darkRed,
                labelStyle: J3Type.code,
              ),
            ],
          ),
          const SizedBox(height: J3Space.md),
          TextField(
            controller: _inputPathController,
            style: J3Type.codeSmall,
            decoration: _inputDecor('Input ${_target == InjectionTarget.apk ? 'APK' : 'IPA'} path'),
          ),
          const SizedBox(height: J3Space.sm),
          TextField(
            controller: _outputPathController,
            style: J3Type.codeSmall,
            decoration: _inputDecor('Output path'),
          ),
          if (_target == InjectionTarget.apk) ...[
            const SizedBox(height: J3Space.md),
            Text('Architecture', style: J3Type.caption),
            const SizedBox(height: J3Space.xs),
            Wrap(
              spacing: J3Space.sm,
              children: TargetArch.values.map((a) => ChoiceChip(
                label: Text(a.name),
                selected: _arch == a,
                onSelected: (_) => setState(() => _arch = a),
                selectedColor: J3Colors.darkRed,
                labelStyle: J3Type.codeSmall,
              )).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGadgetConfig() {
    return NeonPanel(
      kicker: 'GADGET',
      icon: Icons.settings_input_component,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _gadgetPathController,
            style: J3Type.codeSmall,
            decoration: _inputDecor('Frida gadget .so/.dylib path (optional — downloads if empty)'),
          ),
          const SizedBox(height: J3Space.md),
          Text('Gadget Config JSON', style: J3Type.caption),
          const SizedBox(height: J3Space.xs),
          TextField(
            controller: _configController,
            style: J3Type.codeSmall,
            maxLines: 6,
            decoration: _inputDecor(''),
          ),
        ],
      ),
    );
  }

  Widget _buildAutoScript() {
    return NeonPanel(
      kicker: 'AUTO-LOAD SCRIPT',
      icon: Icons.code,
      child: TextField(
        controller: _scriptController,
        style: J3Type.codeSmall,
        maxLines: 8,
        decoration: _inputDecor('Optional JS script to bundle with the gadget'),
      ),
    );
  }

  Widget _buildProgress() {
    return NeonPanel(
      kicker: 'PROGRESS',
      icon: Icons.timeline,
      emphasis: _injecting ? PanelEmphasis.strong : PanelEmphasis.subtle,
      child: _steps.isEmpty
          ? Text('Ready to inject', style: J3Type.caption)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _steps.map((s) => Padding(
                padding: const EdgeInsets.only(bottom: J3Space.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.chevron_right, size: 14, color: J3Colors.success),
                    const SizedBox(width: J3Space.xs),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.label, style: J3Type.label),
                          Text(s.detail, style: J3Type.caption),
                        ],
                      ),
                    ),
                  ],
                ),
              )).toList(),
            ),
    );
  }

  Widget _buildResult() {
    final r = _result!;
    return NeonPanel(
      kicker: 'RESULT',
      icon: r.success ? Icons.check_circle : Icons.error,
      emphasis: r.success ? PanelEmphasis.success : PanelEmphasis.danger,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r.success ? 'Injection successful!' : 'Injection failed', style: J3Type.subtitle),

          const SizedBox(height: J3Space.xs),
          if (r.success)
            Text('Output: ${r.outputPath}', style: J3Type.codeSmall)
          else if (r.error != null)
            Text('Error: ${r.error}', style: J3Type.codeSmall.copyWith(color: J3Colors.error)),
        ],
      ),
    );
  }

  InputDecoration _inputDecor(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: J3Type.codeSmall.copyWith(color: J3Colors.textMuted),
    isDense: true,
    contentPadding: const EdgeInsets.all(J3Space.sm),
    filled: true,
    fillColor: J3Colors.inputFill,
    border: OutlineInputBorder(borderRadius: J3Radius.small, borderSide: BorderSide(color: J3Colors.border)),
  );
}
