import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef _IsAttachedNative = Int32 Function();
typedef _IsAttachedDart = int Function();

typedef _AttachNative = Void Function();
typedef _AttachDart = void Function();

typedef _ExecuteNative = Void Function(Pointer<Uint8> script);
typedef _ExecuteDart = void Function(Pointer<Uint8> script);

typedef _SetSettingsNative = Void Function(Pointer<Uint8> settings);
typedef _SetSettingsDart = void Function(Pointer<Uint8> settings);

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

enum ExecutorStatus { unloaded, ready, attaching, attached, error }

class ExecutorState {
  const ExecutorState({
    this.status = ExecutorStatus.unloaded,
    this.error,
    this.output = const [],
    this.lastScript = '',
  });

  final ExecutorStatus status;
  final String? error;
  final List<String> output;
  final String lastScript;

  ExecutorState copyWith({ExecutorStatus? status, String? error, List<String>? output, String? lastScript}) {
    return ExecutorState(
      status: status ?? this.status,
      error: error,
      output: output ?? this.output,
      lastScript: lastScript ?? this.lastScript,
    );
  }
}

class ExecutorController extends Notifier<ExecutorState> {
  DynamicLibrary? _lib;
  _IsAttachedDart? _isAttached;
  _AttachDart? _attach;
  _ExecuteDart? _execute;
  _SetSettingsDart? _setSettings;

  @override
  ExecutorState build() => const ExecutorState();

  String? _findDll() {
    final exe = Platform.resolvedExecutable;
    final dir = File(exe).parent.path;
    final sep = Platform.pathSeparator;
    final candidates = [
      '$dir${sep}wearedevs_exploit_api.dll',
      '$dir${sep}data${sep}wearedevs_exploit_api.dll',
      '$dir${sep}bin${sep}wearedevs_exploit_api.dll',
    ];
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  bool loadDll() {
    if (_lib != null) return true;
    if (!Platform.isWindows) {
      state = state.copyWith(status: ExecutorStatus.error, error: 'Windows only');
      return false;
    }

    final path = _findDll();
    if (path == null) {
      state = state.copyWith(
        status: ExecutorStatus.error,
        error:
            'wearedevs_exploit_api.dll not found. '
            'Place it next to j3nsontop_multitool.exe and restart.',
      );
      return false;
    }

    try {
      _lib = DynamicLibrary.open(path);
      _isAttached = _lib!.lookupFunction<_IsAttachedNative, _IsAttachedDart>('IsAttached');
      _attach = _lib!.lookupFunction<_AttachNative, _AttachDart>('Attach');
      _execute = _lib!.lookupFunction<_ExecuteNative, _ExecuteDart>('Execute');
      _setSettings = _lib!.lookupFunction<_SetSettingsNative, _SetSettingsDart>('SetSettings');
      state = state.copyWith(status: ExecutorStatus.ready);
      addOutput('[+] DLL loaded from: $path');
      return true;
    } catch (e) {
      state = state.copyWith(status: ExecutorStatus.error, error: 'Failed to load DLL: $e');
      return false;
    }
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
    if (_attach == null) {
      addOutput('[!] DLL not loaded');
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
      addOutput('[!] DLL not loaded');
      return;
    }
    if (!isAttached) {
      addOutput('[!] Not attached. Click Attach first.');
      return;
    }

    state = state.copyWith(lastScript: script);
    addOutput('[*] Executing script (${script.length} chars)...');

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
    if (_setSettings == null) return;
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
