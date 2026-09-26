import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

enum TargetArch { arm, arm64, x86, x86_64 }

enum InjectionTarget { apk, ipa }

class GadgetConfig {
  const GadgetConfig({
    required this.inputPath,
    required this.outputPath,
    required this.arch,
    required this.target,
    this.gadgetPath,
    this.fridaGadgetVersion,
    this.autoLoadScript,
    this.configJson,
    this.listenAddress = '0.0.0.0',
    this.listenPort = 27042,
  });

  final String inputPath;
  final String outputPath;
  final TargetArch arch;
  final InjectionTarget target;
  final String? gadgetPath;
  final String? fridaGadgetVersion;
  final String? autoLoadScript;
  final String? configJson;
  final String listenAddress;
  final int listenPort;
}

class InjectionStep {
  const InjectionStep(this.label, this.detail);
  final String label;
  final String detail;
}

class InjectionResult {
  const InjectionResult({
    required this.success,
    required this.outputPath,
    required this.steps,
    this.error,
  });
  final bool success;
  final String outputPath;
  final List<InjectionStep> steps;
  final String? error;
}

class GadgetInjector {
  Future<bool> hasApktool() async {
    try {
      final r = await Process.run('apktool', ['--version']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasZipalign() async {
    try {
      await Process.run('zipalign', ['-h']);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasApksigner() async {
    try {
      final r = await Process.run('apksigner', ['--version']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<InjectionResult> injectApk(GadgetConfig config, {void Function(InjectionStep)? onStep}) async {
    final steps = <InjectionStep>[];
    void step(String label, String detail) {
      final s = InjectionStep(label, detail);
      steps.add(s);
      onStep?.call(s);
    }

    try {
      final workDir = '${config.outputPath}_work';
      final dir = Directory(workDir);
      if (dir.existsSync()) dir.deleteSync(recursive: true);

      step('Decompile', 'Decompiling APK with apktool...');
      await _exec('apktool', ['d', '-f', '-o', workDir, config.inputPath]);

      step('Inject gadget', 'Copying frida-gadget to lib/${_archDir(config.arch)}/');
      final libDir = Directory('$workDir/lib/${_archDir(config.arch)}');
      if (!libDir.existsSync()) libDir.createSync(recursive: true);

      final gadgetSrc = config.gadgetPath ?? await _downloadGadget(config.arch, config.fridaGadgetVersion);
      final gadgetDst = '${libDir.path}/libfrida-gadget.so';
      File(gadgetSrc).copySync(gadgetDst);

      if (config.configJson != null) {
        step('Config', 'Writing frida-gadget config...');
        File('${libDir.path}/libfrida-gadget.config.so').writeAsStringSync(config.configJson!);
      }

      if (config.autoLoadScript != null) {
        step('Script', 'Embedding auto-load script...');
        File('${libDir.path}/libfrida-gadget-script.so').writeAsStringSync(config.autoLoadScript!);
      }

      step('Patch SMALI', 'Injecting gadget load into main activity...');
      await _patchSmali(workDir);

      step('Patch manifest', 'Adding internet permission and extractNativeLibs...');
      await _patchManifest(workDir);

      step('Rebuild', 'Rebuilding APK with apktool...');
      final rebuilt = '${config.outputPath}.unsigned.apk';
      await _exec('apktool', ['b', '-o', rebuilt, workDir]);

      step('Zipalign', 'Aligning APK...');
      final aligned = '${config.outputPath}.aligned.apk';
      await _exec('zipalign', ['-f', '4', rebuilt, aligned]);

      step('Sign', 'Signing with debug key...');
      await _exec('apksigner', [
        'sign',
        '--ks', _debugKeystore(),
        '--ks-pass', 'pass:android',
        '--ks-key-alias', 'androiddebugkey',
        '--out', config.outputPath,
        aligned,
      ]);

      step('Cleanup', 'Removing temporary files...');
      for (final f in [rebuilt, aligned]) {
        final file = File(f);
        if (file.existsSync()) file.deleteSync();
      }
      dir.deleteSync(recursive: true);

      step('Done', 'Gadget injected successfully → ${config.outputPath}');
      return InjectionResult(success: true, outputPath: config.outputPath, steps: steps);
    } catch (e) {
      return InjectionResult(success: false, outputPath: config.outputPath, steps: steps, error: '$e');
    }
  }

  Future<InjectionResult> injectIpa(GadgetConfig config, {void Function(InjectionStep)? onStep}) async {
    final steps = <InjectionStep>[];
    void step(String label, String detail) {
      final s = InjectionStep(label, detail);
      steps.add(s);
      onStep?.call(s);
    }

    try {
      final workDir = '${config.outputPath}_work';
      final dir = Directory(workDir);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);

      step('Unzip', 'Extracting IPA...');
      await _exec('unzip', ['-o', config.inputPath, '-d', workDir]);

      step('Find app', 'Locating .app bundle...');
      final payloadDir = Directory('$workDir/Payload');
      if (!payloadDir.existsSync()) throw Exception('No Payload directory in IPA');
      final appDir = payloadDir.listSync().whereType<Directory>().firstWhere(
            (d) => d.path.endsWith('.app'),
            orElse: () => throw Exception('No .app bundle found'),
          );

      step('Inject dylib', 'Copying FridaGadget.dylib...');
      final frameworksDir = Directory('${appDir.path}/Frameworks');
      if (!frameworksDir.existsSync()) frameworksDir.createSync();

      final gadgetSrc = config.gadgetPath ?? await _downloadGadgetIos(config.fridaGadgetVersion);
      File(gadgetSrc).copySync('${frameworksDir.path}/FridaGadget.dylib');

      if (config.configJson != null) {
        step('Config', 'Writing FridaGadget config...');
        File('${frameworksDir.path}/FridaGadget.config').writeAsStringSync(config.configJson!);
      }

      step('Patch binary', 'Injecting load command with insert_dylib...');
      final appName = appDir.path.split('/').last.replaceAll('.app', '');
      final binary = '${appDir.path}/$appName';
      try {
        await _exec('insert_dylib', ['--strip-codesig', '--inplace', '@executable_path/Frameworks/FridaGadget.dylib', binary]);
      } catch (_) {
        await _exec('optool', ['install', '-c', 'load', '-p', '@executable_path/Frameworks/FridaGadget.dylib', '-t', binary]);
      }

      step('Repack', 'Creating output IPA...');
      final outIpa = config.outputPath.endsWith('.ipa') ? config.outputPath : '${config.outputPath}.ipa';
      await _exec('zip', ['-r', outIpa, 'Payload'], workingDir: workDir);

      step('Cleanup', 'Removing temporary files...');
      dir.deleteSync(recursive: true);

      step('Done', 'Gadget injected → $outIpa (requires re-signing for device)');
      return InjectionResult(success: true, outputPath: outIpa, steps: steps);
    } catch (e) {
      return InjectionResult(success: false, outputPath: config.outputPath, steps: steps, error: '$e');
    }
  }

  String _archDir(TargetArch arch) => switch (arch) {
        TargetArch.arm => 'armeabi-v7a',
        TargetArch.arm64 => 'arm64-v8a',
        TargetArch.x86 => 'x86',
        TargetArch.x86_64 => 'x86_64',
      };

  Future<String> _downloadGadget(TargetArch arch, String? version) async {
    throw UnimplementedError(
        'Provide a local frida-gadget .so file. '
        'Download from https://github.com/frida/frida/releases for ${_archDir(arch)}');
  }

  Future<String> _downloadGadgetIos(String? version) async {
    throw UnimplementedError(
        'Provide a local FridaGadget.dylib. '
        'Download the iOS universal dylib from https://github.com/frida/frida/releases');
  }

  Future<void> _patchSmali(String workDir) async {
    final smaliDir = Directory('$workDir/smali');
    if (!smaliDir.existsSync()) return;

    File? mainActivity;
    await for (final entity in smaliDir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.smali')) {
        final content = entity.readAsStringSync();
        if (content.contains('.method') && content.contains('onCreate')) {
          mainActivity = entity;
          break;
        }
      }
    }

    if (mainActivity == null) return;
    var content = mainActivity.readAsStringSync();
    if (content.contains('frida-gadget')) return;

    const injection = '''
    const-string v0, "frida-gadget"
    invoke-static {v0}, Ljava/lang/System;->loadLibrary(Ljava/lang/String;)V
''';

    final onCreateMatch = RegExp(r'\.method.*onCreate.*\n(.*\.locals\s+\d+)');
    content = content.replaceFirstMapped(onCreateMatch, (m) {
      return '${m.group(0)}\n$injection';
    });
    mainActivity.writeAsStringSync(content);
  }

  Future<void> _patchManifest(String workDir) async {
    final manifest = File('$workDir/AndroidManifest.xml');
    if (!manifest.existsSync()) return;
    var content = manifest.readAsStringSync();

    if (!content.contains('android.permission.INTERNET')) {
      content = content.replaceFirst(
        '<application',
        '<uses-permission android:name="android.permission.INTERNET"/>\n    <application',
      );
    }

    if (!content.contains('extractNativeLibs')) {
      content = content.replaceFirst(
        '<application',
        '<application android:extractNativeLibs="true"',
      );
    }
    manifest.writeAsStringSync(content);
  }

  String _debugKeystore() {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
    final ks = '$home/.android/debug.keystore';
    if (File(ks).existsSync()) return ks;
    return 'android/test-signing/j3-test.keystore';
  }

  Future<void> _exec(String exe, List<String> args, {String? workingDir}) async {
    final result = await Process.run(exe, args, workingDirectory: workingDir);
    if (result.exitCode != 0) {
      throw Exception('$exe failed (exit ${result.exitCode}): ${result.stderr}');
    }
  }
}

final gadgetInjectorProvider = Provider<GadgetInjector>((ref) => GadgetInjector());
