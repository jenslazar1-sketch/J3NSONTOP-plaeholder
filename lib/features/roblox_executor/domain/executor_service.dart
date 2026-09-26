import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();

typedef _IntNative = Int32 Function();
typedef _IntDart = int Function();

typedef _PtrVoidNative = Void Function(Pointer<Uint8> arg);
typedef _PtrVoidDart = void Function(Pointer<Uint8> arg);

typedef _MallocNative = Pointer<Uint8> Function(IntPtr size);
typedef _MallocDart = Pointer<Uint8> Function(int size);

typedef _FreeNative = Void Function(Pointer<Uint8> ptr);
typedef _FreeDart = void Function(Pointer<Uint8> ptr);

Pointer<Uint8> _toNativeUtf8(String s) {
  final units = utf8.encode(s);
  final len = units.length;
  final ptr = _stdlib.lookupFunction<_MallocNative, _MallocDart>('malloc')(len + 1);
  final list = ptr.asTypedList(len + 1);
  list.setAll(0, units);
  list[len] = 0;
  return ptr;
}

void _freeNativeUtf8(Pointer<Uint8> ptr) {
  _stdlib.lookupFunction<_FreeNative, _FreeDart>('free')(ptr);
}

final DynamicLibrary _stdlib = DynamicLibrary.process();

class DllBackend {
  const DllBackend({
    required this.name,
    this.dllFileName = '',
    this.isAttachedFn = 'IsAttached',
    this.attachFn = 'Attach',
    this.executeFn = 'Execute',
    this.settingsFn = 'SetSettings',
    this.customDllPath,
  });

  final String name;
  final String dllFileName;
  final String isAttachedFn;
  final String attachFn;
  final String executeFn;
  final String settingsFn;
  final String? customDllPath;

  DllBackend copyWith({
    String? name,
    String? dllFileName,
    String? isAttachedFn,
    String? attachFn,
    String? executeFn,
    String? settingsFn,
    String? customDllPath,
  }) {
    return DllBackend(
      name: name ?? this.name,
      dllFileName: dllFileName ?? this.dllFileName,
      isAttachedFn: isAttachedFn ?? this.isAttachedFn,
      attachFn: attachFn ?? this.attachFn,
      executeFn: executeFn ?? this.executeFn,
      settingsFn: settingsFn ?? this.settingsFn,
      customDllPath: customDllPath ?? this.customDllPath,
    );
  }

  Map<String, String> toJson() => {
    'name': name,
    'dllFileName': dllFileName,
    'isAttachedFn': isAttachedFn,
    'attachFn': attachFn,
    'executeFn': executeFn,
    'settingsFn': settingsFn,
    // ignore: use_null_aware_elements
    if (customDllPath != null) 'customDllPath': customDllPath!,
  };

  factory DllBackend.fromJson(Map<String, dynamic> j) => DllBackend(
    name: j['name'] as String? ?? 'Custom',
    dllFileName: j['dllFileName'] as String? ?? '',
    isAttachedFn: j['isAttachedFn'] as String? ?? 'IsAttached',
    attachFn: j['attachFn'] as String? ?? 'Attach',
    executeFn: j['executeFn'] as String? ?? 'Execute',
    settingsFn: j['settingsFn'] as String? ?? 'SetSettings',
    customDllPath: j['customDllPath'] as String?,
  );
}

const List<DllBackend> builtInBackends = [
  DllBackend(
    name: 'WeAreDevs API',
    dllFileName: 'wearedevs_exploit_api.dll',
    isAttachedFn: 'IsAttached',
    attachFn: 'Attach',
    executeFn: 'Execute',
    settingsFn: 'SetSettings',
  ),
  DllBackend(
    name: 'Krnl',
    dllFileName: 'krnl.dll',
    isAttachedFn: 'is_injected',
    attachFn: 'inject',
    executeFn: 'execute',
    settingsFn: '',
  ),
  DllBackend(
    name: 'Fluxus',
    dllFileName: 'fluxus.dll',
    isAttachedFn: 'isAttached',
    attachFn: 'attach',
    executeFn: 'runScript',
    settingsFn: '',
  ),
  DllBackend(
    name: 'Oxygen U',
    dllFileName: 'oxygenu.dll',
    isAttachedFn: 'IsInjected',
    attachFn: 'Inject',
    executeFn: 'Execute',
    settingsFn: '',
  ),
  DllBackend(
    name: 'Custom DLL',
    dllFileName: '',
    isAttachedFn: 'IsAttached',
    attachFn: 'Attach',
    executeFn: 'Execute',
    settingsFn: '',
  ),
];

enum ExecutorStatus { unloaded, ready, attaching, attached, error }

class DllDiagnostic {
  const DllDiagnostic({required this.label, required this.passed, this.detail});
  final String label;
  final bool passed;
  final String? detail;
}

class ExecutorState {
  const ExecutorState({
    this.status = ExecutorStatus.unloaded,
    this.error,
    this.output = const [],
    this.lastScript = '',
    this.activeBackend = const DllBackend(name: 'WeAreDevs API', dllFileName: 'wearedevs_exploit_api.dll'),
    this.loadedDllPath,
    this.diagnostics = const [],
    this.boundFunctions = const [],
  });

  final ExecutorStatus status;
  final String? error;
  final List<String> output;
  final String lastScript;
  final DllBackend activeBackend;
  final String? loadedDllPath;
  final List<DllDiagnostic> diagnostics;
  final List<String> boundFunctions;

  ExecutorState copyWith({
    ExecutorStatus? status,
    String? error,
    List<String>? output,
    String? lastScript,
    DllBackend? activeBackend,
    String? loadedDllPath,
    List<DllDiagnostic>? diagnostics,
    List<String>? boundFunctions,
  }) {
    return ExecutorState(
      status: status ?? this.status,
      error: error,
      output: output ?? this.output,
      lastScript: lastScript ?? this.lastScript,
      activeBackend: activeBackend ?? this.activeBackend,
      loadedDllPath: loadedDllPath ?? this.loadedDllPath,
      diagnostics: diagnostics ?? this.diagnostics,
      boundFunctions: boundFunctions ?? this.boundFunctions,
    );
  }
}

class ExecutorController extends Notifier<ExecutorState> {
  DynamicLibrary? _lib;
  _IntDart? _isAttached;
  _VoidDart? _attach;
  _PtrVoidDart? _execute;
  _PtrVoidDart? _setSettings;

  @override
  ExecutorState build() => const ExecutorState();

  void setBackend(DllBackend backend) {
    unloadDll();
    state = state.copyWith(activeBackend: backend, status: ExecutorStatus.unloaded);
    addOutput('[*] Backend switched to: ${backend.name}');
  }

  List<String> _findDllCandidates(DllBackend backend) {
    final exe = Platform.resolvedExecutable;
    final dir = File(exe).parent.path;
    final sep = Platform.pathSeparator;
    final paths = <String>[];

    if (backend.customDllPath != null && backend.customDllPath!.isNotEmpty) {
      paths.add(backend.customDllPath!);
    }

    if (backend.dllFileName.isNotEmpty) {
      paths.addAll([
        '$dir$sep${backend.dllFileName}',
        '$dir${sep}data$sep${backend.dllFileName}',
        '$dir${sep}bin$sep${backend.dllFileName}',
      ]);
    }

    return paths;
  }

  List<DllDiagnostic> _diagnose(String path) {
    final results = <DllDiagnostic>[];
    final file = File(path);

    results.add(
      DllDiagnostic(
        label: 'File exists',
        passed: file.existsSync(),
        detail: file.existsSync() ? path : 'Not found at $path',
      ),
    );
    if (!file.existsSync()) return results;

    final stat = file.statSync();
    results.add(
      DllDiagnostic(label: 'File size', passed: stat.size > 0, detail: '${(stat.size / 1024).toStringAsFixed(1)} KB'),
    );

    try {
      final bytes = file.openSync(mode: FileMode.read);
      final header = bytes.readSync(512);
      bytes.closeSync();

      final isDll = header.length >= 2 && header[0] == 0x4D && header[1] == 0x5A;
      results.add(
        DllDiagnostic(
          label: 'Valid PE (MZ header)',
          passed: isDll,
          detail: isDll ? 'Valid Windows DLL/EXE' : 'Not a valid PE file — may be corrupted or wrong format',
        ),
      );

      if (isDll && header.length >= 64) {
        final peOffset = header[60] | (header[61] << 8) | (header[62] << 16) | (header[63] << 24);
        if (peOffset > 0 && peOffset + 6 < header.length) {
          final machine = header[peOffset + 4] | (header[peOffset + 5] << 8);
          final is64 = machine == 0x8664;
          final is32 = machine == 0x014C;
          results.add(
            DllDiagnostic(
              label: 'Architecture',
              passed: is64,
              detail: is64
                  ? 'x86-64 (matches Flutter Windows)'
                  : is32
                  ? 'x86 (32-bit) — incompatible with 64-bit Flutter app'
                  : 'Unknown architecture (0x${machine.toRadixString(16)})',
            ),
          );
        }
      }
    } catch (e) {
      results.add(
        DllDiagnostic(
          label: 'File readable',
          passed: false,
          detail: 'Cannot read file: $e — may be locked by antivirus or another process',
        ),
      );
    }

    final avHints = [
      'Windows Defender',
      'Avast',
      'AVG',
      'Norton',
      'McAfee',
      'Kaspersky',
      'Bitdefender',
      'Malwarebytes',
    ];
    results.add(
      DllDiagnostic(
        label: 'Antivirus note',
        passed: true,
        detail:
            'If loading fails, check that ${avHints.take(3).join(", ")} etc. '
            'have not quarantined or blocked the DLL',
      ),
    );

    return results;
  }

  bool loadDll() {
    if (_lib != null) return true;
    if (!Platform.isWindows) {
      state = state.copyWith(status: ExecutorStatus.error, error: 'Windows only');
      return false;
    }

    final backend = state.activeBackend;
    final candidates = _findDllCandidates(backend);

    if (candidates.isEmpty) {
      state = state.copyWith(
        status: ExecutorStatus.error,
        error: 'No DLL path configured. Open Settings to pick a DLL file.',
      );
      return false;
    }

    String? foundPath;
    for (final p in candidates) {
      if (File(p).existsSync()) {
        foundPath = p;
        break;
      }
    }

    if (foundPath == null) {
      final searched = candidates.map((p) => '  - $p').join('\n');
      addOutput('[!] DLL not found. Searched:\n$searched');
      final diagnostics = _diagnose(candidates.first);
      state = state.copyWith(
        status: ExecutorStatus.error,
        error:
            '${backend.dllFileName.isEmpty ? "DLL" : backend.dllFileName} not found. '
            'Searched ${candidates.length} locations. Open Settings to set a custom path.',
        diagnostics: diagnostics,
      );
      return false;
    }

    addOutput('[*] Found DLL at: $foundPath');
    final diagnostics = _diagnose(foundPath);
    state = state.copyWith(diagnostics: diagnostics);

    for (final d in diagnostics) {
      final icon = d.passed ? '[+]' : '[!]';
      addOutput('$icon ${d.label}: ${d.detail ?? (d.passed ? "OK" : "FAIL")}');
    }

    final archCheck = diagnostics.where((d) => d.label == 'Architecture' && !d.passed);
    if (archCheck.isNotEmpty) {
      state = state.copyWith(
        status: ExecutorStatus.error,
        error: 'Architecture mismatch — ${archCheck.first.detail}',
        diagnostics: diagnostics,
      );
      return false;
    }

    try {
      _lib = DynamicLibrary.open(foundPath);
      addOutput('[+] DLL opened successfully');
    } on ArgumentError catch (e) {
      final msg = e.message.toString();
      String hint;
      if (msg.contains('126') || msg.contains('module could not be found')) {
        hint = 'Missing dependencies — the DLL requires other DLLs not present on this system';
      } else if (msg.contains('193') || msg.contains('not a valid Win32 application')) {
        hint = 'Architecture mismatch — the DLL is 32-bit but this app is 64-bit (or vice versa)';
      } else if (msg.contains('5') || msg.contains('Access is denied')) {
        hint = 'Access denied — antivirus may be blocking the DLL, or it is in use by another process';
      } else {
        hint = 'OS error: $msg';
      }
      state = state.copyWith(
        status: ExecutorStatus.error,
        error: 'DLL load failed: $hint',
        diagnostics: diagnostics,
        loadedDllPath: foundPath,
      );
      addOutput('[!] Load failed: $hint');
      return false;
    } catch (e) {
      state = state.copyWith(
        status: ExecutorStatus.error,
        error: 'DLL load failed: $e',
        diagnostics: diagnostics,
        loadedDllPath: foundPath,
      );
      addOutput('[!] Load failed: $e');
      return false;
    }

    final bound = <String>[];

    _isAttached = _bindInt(backend.isAttachedFn);
    if (_isAttached != null) bound.add(backend.isAttachedFn);

    _attach = _bindVoid(backend.attachFn);
    if (_attach != null) bound.add(backend.attachFn);

    _execute = _bindPtrVoid(backend.executeFn);
    if (_execute != null) bound.add(backend.executeFn);

    if (backend.settingsFn.isNotEmpty) {
      _setSettings = _bindPtrVoid(backend.settingsFn);
      if (_setSettings != null) bound.add(backend.settingsFn);
    }

    if (_execute == null) {
      state = state.copyWith(
        status: ExecutorStatus.error,
        error:
            'Could not bind "${backend.executeFn}" — function not found in DLL. '
            'Open Settings to configure the correct function names.',
        loadedDllPath: foundPath,
        boundFunctions: bound,
      );
      addOutput('[!] Critical: "${backend.executeFn}" not found in DLL exports');
      return false;
    }

    addOutput('[+] Bound ${bound.length} functions: ${bound.join(", ")}');
    if (_attach == null) {
      addOutput('[*] No attach function — will attempt direct execution');
    }

    state = state.copyWith(status: ExecutorStatus.ready, loadedDllPath: foundPath, boundFunctions: bound);
    return true;
  }

  _IntDart? _bindInt(String name) {
    if (name.isEmpty || _lib == null) return null;
    try {
      return _lib!.lookupFunction<_IntNative, _IntDart>(name);
    } catch (_) {
      addOutput('[!] Function "$name" not found in DLL');
      return null;
    }
  }

  _VoidDart? _bindVoid(String name) {
    if (name.isEmpty || _lib == null) return null;
    try {
      return _lib!.lookupFunction<_VoidNative, _VoidDart>(name);
    } catch (_) {
      addOutput('[!] Function "$name" not found in DLL');
      return null;
    }
  }

  _PtrVoidDart? _bindPtrVoid(String name) {
    if (name.isEmpty || _lib == null) return null;
    try {
      return _lib!.lookupFunction<_PtrVoidNative, _PtrVoidDart>(name);
    } catch (_) {
      addOutput('[!] Function "$name" not found in DLL');
      return null;
    }
  }

  void unloadDll() {
    _lib = null;
    _isAttached = null;
    _attach = null;
    _execute = null;
    _setSettings = null;
    state = state.copyWith(status: ExecutorStatus.unloaded, loadedDllPath: null, boundFunctions: [], diagnostics: []);
  }

  Map<String, bool> testBindings() {
    final backend = state.activeBackend;
    final results = <String, bool>{};

    if (_lib == null) {
      for (final fn in [backend.isAttachedFn, backend.attachFn, backend.executeFn, backend.settingsFn]) {
        if (fn.isNotEmpty) results[fn] = false;
      }
      return results;
    }

    for (final fn in [backend.isAttachedFn, backend.attachFn, backend.executeFn, backend.settingsFn]) {
      if (fn.isEmpty) continue;
      try {
        _lib!.lookup(fn);
        results[fn] = true;
      } catch (_) {
        results[fn] = false;
      }
    }

    return results;
  }

  bool get isAttached {
    if (_isAttached == null) return false;
    try {
      return _isAttached!() != 0;
    } catch (_) {
      return false;
    }
  }

  void attach() {
    if (_attach == null && _execute != null) {
      state = state.copyWith(status: ExecutorStatus.attached);
      addOutput('[+] No attach function — direct execution mode enabled');
      return;
    }
    if (_attach == null) {
      addOutput('[!] DLL not loaded or no attach function');
      return;
    }

    state = state.copyWith(status: ExecutorStatus.attaching);
    addOutput('[*] Attaching to RobloxPlayerBeta.exe...');

    try {
      _attach!();
      if (isAttached) {
        state = state.copyWith(status: ExecutorStatus.attached);
        addOutput('[+] Attached to Roblox!');
      } else {
        state = state.copyWith(status: ExecutorStatus.ready);
        addOutput('[!] Attach called but not yet attached. Is Roblox running?');
      }
    } catch (e) {
      state = state.copyWith(status: ExecutorStatus.error, error: '$e');
      addOutput('[!] Attach failed: $e');
    }
  }

  void execute(String script) {
    if (_execute == null) {
      addOutput('[!] DLL not loaded — no execute function bound');
      return;
    }
    if (state.status != ExecutorStatus.attached) {
      addOutput('[!] Not attached. Click Attach first.');
      return;
    }

    state = state.copyWith(lastScript: script);
    addOutput('[>] Executing script (${script.length} chars)...');

    final ptr = _toNativeUtf8(script);
    try {
      _execute!(ptr);
      addOutput('[+] Script executed.');
    } catch (e) {
      addOutput('[!] Execute failed: $e');
    } finally {
      _freeNativeUtf8(ptr);
    }
  }

  void applySettings(String settings) {
    if (_setSettings == null) {
      addOutput('[*] No settings function for this backend');
      return;
    }
    final ptr = _toNativeUtf8(settings);
    try {
      _setSettings!(ptr);
      addOutput('[*] Settings applied.');
    } catch (e) {
      addOutput('[!] SetSettings failed: $e');
    } finally {
      _freeNativeUtf8(ptr);
    }
  }

  void addOutput(String line) {
    final lines = [...state.output, line];
    if (lines.length > 5000) lines.removeRange(0, lines.length - 5000);
    state = state.copyWith(output: lines);
  }

  void clearOutput() => state = state.copyWith(output: []);
}

final executorProvider = NotifierProvider<ExecutorController, ExecutorState>(ExecutorController.new);
