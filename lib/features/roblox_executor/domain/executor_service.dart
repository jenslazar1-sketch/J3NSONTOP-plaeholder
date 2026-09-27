import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

// ---------------------------------------------------------------------------
// FFI typedefs — standard
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// FFI typedefs — Cloudy API
// ---------------------------------------------------------------------------

// ExecuteAsync(uint8_t* script, char** clientUsers, int32_t numUsers)
typedef _CloudyExecNative = Void Function(Pointer<Uint8>, Pointer<Pointer<Uint8>>, Int32);
typedef _CloudyExecDart = void Function(Pointer<Uint8>, Pointer<Pointer<Uint8>>, int);

// GetClients() -> void* (pointer to null-terminated ClientInfo array)
typedef _PtrRetNative = Pointer<Void> Function();
typedef _PtrRetDart = Pointer<Void> Function();

// ---------------------------------------------------------------------------
// FFI typedefs — Xeno API
// ---------------------------------------------------------------------------

// Execute(char* script) -> bool (int32)
typedef _XenoExecNative = Int32 Function(Pointer<Uint8>);
typedef _XenoExecDart = int Function(Pointer<Uint8>);

// Version() -> char*
typedef _StrRetNative = Pointer<Uint8> Function();
typedef _StrRetDart = Pointer<Uint8> Function();

// SetSetting(char* key, char* value)
typedef _TwoPtrVoidNative = Void Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _TwoPtrVoidDart = void Function(Pointer<Uint8>, Pointer<Uint8>);

// ---------------------------------------------------------------------------
// FFI typedefs — kernel32 named-pipe I/O
// ---------------------------------------------------------------------------

typedef _CreateFileWN = IntPtr Function(Pointer<Uint16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr);
typedef _CreateFileWD = int Function(Pointer<Uint16>, int, int, Pointer<Void>, int, int, int);

typedef _RwFileN = Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>);
typedef _RwFileD = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>);

typedef _CloseHandleN = Int32 Function(IntPtr);
typedef _CloseHandleD = int Function(int);

typedef _WaitPipeN = Int32 Function(Pointer<Uint16>, Uint32);
typedef _WaitPipeD = int Function(Pointer<Uint16>, int);

// ---------------------------------------------------------------------------
// String conversion helpers
// ---------------------------------------------------------------------------

final DynamicLibrary _stdlib = DynamicLibrary.process();

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

Pointer<Uint16> _toNativeUtf16(String s) {
  final units = s.codeUnits;
  final len = units.length;
  final raw = _stdlib.lookupFunction<_MallocNative, _MallocDart>('malloc')((len + 1) * 2);
  final ptr = raw.cast<Uint16>();
  final list = ptr.asTypedList(len + 1);
  list.setAll(0, units);
  list[len] = 0;
  return ptr;
}

String _readCString(Pointer<Uint8> ptr) {
  if (ptr.address == 0) return '';
  final bytes = <int>[];
  for (var i = 0; i < 4096; i++) {
    final b = ptr[i];
    if (b == 0) break;
    bytes.add(b);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

Pointer<Pointer<Uint8>> _toNativeStringArray(List<String> strings) {
  final ptrSize = sizeOf<IntPtr>();
  final raw = _stdlib.lookupFunction<_MallocNative, _MallocDart>('malloc')(ptrSize * strings.length);
  final array = raw.cast<Pointer<Uint8>>();
  for (var i = 0; i < strings.length; i++) {
    array[i] = _toNativeUtf8(strings[i]);
  }
  return array;
}

void _freeNativeStringArray(Pointer<Pointer<Uint8>> array, int count) {
  for (var i = 0; i < count; i++) {
    _freeNativeUtf8(array[i]);
  }
  _freeNativeUtf8(array.cast<Uint8>());
}

// ---------------------------------------------------------------------------
// Backend model
// ---------------------------------------------------------------------------

enum BackendMode { dll, process, cloudy, cloudyPipe, xeno }

class DllBackend {
  const DllBackend({
    required this.name,
    this.mode = BackendMode.dll,
    this.dllFileName = '',
    this.isAttachedFn = 'IsAttached',
    this.attachFn = 'Attach',
    this.executeFn = 'Execute',
    this.settingsFn = 'SetSettings',
    this.customDllPath,
    this.exePath,
    this.injectArgs = '',
    this.executeArgsTemplate = '{script_path}',
    this.autoexecDir,
  });

  final String name;
  final BackendMode mode;
  final String dllFileName;
  final String isAttachedFn;
  final String attachFn;
  final String executeFn;
  final String settingsFn;
  final String? customDllPath;
  final String? exePath;
  final String injectArgs;
  final String executeArgsTemplate;
  final String? autoexecDir;

  DllBackend copyWith({
    String? name,
    BackendMode? mode,
    String? dllFileName,
    String? isAttachedFn,
    String? attachFn,
    String? executeFn,
    String? settingsFn,
    String? customDllPath,
    String? exePath,
    String? injectArgs,
    String? executeArgsTemplate,
    String? autoexecDir,
  }) {
    return DllBackend(
      name: name ?? this.name,
      mode: mode ?? this.mode,
      dllFileName: dllFileName ?? this.dllFileName,
      isAttachedFn: isAttachedFn ?? this.isAttachedFn,
      attachFn: attachFn ?? this.attachFn,
      executeFn: executeFn ?? this.executeFn,
      settingsFn: settingsFn ?? this.settingsFn,
      customDllPath: customDllPath ?? this.customDllPath,
      exePath: exePath ?? this.exePath,
      injectArgs: injectArgs ?? this.injectArgs,
      executeArgsTemplate: executeArgsTemplate ?? this.executeArgsTemplate,
      autoexecDir: autoexecDir ?? this.autoexecDir,
    );
  }

  Map<String, String> toJson() => {
    'name': name,
    'mode': mode.name,
    'dllFileName': dllFileName,
    'isAttachedFn': isAttachedFn,
    'attachFn': attachFn,
    'executeFn': executeFn,
    'settingsFn': settingsFn,
    'injectArgs': injectArgs,
    'executeArgsTemplate': executeArgsTemplate,
    // ignore: use_null_aware_elements
    if (customDllPath != null) 'customDllPath': customDllPath!,
    // ignore: use_null_aware_elements
    if (exePath != null) 'exePath': exePath!,
    // ignore: use_null_aware_elements
    if (autoexecDir != null) 'autoexecDir': autoexecDir!,
  };

  factory DllBackend.fromJson(Map<String, dynamic> j) => DllBackend(
    name: j['name'] as String? ?? 'Custom',
    mode: switch (j['mode']) {
      'process' => BackendMode.process,
      'cloudy' => BackendMode.cloudy,
      'cloudyPipe' => BackendMode.cloudyPipe,
      'xeno' => BackendMode.xeno,
      _ => BackendMode.dll,
    },
    dllFileName: j['dllFileName'] as String? ?? '',
    isAttachedFn: j['isAttachedFn'] as String? ?? 'IsAttached',
    attachFn: j['attachFn'] as String? ?? 'Attach',
    executeFn: j['executeFn'] as String? ?? 'Execute',
    settingsFn: j['settingsFn'] as String? ?? 'SetSettings',
    customDllPath: j['customDllPath'] as String?,
    exePath: j['exePath'] as String?,
    injectArgs: j['injectArgs'] as String? ?? '',
    executeArgsTemplate: j['executeArgsTemplate'] as String? ?? '{script_path}',
    autoexecDir: j['autoexecDir'] as String?,
  );
}

const List<DllBackend> builtInBackends = [
  DllBackend(name: 'Xeno (DLL)', mode: BackendMode.xeno, dllFileName: 'Xeno.dll'),
  DllBackend(
    name: 'Custom DLL',
    dllFileName: '',
    isAttachedFn: 'IsAttached',
    attachFn: 'Attach',
    executeFn: 'Execute',
    settingsFn: '',
  ),
  DllBackend(name: 'Custom EXE', mode: BackendMode.process, executeArgsTemplate: '{script_path}'),
  DllBackend(name: 'Cloudy (DLL)', mode: BackendMode.cloudy, dllFileName: 'Cloudy.dll'),
  DllBackend(name: 'Cloudy (Pipe)', mode: BackendMode.cloudyPipe),
];

// ---------------------------------------------------------------------------
// Cloudy dependency DLLs (must be loaded before Cloudy.dll)
// ---------------------------------------------------------------------------

const _cloudyDeps = ['libcrypto-3-x64.dll', 'libssl-3-x64.dll', 'xxhash.dll', 'zstd.dll'];
const _cloudyPipeName = r'\\.\pipe\CLDYexecution';

const _xenoDeps = ['libcurl.dll', 'libcrypto-3-x64.dll', 'libssl-3-x64.dll', 'xxhash.dll', 'zstd.dll', 'zlib1.dll'];

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

enum ExecutorStatus { unloaded, ready, attaching, attached, error }

class DllDiagnostic {
  const DllDiagnostic({required this.label, required this.passed, this.detail});
  final String label;
  final bool passed;
  final String? detail;
}

class _CloudyClient {
  _CloudyClient({required this.version, required this.name, required this.id});
  final String version;
  final String name;
  final int id;
}

class ExecutorState {
  const ExecutorState({
    this.status = ExecutorStatus.unloaded,
    this.error,
    this.output = const [],
    this.lastScript = '',
    this.activeBackend = const DllBackend(name: 'Xeno (DLL)', mode: BackendMode.xeno, dllFileName: 'Xeno.dll'),
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

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

class ExecutorController extends Notifier<ExecutorState> {
  DynamicLibrary? _lib;
  _IntDart? _isAttached;
  _VoidDart? _attach;
  _PtrVoidDart? _execute;
  _PtrVoidDart? _setSettings;

  // Cloudy-specific bindings
  _VoidDart? _cloudyInit;
  _PtrRetDart? _cloudyGetClients;
  _CloudyExecDart? _cloudyExec;

  // Xeno-specific bindings
  _VoidDart? _xenoInit;
  _VoidDart? _xenoAttachFn;
  _XenoExecDart? _xenoExec;
  _PtrRetDart? _xenoGetClients;
  _TwoPtrVoidDart? _xenoSetSetting;
  _StrRetDart? _xenoVersion;

  // kernel32 for named-pipe I/O
  DynamicLibrary? _kernel32;

  @override
  ExecutorState build() => const ExecutorState();

  void setBackend(DllBackend backend) {
    unloadDll();
    state = state.copyWith(activeBackend: backend, status: ExecutorStatus.unloaded);
    addOutput('[*] Backend switched to: ${backend.name} (${backend.mode.name} mode)');
  }

  // ---------------------------------------------------------------------------
  // DLL candidate search
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // PE / file diagnostics
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // Load — dispatches by mode
  // ---------------------------------------------------------------------------

  bool loadDll() {
    return switch (state.activeBackend.mode) {
      BackendMode.dll => _loadDllBackend(),
      BackendMode.process => _loadProcess(),
      BackendMode.cloudy => _loadCloudy(),
      BackendMode.cloudyPipe => _loadCloudyPipe(),
      BackendMode.xeno => _loadXeno(),
    };
  }

  bool _loadProcess() {
    final backend = state.activeBackend;
    final diagnostics = <DllDiagnostic>[];

    if (backend.exePath != null && backend.exePath!.isNotEmpty) {
      final file = File(backend.exePath!);
      diagnostics.add(
        DllDiagnostic(
          label: 'Injector EXE',
          passed: file.existsSync(),
          detail: file.existsSync()
              ? '${backend.exePath} (${(file.statSync().size / 1024).toStringAsFixed(1)} KB)'
              : 'Not found: ${backend.exePath}',
        ),
      );
    } else {
      diagnostics.add(
        const DllDiagnostic(
          label: 'Injector EXE',
          passed: true,
          detail: 'Not configured — injection handled externally',
        ),
      );
    }

    if (backend.autoexecDir != null && backend.autoexecDir!.isNotEmpty) {
      final dir = Directory(backend.autoexecDir!);
      diagnostics.add(
        DllDiagnostic(
          label: 'Autoexec folder',
          passed: dir.existsSync(),
          detail: dir.existsSync() ? backend.autoexecDir! : 'Not found: ${backend.autoexecDir}',
        ),
      );
    }

    for (final d in diagnostics) {
      final icon = d.passed ? '[+]' : '[!]';
      addOutput('$icon ${d.label}: ${d.detail ?? (d.passed ? "OK" : "FAIL")}');
    }

    state = state.copyWith(status: ExecutorStatus.ready, diagnostics: diagnostics, loadedDllPath: backend.exePath);

    addOutput('[+] Process backend "${backend.name}" ready');
    return true;
  }

  // ---------------------------------------------------------------------------
  // Load — Cloudy DLL (External API)
  // ---------------------------------------------------------------------------

  bool _loadCloudy() {
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
        error: 'No Cloudy.dll path configured. Open Settings to pick the DLL path.',
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
      addOutput('[!] Cloudy.dll not found. Searched:\n$searched');
      final diagnostics = _diagnose(candidates.first);
      state = state.copyWith(
        status: ExecutorStatus.error,
        error: 'Cloudy.dll not found. Place it in the bin\\ subfolder or set a custom path in Settings.',
        diagnostics: diagnostics,
      );
      return false;
    }

    addOutput('[*] Found Cloudy.dll at: $foundPath');
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

    // Preload dependency DLLs from the same directory
    final dllDir = File(foundPath).parent.path;
    final sep = Platform.pathSeparator;
    for (final dep in _cloudyDeps) {
      final depPath = '$dllDir$sep$dep';
      if (File(depPath).existsSync()) {
        try {
          DynamicLibrary.open(depPath);
          addOutput('[+] Loaded dependency: $dep');
        } catch (e) {
          addOutput('[*] Could not preload $dep: $e (may already be loaded)');
        }
      } else {
        addOutput('[*] Dependency not found: $depPath (may cause load failure)');
      }
    }

    try {
      _lib = DynamicLibrary.open(foundPath);
      addOutput('[+] Cloudy.dll opened successfully');
    } on ArgumentError catch (e) {
      final msg = e.message.toString();
      String hint;
      if (msg.contains('126') || msg.contains('module could not be found')) {
        hint = 'Missing dependencies — ensure libcrypto, libssl, xxhash, and zstd DLLs are in the same folder';
      } else if (msg.contains('193') || msg.contains('not a valid Win32 application')) {
        hint = 'Architecture mismatch — Cloudy.dll must be 64-bit for this app';
      } else if (msg.contains('5') || msg.contains('Access is denied')) {
        hint = 'Access denied — antivirus may be blocking Cloudy.dll';
      } else {
        hint = 'OS error: $msg';
      }
      state = state.copyWith(
        status: ExecutorStatus.error,
        error: 'Cloudy.dll load failed: $hint',
        diagnostics: diagnostics,
        loadedDllPath: foundPath,
      );
      addOutput('[!] Load failed: $hint');
      return false;
    } catch (e) {
      state = state.copyWith(
        status: ExecutorStatus.error,
        error: 'Cloudy.dll load failed: $e',
        diagnostics: diagnostics,
        loadedDllPath: foundPath,
      );
      addOutput('[!] Load failed: $e');
      return false;
    }

    // Bind Cloudy API functions
    final bound = <String>[];

    _cloudyInit = _bindVoid('Initialize');
    if (_cloudyInit != null) bound.add('Initialize');

    try {
      _cloudyGetClients = _lib!.lookupFunction<_PtrRetNative, _PtrRetDart>('GetClients');
      bound.add('GetClients');
    } catch (_) {
      addOutput('[!] Function "GetClients" not found in Cloudy.dll');
    }

    try {
      _cloudyExec = _lib!.lookupFunction<_CloudyExecNative, _CloudyExecDart>('ExecuteAsync');
      bound.add('ExecuteAsync');
    } catch (_) {
      addOutput('[!] Function "ExecuteAsync" not found in Cloudy.dll');
    }

    if (_cloudyInit == null || _cloudyExec == null) {
      state = state.copyWith(
        status: ExecutorStatus.error,
        error: 'Missing Cloudy API exports — need Initialize and ExecuteAsync at minimum.',
        loadedDllPath: foundPath,
        boundFunctions: bound,
      );
      return false;
    }

    addOutput('[+] Bound ${bound.length} Cloudy functions: ${bound.join(", ")}');
    state = state.copyWith(status: ExecutorStatus.ready, loadedDllPath: foundPath, boundFunctions: bound);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Load — Cloudy Pipe (Internal API)
  // ---------------------------------------------------------------------------

  bool _loadCloudyPipe() {
    if (!Platform.isWindows) {
      state = state.copyWith(status: ExecutorStatus.error, error: 'Windows only');
      return false;
    }

    final backend = state.activeBackend;
    final diagnostics = <DllDiagnostic>[];

    // Load kernel32 for pipe operations
    try {
      _kernel32 ??= DynamicLibrary.open('kernel32.dll');
      diagnostics.add(const DllDiagnostic(label: 'kernel32.dll', passed: true, detail: 'Loaded'));
    } catch (e) {
      state = state.copyWith(status: ExecutorStatus.error, error: 'Failed to load kernel32.dll: $e');
      return false;
    }

    // Check Injector.exe
    if (backend.exePath != null && backend.exePath!.isNotEmpty) {
      final file = File(backend.exePath!);
      diagnostics.add(
        DllDiagnostic(
          label: 'Injector.exe',
          passed: file.existsSync(),
          detail: file.existsSync()
              ? '${backend.exePath} (${(file.statSync().size / 1024).toStringAsFixed(1)} KB)'
              : 'Not found: ${backend.exePath}',
        ),
      );
    } else {
      diagnostics.add(
        const DllDiagnostic(
          label: 'Injector.exe',
          passed: true,
          detail: 'Not configured — inject externally, then use pipe for execution',
        ),
      );
    }

    diagnostics.add(const DllDiagnostic(label: 'Named pipe', passed: true, detail: 'CLDYexecution'));

    for (final d in diagnostics) {
      final icon = d.passed ? '[+]' : '[!]';
      addOutput('$icon ${d.label}: ${d.detail ?? (d.passed ? "OK" : "FAIL")}');
    }

    state = state.copyWith(status: ExecutorStatus.ready, diagnostics: diagnostics, loadedDllPath: backend.exePath);
    addOutput('[+] Cloudy Pipe backend ready');
    return true;
  }

  // ---------------------------------------------------------------------------
  // Load — Xeno DLL
  // ---------------------------------------------------------------------------

  bool _loadXeno() {
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
        error: 'No Xeno.dll path configured. Open Settings to pick the DLL path.',
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
      addOutput('[!] Xeno.dll not found. Searched:\n$searched');
      final diagnostics = _diagnose(candidates.first);
      state = state.copyWith(
        status: ExecutorStatus.error,
        error: 'Xeno.dll not found. Place it next to the app or set a custom path in Settings.',
        diagnostics: diagnostics,
      );
      return false;
    }

    addOutput('[*] Found Xeno.dll at: $foundPath');
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

    // Preload dependency DLLs from the same directory
    final dllDir = File(foundPath).parent.path;
    final sep = Platform.pathSeparator;
    for (final dep in _xenoDeps) {
      final depPath = '$dllDir$sep$dep';
      if (File(depPath).existsSync()) {
        try {
          DynamicLibrary.open(depPath);
          addOutput('[+] Loaded dependency: $dep');
        } catch (e) {
          addOutput('[*] Could not preload $dep: $e (may already be loaded)');
        }
      } else {
        addOutput('[*] Dependency not found: $depPath (may cause load failure)');
      }
    }

    try {
      _lib = DynamicLibrary.open(foundPath);
      addOutput('[+] Xeno.dll opened successfully');
    } on ArgumentError catch (e) {
      final msg = e.message.toString();
      String hint;
      if (msg.contains('126') || msg.contains('module could not be found')) {
        hint =
            'Missing dependencies — ensure libcurl, libssl, libcrypto, '
            'xxhash, zstd, zlib1 DLLs are in the same folder';
      } else if (msg.contains('193') || msg.contains('not a valid Win32 application')) {
        hint = 'Architecture mismatch — Xeno.dll must be 64-bit for this app';
      } else if (msg.contains('5') || msg.contains('Access is denied')) {
        hint = 'Access denied — antivirus may be blocking Xeno.dll';
      } else {
        hint = 'OS error: $msg';
      }
      state = state.copyWith(
        status: ExecutorStatus.error,
        error: 'Xeno.dll load failed: $hint',
        diagnostics: diagnostics,
        loadedDllPath: foundPath,
      );
      addOutput('[!] Load failed: $hint');
      return false;
    } catch (e) {
      state = state.copyWith(
        status: ExecutorStatus.error,
        error: 'Xeno.dll load failed: $e',
        diagnostics: diagnostics,
        loadedDllPath: foundPath,
      );
      addOutput('[!] Load failed: $e');
      return false;
    }

    // Bind Xeno API functions
    final bound = <String>[];

    _xenoInit = _bindVoid('Initialize');
    if (_xenoInit != null) bound.add('Initialize');

    _xenoAttachFn = _bindVoid('Attach');
    if (_xenoAttachFn != null) bound.add('Attach');

    try {
      _xenoExec = _lib!.lookupFunction<_XenoExecNative, _XenoExecDart>('Execute');
      bound.add('Execute');
    } catch (_) {
      _xenoExec = null;
      addOutput('[!] Function "Execute" not found in Xeno.dll');
    }

    try {
      _xenoGetClients = _lib!.lookupFunction<_PtrRetNative, _PtrRetDart>('GetClients');
      bound.add('GetClients');
    } catch (_) {
      addOutput('[!] Function "GetClients" not found in Xeno.dll');
    }

    try {
      _xenoSetSetting = _lib!.lookupFunction<_TwoPtrVoidNative, _TwoPtrVoidDart>('SetSetting');
      bound.add('SetSetting');
    } catch (_) {
      addOutput('[!] Function "SetSetting" not found in Xeno.dll');
    }

    try {
      _xenoVersion = _lib!.lookupFunction<_StrRetNative, _StrRetDart>('Version');
      bound.add('Version');
    } catch (_) {
      addOutput('[!] Function "Version" not found in Xeno.dll');
    }

    if (_xenoExec == null) {
      state = state.copyWith(
        status: ExecutorStatus.error,
        error: 'Missing Xeno API exports — need Execute at minimum.',
        loadedDllPath: foundPath,
        boundFunctions: bound,
      );
      return false;
    }

    // Try to get version info
    if (_xenoVersion != null) {
      try {
        final vPtr = _xenoVersion!();
        if (vPtr.address != 0) {
          final version = _readCString(vPtr);
          if (version.isNotEmpty) addOutput('[+] Xeno API version: $version');
        }
      } catch (e) {
        addOutput('[*] Version() call failed: $e');
      }
    }

    addOutput('[+] Bound ${bound.length} Xeno functions: ${bound.join(", ")}');
    state = state.copyWith(status: ExecutorStatus.ready, loadedDllPath: foundPath, boundFunctions: bound);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Load — standard DLL
  // ---------------------------------------------------------------------------

  bool _loadDllBackend() {
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

  // ---------------------------------------------------------------------------
  // FFI binding helpers
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // Unload
  // ---------------------------------------------------------------------------

  void unloadDll() {
    _lib = null;
    _isAttached = null;
    _attach = null;
    _execute = null;
    _setSettings = null;
    _cloudyInit = null;
    _cloudyGetClients = null;
    _cloudyExec = null;
    _xenoInit = null;
    _xenoAttachFn = null;
    _xenoExec = null;
    _xenoGetClients = null;
    _xenoSetSetting = null;
    _xenoVersion = null;
    state = state.copyWith(status: ExecutorStatus.unloaded, loadedDllPath: null, boundFunctions: [], diagnostics: []);
  }

  // ---------------------------------------------------------------------------
  // Test bindings
  // ---------------------------------------------------------------------------

  Map<String, bool> testBindings() {
    return switch (state.activeBackend.mode) {
      BackendMode.process => _testProcessBindings(),
      BackendMode.cloudy => _testCloudyBindings(),
      BackendMode.cloudyPipe => _testCloudyPipeBindings(),
      BackendMode.xeno => _testXenoBindings(),
      BackendMode.dll => _testDllBindings(),
    };
  }

  Map<String, bool> _testDllBindings() {
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

  Map<String, bool> _testProcessBindings() {
    final backend = state.activeBackend;
    final results = <String, bool>{};

    if (backend.exePath != null && backend.exePath!.isNotEmpty) {
      results['Injector EXE exists'] = File(backend.exePath!).existsSync();
    }

    if (backend.autoexecDir != null && backend.autoexecDir!.isNotEmpty) {
      results['Autoexec folder exists'] = Directory(backend.autoexecDir!).existsSync();
    }

    results['Temp folder writable'] = Directory.systemTemp.existsSync();

    return results;
  }

  Map<String, bool> _testCloudyBindings() {
    final results = <String, bool>{};

    if (_lib == null) {
      results['Initialize'] = false;
      results['GetClients'] = false;
      results['ExecuteAsync'] = false;
      return results;
    }

    results['Initialize'] = _cloudyInit != null;
    results['GetClients'] = _cloudyGetClients != null;
    results['ExecuteAsync'] = _cloudyExec != null;

    return results;
  }

  Map<String, bool> _testCloudyPipeBindings() {
    final backend = state.activeBackend;
    final results = <String, bool>{};

    results['kernel32.dll'] = _kernel32 != null;

    if (backend.exePath != null && backend.exePath!.isNotEmpty) {
      results['Injector.exe exists'] = File(backend.exePath!).existsSync();
    }

    results['Temp folder writable'] = Directory.systemTemp.existsSync();

    return results;
  }

  Map<String, bool> _testXenoBindings() {
    final results = <String, bool>{};

    if (_lib == null) {
      for (final fn in ['Initialize', 'Attach', 'Execute', 'GetClients', 'SetSetting', 'Version']) {
        results[fn] = false;
      }
      return results;
    }

    results['Initialize'] = _xenoInit != null;
    results['Attach'] = _xenoAttachFn != null;
    results['Execute'] = _xenoExec != null;
    results['GetClients'] = _xenoGetClients != null;
    results['SetSetting'] = _xenoSetSetting != null;
    results['Version'] = _xenoVersion != null;

    return results;
  }

  // ---------------------------------------------------------------------------
  // Attach — dispatches by mode
  // ---------------------------------------------------------------------------

  bool get isAttached {
    if (state.activeBackend.mode == BackendMode.cloudy) {
      if (_cloudyGetClients == null) return false;
      try {
        return _getCloudyClients().isNotEmpty;
      } catch (_) {
        return false;
      }
    }
    if (state.activeBackend.mode == BackendMode.xeno) {
      return state.status == ExecutorStatus.attached;
    }
    if (_isAttached == null) return false;
    try {
      return _isAttached!() != 0;
    } catch (_) {
      return false;
    }
  }

  void attach() {
    switch (state.activeBackend.mode) {
      case BackendMode.dll:
        _dllAttach();
      case BackendMode.process:
        _processAttach();
      case BackendMode.cloudy:
        _cloudyAttach();
      case BackendMode.cloudyPipe:
        _cloudyPipeAttach();
      case BackendMode.xeno:
        _xenoAttach();
    }
  }

  void _processAttach() {
    final backend = state.activeBackend;

    if (backend.exePath == null || backend.exePath!.isEmpty) {
      state = state.copyWith(status: ExecutorStatus.attached);
      addOutput('[+] Process mode — no injector EXE configured');
      addOutput('[*] Assuming injection is handled externally');
      return;
    }

    if (!File(backend.exePath!).existsSync()) {
      state = state.copyWith(status: ExecutorStatus.error, error: 'Injector EXE not found: ${backend.exePath}');
      addOutput('[!] EXE not found: ${backend.exePath}');
      return;
    }

    state = state.copyWith(status: ExecutorStatus.attaching);
    addOutput('[*] Launching injector: ${backend.exePath}');

    final args = backend.injectArgs.trim().isEmpty ? <String>[] : backend.injectArgs.trim().split(RegExp(r'\s+'));

    Process.run(backend.exePath!, args)
        .timeout(const Duration(seconds: 30))
        .then((result) {
          final stdout = result.stdout.toString().trim();
          final stderr = result.stderr.toString().trim();
          if (stdout.isNotEmpty) addOutput('[*] $stdout');
          if (stderr.isNotEmpty) addOutput('[!] $stderr');
          state = state.copyWith(status: ExecutorStatus.attached);
          addOutput('[+] Injector finished (exit: ${result.exitCode})');
        })
        .catchError((Object e) {
          state = state.copyWith(status: ExecutorStatus.error, error: 'Injector failed: $e');
          addOutput('[!] Injector failed: $e');
        });
  }

  void _dllAttach() {
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

  // ---------------------------------------------------------------------------
  // Attach — Cloudy DLL (calls Initialize, waits, checks clients)
  // ---------------------------------------------------------------------------

  void _cloudyAttach() {
    if (_cloudyInit == null) {
      addOutput('[!] Cloudy.dll not loaded — no Initialize function');
      return;
    }

    state = state.copyWith(status: ExecutorStatus.attaching);
    addOutput('[*] Calling Cloudy Initialize()...');

    try {
      _cloudyInit!();
    } catch (e) {
      state = state.copyWith(status: ExecutorStatus.error, error: 'Initialize() failed: $e');
      addOutput('[!] Initialize() failed: $e');
      return;
    }

    addOutput('[*] Waiting for injection (2s)...');
    Future.delayed(const Duration(seconds: 2)).then((_) {
      if (_cloudyGetClients == null) {
        state = state.copyWith(status: ExecutorStatus.attached);
        addOutput('[+] Cloudy initialized (no GetClients to verify — assuming attached)');
        return;
      }

      try {
        final clients = _getCloudyClients();
        if (clients.isEmpty) {
          state = state.copyWith(status: ExecutorStatus.error, error: 'No Roblox clients detected. Is Roblox running?');
          addOutput('[!] No Roblox clients found after Initialize()');
          addOutput('[*] Make sure Roblox is running and you are in a game');
          return;
        }

        addOutput('[+] Found ${clients.length} client(s):');
        for (final c in clients) {
          addOutput('[+]   ${c.name} (v${c.version}, id=${c.id})');
        }

        state = state.copyWith(status: ExecutorStatus.attached);
        addOutput('[+] Cloudy API attached!');
      } catch (e) {
        state = state.copyWith(status: ExecutorStatus.error, error: 'GetClients() failed: $e');
        addOutput('[!] GetClients() failed: $e');
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Attach — Cloudy Pipe (launches Injector.exe)
  // ---------------------------------------------------------------------------

  void _cloudyPipeAttach() {
    final backend = state.activeBackend;

    if (backend.exePath == null || backend.exePath!.isEmpty) {
      state = state.copyWith(status: ExecutorStatus.attached);
      addOutput('[+] Cloudy Pipe mode — no Injector.exe configured');
      addOutput('[*] Assuming injection is handled externally');
      addOutput('[*] Will use named pipe "$_cloudyPipeName" for execution');
      return;
    }

    if (!File(backend.exePath!).existsSync()) {
      state = state.copyWith(status: ExecutorStatus.error, error: 'Injector.exe not found: ${backend.exePath}');
      addOutput('[!] Injector.exe not found: ${backend.exePath}');
      return;
    }

    state = state.copyWith(status: ExecutorStatus.attaching);
    addOutput('[*] Launching Cloudy Injector: ${backend.exePath}');

    Process.run(backend.exePath!, [])
        .timeout(const Duration(seconds: 30))
        .then((result) {
          final stdout = result.stdout.toString().trim();
          final stderr = result.stderr.toString().trim();
          if (stdout.isNotEmpty) addOutput('[*] $stdout');
          if (stderr.isNotEmpty) addOutput('[!] $stderr');
          state = state.copyWith(status: ExecutorStatus.attached);
          addOutput('[+] Injector finished (exit: ${result.exitCode})');
          addOutput('[*] Using named pipe "$_cloudyPipeName" for execution');
        })
        .catchError((Object e) {
          state = state.copyWith(status: ExecutorStatus.error, error: 'Injector failed: $e');
          addOutput('[!] Injector failed: $e');
        });
  }

  // ---------------------------------------------------------------------------
  // Attach — Xeno DLL (calls Initialize, then Attach, checks clients)
  // ---------------------------------------------------------------------------

  void _xenoAttach() {
    if (_xenoInit == null && _xenoAttachFn == null) {
      addOutput('[!] Xeno.dll not loaded');
      return;
    }

    state = state.copyWith(status: ExecutorStatus.attaching);

    if (_xenoInit != null) {
      addOutput('[*] Calling Xeno Initialize()...');
      try {
        _xenoInit!();
      } catch (e) {
        state = state.copyWith(status: ExecutorStatus.error, error: 'Initialize() failed: $e');
        addOutput('[!] Initialize() failed: $e');
        return;
      }
    }

    if (_xenoAttachFn != null) {
      addOutput('[*] Calling Xeno Attach()...');
      try {
        _xenoAttachFn!();
      } catch (e) {
        state = state.copyWith(status: ExecutorStatus.error, error: 'Attach() failed: $e');
        addOutput('[!] Attach() failed: $e');
        return;
      }
    }

    addOutput('[*] Waiting for injection...');
    _pollXenoClients(0);
  }

  void _pollXenoClients(int attempt) {
    const maxAttempts = 6;
    const delayMs = 2000;

    Future.delayed(const Duration(milliseconds: delayMs)).then((_) {
      if (state.status != ExecutorStatus.attaching) return;

      bool hasClient = false;
      if (_xenoGetClients != null) {
        try {
          final ptr = _xenoGetClients!();
          if (ptr.address != 0) {
            final asStr = _readCString(Pointer<Uint8>.fromAddress(ptr.address));
            if (asStr.isNotEmpty) {
              addOutput('[+] Clients: $asStr');
              hasClient = true;
            }
          }
        } catch (e) {
          addOutput('[*] GetClients(): $e');
        }
      }

      if (hasClient || attempt >= maxAttempts - 1) {
        state = state.copyWith(status: ExecutorStatus.attached);
        if (hasClient) {
          addOutput('[+] Xeno API attached — client found!');
        } else {
          addOutput('[+] Xeno API attached (no client confirmed — try executing anyway)');
        }
        if (_xenoVersion != null) {
          try {
            final vPtr = _xenoVersion!();
            if (vPtr.address != 0) {
              addOutput('[*] Xeno version: ${_readCString(vPtr)}');
            }
          } catch (_) {}
        }
      } else {
        addOutput('[*] Polling for clients (${attempt + 1}/$maxAttempts)...');
        _pollXenoClients(attempt + 1);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Execute — dispatches by mode
  // ---------------------------------------------------------------------------

  void execute(String script) {
    switch (state.activeBackend.mode) {
      case BackendMode.dll:
        _dllExecute(script);
      case BackendMode.process:
        _processExecute(script);
      case BackendMode.cloudy:
        _cloudyExecute(script);
      case BackendMode.cloudyPipe:
        _cloudyPipeExecute(script);
      case BackendMode.xeno:
        _xenoExecute(script);
    }
  }

  void _processExecute(String script) {
    if (state.status != ExecutorStatus.attached) {
      addOutput('[!] Not attached. Click Attach first.');
      return;
    }

    state = state.copyWith(lastScript: script);
    addOutput('[>] Executing script (${script.length} chars)...');

    final backend = state.activeBackend;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fileName = 'j3_exec_$timestamp.lua';

    String scriptPath;
    if (backend.autoexecDir != null && backend.autoexecDir!.isNotEmpty) {
      final dir = Directory(backend.autoexecDir!);
      if (!dir.existsSync()) {
        try {
          dir.createSync(recursive: true);
        } catch (e) {
          addOutput('[!] Cannot create autoexec folder: $e');
          return;
        }
      }
      scriptPath = '${backend.autoexecDir}${Platform.pathSeparator}$fileName';
    } else {
      scriptPath = '${Directory.systemTemp.path}${Platform.pathSeparator}$fileName';
    }

    try {
      File(scriptPath).writeAsStringSync(script);
    } catch (e) {
      addOutput('[!] Failed to write script file: $e');
      return;
    }

    if (backend.autoexecDir != null && backend.autoexecDir!.isNotEmpty) {
      addOutput('[+] Script written to autoexec: $scriptPath');
      addOutput('[*] Your executor will pick it up automatically');
      return;
    }

    if (backend.exePath != null && backend.exePath!.isNotEmpty) {
      final argsStr = backend.executeArgsTemplate.replaceAll('{script_path}', scriptPath);
      final args = argsStr.trim().isEmpty ? <String>[] : argsStr.trim().split(RegExp(r'\s+'));

      addOutput('[*] Launching: ${backend.exePath} ${args.join(' ')}');

      Process.run(backend.exePath!, args)
          .timeout(const Duration(seconds: 30))
          .then((result) {
            final stdout = result.stdout.toString().trim();
            final stderr = result.stderr.toString().trim();
            if (stdout.isNotEmpty) addOutput('[+] $stdout');
            if (stderr.isNotEmpty) addOutput('[!] $stderr');
            addOutput('[+] Script executed (exit: ${result.exitCode})');
          })
          .catchError((Object e) {
            addOutput('[!] Execute failed: $e');
          });
    } else {
      addOutput('[+] Script saved to: $scriptPath');
      addOutput('[*] No EXE configured — load the file in your executor manually');
    }
  }

  void _dllExecute(String script) {
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

  // ---------------------------------------------------------------------------
  // Execute — Cloudy DLL (gets clients, calls ExecuteAsync)
  // ---------------------------------------------------------------------------

  void _cloudyExecute(String script) {
    if (_cloudyExec == null) {
      addOutput('[!] Cloudy.dll not loaded — no ExecuteAsync function');
      return;
    }
    if (state.status != ExecutorStatus.attached) {
      addOutput('[!] Not attached. Click Attach first.');
      return;
    }

    state = state.copyWith(lastScript: script);
    addOutput('[>] Executing via Cloudy API (${script.length} chars)...');

    // Get client list
    List<_CloudyClient> clients;
    try {
      clients = _cloudyGetClients != null ? _getCloudyClients() : [];
    } catch (e) {
      addOutput('[!] GetClients() failed: $e — executing without client filter');
      clients = [];
    }

    if (clients.isEmpty && _cloudyGetClients != null) {
      addOutput('[!] No clients connected. Is Roblox running?');
      return;
    }

    final clientNames = clients.map((c) => c.name).toList();
    if (clientNames.isNotEmpty) {
      addOutput('[*] Targeting ${clientNames.length} client(s): ${clientNames.join(", ")}');
    }

    // Build native args
    final scriptPtr = _toNativeUtf8(script);
    Pointer<Pointer<Uint8>>? namesPtr;

    try {
      if (clientNames.isNotEmpty) {
        namesPtr = _toNativeStringArray(clientNames);
        _cloudyExec!(scriptPtr, namesPtr, clientNames.length);
      } else {
        // No clients known — pass empty array
        namesPtr = _toNativeStringArray(['']);
        _cloudyExec!(scriptPtr, namesPtr, 1);
      }
      addOutput('[+] Script sent via Cloudy ExecuteAsync');
    } catch (e) {
      addOutput('[!] ExecuteAsync failed: $e');
    } finally {
      _freeNativeUtf8(scriptPtr);
      if (namesPtr != null) {
        _freeNativeStringArray(namesPtr, clientNames.isEmpty ? 1 : clientNames.length);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Execute — Cloudy Pipe (writes script to named pipe)
  // ---------------------------------------------------------------------------

  void _cloudyPipeExecute(String script) {
    if (_kernel32 == null) {
      addOutput('[!] kernel32.dll not loaded — call Load first');
      return;
    }
    if (state.status != ExecutorStatus.attached) {
      addOutput('[!] Not attached. Click Attach first.');
      return;
    }

    state = state.copyWith(lastScript: script);
    addOutput('[>] Executing via Cloudy pipe (${script.length} chars)...');

    final k32 = _kernel32!;
    final createFile = k32.lookupFunction<_CreateFileWN, _CreateFileWD>('CreateFileW');
    final writeFile = k32.lookupFunction<_RwFileN, _RwFileD>('WriteFile');
    final readFile = k32.lookupFunction<_RwFileN, _RwFileD>('ReadFile');
    final closeHandle = k32.lookupFunction<_CloseHandleN, _CloseHandleD>('CloseHandle');
    final waitPipe = k32.lookupFunction<_WaitPipeN, _WaitPipeD>('WaitNamedPipeW');

    final pipePath = _toNativeUtf16(_cloudyPipeName);
    final malloc = _stdlib.lookupFunction<_MallocNative, _MallocDart>('malloc');
    final free = _stdlib.lookupFunction<_FreeNative, _FreeDart>('free');

    try {
      // Wait for pipe to become available
      final waited = waitPipe(pipePath, 5000);
      if (waited == 0) {
        addOutput('[!] Pipe not available — is Cloudy injected?');
        addOutput('[*] Make sure you attached first and Roblox is running');
        return;
      }

      // Open the pipe: GENERIC_READ | GENERIC_WRITE, OPEN_EXISTING
      final handle = createFile(pipePath, 0xC0000000, 0, Pointer<Void>.fromAddress(0), 3, 0, 0);

      if (handle == -1) {
        addOutput('[!] Failed to open pipe — access denied or pipe busy');
        return;
      }

      try {
        // Write script bytes
        final scriptBytes = utf8.encode(script);
        final writeBuf = malloc(scriptBytes.length);
        final writeList = writeBuf.asTypedList(scriptBytes.length);
        writeList.setAll(0, scriptBytes);

        final bytesWrittenPtr = malloc(4).cast<Uint32>();
        final writeOk = writeFile(handle, writeBuf, scriptBytes.length, bytesWrittenPtr, Pointer<Void>.fromAddress(0));

        final bytesWritten = bytesWrittenPtr.value;
        free(bytesWrittenPtr.cast<Uint8>());
        free(writeBuf);

        if (writeOk == 0) {
          addOutput('[!] WriteFile failed');
          return;
        }

        addOutput('[+] Wrote $bytesWritten bytes to pipe');

        // Read response
        final readBuf = malloc(4096);
        final bytesReadPtr = malloc(4).cast<Uint32>();
        final readOk = readFile(handle, readBuf, 4096, bytesReadPtr, Pointer<Void>.fromAddress(0));

        if (readOk != 0 && bytesReadPtr.value > 0) {
          final response = utf8.decode(readBuf.asTypedList(bytesReadPtr.value), allowMalformed: true);
          addOutput('[+] Response: $response');
        }

        free(bytesReadPtr.cast<Uint8>());
        free(readBuf);

        addOutput('[+] Script executed via Cloudy pipe');
      } finally {
        closeHandle(handle);
      }
    } finally {
      _freeNativeUtf8(pipePath.cast<Uint8>());
    }
  }

  // ---------------------------------------------------------------------------
  // Execute — Xeno DLL (calls Execute with script)
  // ---------------------------------------------------------------------------

  void _xenoExecute(String script) {
    if (_xenoExec == null) {
      addOutput('[!] Xeno.dll not loaded — no Execute function');
      return;
    }
    if (state.status != ExecutorStatus.attached) {
      addOutput('[!] Not attached. Click Attach first.');
      return;
    }

    if (_xenoGetClients != null) {
      try {
        final cPtr = _xenoGetClients!();
        if (cPtr.address == 0) {
          addOutput('[!] No Xeno clients — re-attach and try again.');
          return;
        }
      } catch (_) {}
    }

    state = state.copyWith(lastScript: script);
    addOutput('[>] Executing via Xeno API (${script.length} chars)...');

    final ptr = _toNativeUtf8(script);
    try {
      final result = _xenoExec!(ptr);
      addOutput('[+] Script sent to Xeno (result=$result).');
    } catch (e) {
      addOutput('[!] Execute failed: $e');
      _freeNativeUtf8(ptr);
      return;
    }
    // Xeno reads the script buffer asynchronously — keep it alive while
    // the injection pipeline writes it into the target process.
    Future.delayed(const Duration(seconds: 5)).then((_) {
      _freeNativeUtf8(ptr);
    });
  }

  // ---------------------------------------------------------------------------
  // Cloudy client helpers
  // ---------------------------------------------------------------------------

  List<_CloudyClient> _getCloudyClients() {
    if (_cloudyGetClients == null) return [];
    final ptr = _cloudyGetClients!();
    return _parseClients(ptr);
  }

  List<_CloudyClient> _parseClients(Pointer<Void> ptr) {
    if (ptr.address == 0) return [];
    final clients = <_CloudyClient>[];

    // ClientInfo struct layout on x64:
    //   offset  0: char* version  (8 bytes)
    //   offset  8: char* name     (8 bytes)
    //   offset 16: int32 id       (4 bytes)
    //   offset 20: padding        (4 bytes)
    //   total: 24 bytes
    const structSize = 24;

    for (var i = 0; i < 256; i++) {
      final baseAddr = ptr.address + i * structSize;

      // Read name pointer at offset 8 — null signals end of array
      final namePtrAddr = Pointer<IntPtr>.fromAddress(baseAddr + 8).value;
      if (namePtrAddr == 0) break;

      final versionPtrAddr = Pointer<IntPtr>.fromAddress(baseAddr).value;
      final id = Pointer<Int32>.fromAddress(baseAddr + 16).value;

      clients.add(
        _CloudyClient(
          version: _readCString(Pointer<Uint8>.fromAddress(versionPtrAddr)),
          name: _readCString(Pointer<Uint8>.fromAddress(namePtrAddr)),
          id: id,
        ),
      );
    }

    return clients;
  }

  // ---------------------------------------------------------------------------
  // Settings & output
  // ---------------------------------------------------------------------------

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
