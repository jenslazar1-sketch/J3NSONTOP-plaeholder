import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level guarantees for the Developer Tools feature.
void main() {
  List<File> dartFiles(String dir) =>
      Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList();

  test('TLS verification is never disabled anywhere in lib/', () {
    final offenders = [
      for (final f in dartFiles('lib'))
        if (f.readAsStringSync().contains('badCertificateCallback')) f.path,
    ];
    expect(offenders, isEmpty, reason: 'badCertificateCallback must not be used');
  });

  test('dev tools never check Platform.isX directly', () {
    final offenders = [
      for (final f in dartFiles('lib/features/dev_tools'))
        if (RegExp(r'Platform\.is[A-Z]').hasMatch(f.readAsStringSync())) f.path,
    ];
    expect(offenders, isEmpty);
  });

  test('dev tools contain no leftover TODO markers', () {
    final offenders = [
      for (final f in dartFiles('lib/features/dev_tools'))
        if (f.readAsStringSync().contains('TODO')) f.path,
    ];
    expect(offenders, isEmpty);
  });
}
