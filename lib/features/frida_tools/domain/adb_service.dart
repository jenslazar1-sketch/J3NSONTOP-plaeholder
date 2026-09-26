import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class AdbDevice {
  const AdbDevice({required this.serial, required this.state, this.model, this.product});
  final String serial;
  final String state;
  final String? model;
  final String? product;

  bool get isOnline => state == 'device';
  String get displayName => model ?? product ?? serial;
}

class InstalledPackage {
  const InstalledPackage({required this.packageName, this.path});
  final String packageName;
  final String? path;
}

class AdbLogEntry {
  const AdbLogEntry({required this.timestamp, required this.level, required this.tag, required this.message});
  final String timestamp;
  final String level;
  final String tag;
  final String message;
}

class AdbService {
  AdbService([this._adbPath = 'adb']);
  final String _adbPath;

  Future<String> _run(List<String> args, {String? serial}) async {
    final fullArgs = <String>[if (serial != null) ...['-s', serial], ...args];
    final result = await Process.run(_adbPath, fullArgs);
    if (result.exitCode != 0) {
      throw AdbException('adb ${args.join(' ')} failed (exit ${result.exitCode}): ${result.stderr}');
    }
    return (result.stdout as String).trim();
  }

  Future<bool> isAvailable() async {
    try {
      await _run(['version']);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<AdbDevice>> devices() async {
    final out = await _run(['devices', '-l']);
    final lines = out.split('\n').skip(1).where((l) => l.trim().isNotEmpty);
    return lines.map((l) {
      final parts = l.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) return null;
      final serial = parts[0];
      final state = parts[1];
      String? prop(String key) {
        for (final p in parts.skip(2)) {
          if (p.startsWith('$key:')) return p.substring(key.length + 1);
        }
        return null;
      }
      return AdbDevice(serial: serial, state: state, model: prop('model'), product: prop('product'));
    }).whereType<AdbDevice>().toList();
  }

  Future<List<InstalledPackage>> listPackages(String serial, {bool thirdPartyOnly = true}) async {
    final flag = thirdPartyOnly ? '-3' : '';
    final out = await _run(['shell', 'pm', 'list', 'packages', if (flag.isNotEmpty) flag], serial: serial);
    return out.split('\n').where((l) => l.startsWith('package:')).map((l) {
      return InstalledPackage(packageName: l.substring(8).trim());
    }).toList()
      ..sort((a, b) => a.packageName.compareTo(b.packageName));
  }

  Future<String> getPackagePath(String serial, String pkg) async {
    final out = await _run(['shell', 'pm', 'path', pkg], serial: serial);
    return out.replaceFirst('package:', '').trim();
  }

  Future<void> installApk(String serial, String apkPath) async {
    await _run(['install', '-r', apkPath], serial: serial);
  }

  Future<void> uninstall(String serial, String pkg) async {
    await _run(['uninstall', pkg], serial: serial);
  }

  Future<void> forceStop(String serial, String pkg) async {
    await _run(['shell', 'am', 'force-stop', pkg], serial: serial);
  }

  Future<void> launchApp(String serial, String pkg) async {
    await _run(['shell', 'monkey', '-p', pkg, '-c', 'android.intent.category.LAUNCHER', '1'], serial: serial);
  }

  Future<void> pullFile(String serial, String remotePath, String localPath) async {
    await _run(['pull', remotePath, localPath], serial: serial);
  }

  Future<void> pushFile(String serial, String localPath, String remotePath) async {
    await _run(['push', localPath, remotePath], serial: serial);
  }

  Future<String> shell(String serial, String command) async {
    return await _run(['shell', command], serial: serial);
  }

  Future<String> getDeviceProp(String serial, String prop) async {
    return await _run(['shell', 'getprop', prop], serial: serial);
  }

  Future<Map<String, String>> deviceInfo(String serial) async {
    final props = ['ro.product.model', 'ro.product.brand', 'ro.build.version.release', 'ro.build.version.sdk'];
    final info = <String, String>{};
    for (final p in props) {
      try {
        info[p.split('.').last] = await getDeviceProp(serial, p);
      } catch (_) {}
    }
    return info;
  }

  Stream<String> logcat(String serial, {String? filter}) {
    final args = <String>['-s', serial, 'logcat', '-v', 'time'];
    if (filter != null && filter.isNotEmpty) args.addAll(['-s', filter]);
    final controller = StreamController<String>();

    () async {
      Process? proc;
      try {
        proc = await Process.start(_adbPath, args);
        await controller.addStream(proc.stdout.transform(utf8.decoder).transform(const LineSplitter()));
      } catch (e) {
        controller.addError(e);
      } finally {
        proc?.kill();
        await controller.close();
      }
    }();

    return controller.stream;
  }

  Future<void> clearLogcat(String serial) async {
    await _run(['logcat', '-c'], serial: serial);
  }

  Future<String> screencap(String serial, String localPath) async {
    const remote = '/sdcard/j3_screencap.png';
    await _run(['shell', 'screencap', '-p', remote], serial: serial);
    await _run(['pull', remote, localPath], serial: serial);
    await _run(['shell', 'rm', remote], serial: serial);
    return localPath;
  }

  Future<void> tcpForward(String serial, int localPort, int remotePort) async {
    await _run(['forward', 'tcp:$localPort', 'tcp:$remotePort'], serial: serial);
  }

  Future<void> reverseForward(String serial, int remotePort, int localPort) async {
    await _run(['reverse', 'tcp:$remotePort', 'tcp:$localPort'], serial: serial);
  }
}

class AdbException implements Exception {
  const AdbException(this.message);
  final String message;
  @override
  String toString() => message;
}

final adbServiceProvider = Provider<AdbService>((ref) => AdbService());
