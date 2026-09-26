import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class FridaProcess {
  const FridaProcess({required this.pid, required this.name, this.identifier});
  final int pid;
  final String name;
  final String? identifier;
}

class FridaDevice {
  const FridaDevice({required this.id, required this.name, required this.type});
  final String id;
  final String name;
  final String type;

  bool get isUsb => type == 'usb';
  bool get isLocal => type == 'local';
  bool get isRemote => type == 'remote';
}

class FridaScriptResult {
  const FridaScriptResult({required this.output, this.error, this.exitCode = 0});
  final String output;
  final String? error;
  final int exitCode;

  bool get success => exitCode == 0;
}

class FridaService {
  FridaService({this.fridaPath = 'frida', this.fridaPsPath = 'frida-ps'});
  final String fridaPath;
  final String fridaPsPath;

  Future<bool> isAvailable() async {
    try {
      final result = await Process.run(fridaPath, ['--version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<String> version() async {
    final result = await Process.run(fridaPath, ['--version']);
    return (result.stdout as String).trim();
  }

  Future<List<FridaDevice>> listDevices() async {
    final result = await Process.run(fridaPath, ['--device', 'enumerate']);
    if (result.exitCode != 0) {
      final psResult = await Process.run(fridaPsPath, ['-D', 'usb']);
      if (psResult.exitCode != 0) {
        throw FridaException('Cannot enumerate devices: ${result.stderr}');
      }
    }
    final lines = (result.stdout as String).split('\n').where((l) => l.trim().isNotEmpty).skip(1);
    return lines.map((l) {
      final parts = l.trim().split(RegExp(r'\s{2,}'));
      if (parts.length < 3) return null;
      return FridaDevice(id: parts[0].trim(), name: parts[1].trim(), type: parts[2].trim());
    }).whereType<FridaDevice>().toList();
  }

  Future<List<FridaProcess>> listProcesses({String? device}) async {
    final args = <String>[if (device != null) ...['-D', device]];
    final result = await Process.run(fridaPsPath, args);
    if (result.exitCode != 0) throw FridaException('frida-ps failed: ${result.stderr}');
    final lines = (result.stdout as String).split('\n').skip(2).where((l) => l.trim().isNotEmpty);
    return lines.map((l) {
      final match = RegExp(r'^\s*(\d+)\s+(.+)$').firstMatch(l);
      if (match == null) return null;
      return FridaProcess(pid: int.parse(match.group(1)!), name: match.group(2)!.trim());
    }).whereType<FridaProcess>().toList();
  }

  Future<List<FridaProcess>> listApps({String? device}) async {
    final args = <String>[if (device != null) ...['-D', device], '-ai'];
    final result = await Process.run(fridaPsPath, args);
    if (result.exitCode != 0) throw FridaException('frida-ps -ai failed: ${result.stderr}');
    final lines = (result.stdout as String).split('\n').skip(2).where((l) => l.trim().isNotEmpty);
    return lines.map((l) {
      final match = RegExp(r'^\s*(\d+)\s+(\S+)\s+(.+)$').firstMatch(l);
      if (match == null) return null;
      return FridaProcess(pid: int.parse(match.group(1)!), name: match.group(3)!.trim(), identifier: match.group(2)!.trim());
    }).whereType<FridaProcess>().toList();
  }

  Stream<String> attach({required int pid, required String script, String? device}) {
    final args = <String>[
      if (device != null) ...['-D', device],
      '-p', '$pid',
      '-l', script,
      '--no-pause',
    ];
    return _runStream(args);
  }

  Stream<String> spawn({required String identifier, required String script, String? device}) {
    final args = <String>[
      if (device != null) ...['-D', device],
      '-f', identifier,
      '-l', script,
      '--no-pause',
    ];
    return _runStream(args);
  }

  Stream<String> attachInline({required int pid, required String jsCode, String? device}) {
    final args = <String>[
      if (device != null) ...['-D', device],
      '-p', '$pid',
      '--codeshare', '',
      '-e', jsCode,
    ];
    return _runStream(args);
  }

  Future<FridaScriptResult> runScript({required String target, required String scriptPath, String? device}) async {
    final args = <String>[
      if (device != null) ...['-D', device],
      '-f', target,
      '-l', scriptPath,
      '--no-pause',
      '-q',
    ];
    final result = await Process.run(fridaPath, args, stdoutEncoding: utf8, stderrEncoding: utf8);
    return FridaScriptResult(
      output: result.stdout as String,
      error: result.stderr as String,
      exitCode: result.exitCode,
    );
  }

  Stream<String> _runStream(List<String> args) {
    final controller = StreamController<String>();
    () async {
      Process? proc;
      try {
        proc = await Process.start(fridaPath, args);
        final combined = StreamGroup.merge([
          proc.stdout.transform(utf8.decoder).transform(const LineSplitter()),
          proc.stderr.transform(utf8.decoder).transform(const LineSplitter()),
        ]);
        await controller.addStream(combined);
      } catch (e) {
        controller.addError(e);
      } finally {
        proc?.kill();
        await controller.close();
      }
    }();
    return controller.stream;
  }
}

class StreamGroup {
  static Stream<T> merge<T>(Iterable<Stream<T>> streams) {
    final controller = StreamController<T>();
    var remaining = 0;
    for (final s in streams) {
      remaining++;
      s.listen(
        controller.add,
        onError: controller.addError,
        onDone: () {
          remaining--;
          if (remaining == 0) controller.close();
        },
      );
    }
    if (remaining == 0) controller.close();
    return controller.stream;
  }
}

class FridaException implements Exception {
  const FridaException(this.message);
  final String message;
  @override
  String toString() => message;
}

final fridaServiceProvider = Provider<FridaService>((ref) => FridaService());
