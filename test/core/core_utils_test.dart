import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/app/app_info.dart';
import 'package:j3nsontop_multitool/core/commands/terminal_command.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/core/tasks/isolate_runner.dart';
import 'package:j3nsontop_multitool/core/utils/hashing.dart';
import 'package:j3nsontop_multitool/core/utils/text_codec.dart';
import 'package:path/path.dart' as p;

bool _catastrophic(String input) => RegExp(r'^(a+)+$').hasMatch(input);

int _slowSum() {
  var s = 0;
  for (var i = 0; i < 2000000000; i++) {
    s += i % 7;
  }
  return s;
}

void main() {
  group('Hashing', () {
    test('known SHA-256 vectors', () {
      expect(Hashing.text(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(Hashing.text('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(Hashing.text('abc', HashAlgorithm.md5), '900150983cd24fb0d6963f7d28e17f72');
    });

    test('streamed file hash matches in-memory hash and reports progress', () async {
      final dir = Directory.systemTemp.createTempSync('j3_hash_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bytes = List<int>.generate(3 * 1024 * 1024 + 17, (i) => (i * 31) & 0xFF);
      final f = File(p.join(dir.path, 'big.bin'))..writeAsBytesSync(bytes);
      final progress = <double?>[];
      final h = await Hashing.file(f.path, onProgress: (v, _) => progress.add(v));
      expect(h, Hashing.bytes(bytes));
      expect(progress.last, 1);
    });

    test('file hash honours cancellation', () async {
      final dir = Directory.systemTemp.createTempSync('j3_hashc_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File(p.join(dir.path, 'x.bin'))..writeAsBytesSync(List<int>.filled(1 << 20, 1));
      final token = CancellationToken()..cancel();
      expect(Hashing.file(f.path, token: token), throwsA(isA<OperationCancelled>()));
    });

    test('digestsEqual ignores case, whitespace and algo prefix', () {
      expect(Hashing.digestsEqual('ABCDEF', ' abcdef\n'), isTrue);
      expect(Hashing.digestsEqual('sha256:abcdef', 'ABCDEF'), isTrue);
      expect(Hashing.digestsEqual('abc', 'abd'), isFalse);
      expect(Hashing.digestsEqual('', ''), isFalse);
    });
  });

  group('TextCodec', () {
    test('detects BOMs and decodes UTF-16', () {
      final le = TextCodec.encode('héllo', TextEncodingKind.utf16le);
      final d = TextCodec.decode(le);
      expect(d.text, 'héllo');
      expect(d.encoding, TextEncodingKind.utf16le);
      expect(TextCodec.decode(TextCodec.encode('x', TextEncodingKind.utf8Bom)).encoding, TextEncodingKind.utf8Bom);
    });

    test('invalid UTF-8 falls back to Latin-1 and flags it', () {
      final d = TextCodec.decode([0x63, 0x61, 0x66, 0xE9]); // "café" in Latin-1
      expect(d.text, 'café');
      expect(d.hadMalformedBytes, isTrue);
      expect(d.encoding, TextEncodingKind.latin1);
    });

    test('binary detection', () {
      expect(TextCodec.looksBinary(utf8.encode('plain text\nline 2')), isFalse);
      expect(TextCodec.looksBinary([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]), isTrue);
      expect(TextCodec.looksBinary(TextCodec.encode('ok', TextEncodingKind.utf16le)), isFalse);
    });

    test('line endings and line/column', () {
      expect(TextCodec.detectLineEnding('a\nb\n'), LineEnding.lf);
      expect(TextCodec.detectLineEnding('a\r\nb\r\n'), LineEnding.crlf);
      expect(TextCodec.detectLineEnding('a\r\nb\n'), LineEnding.mixed);
      expect(TextCodec.detectLineEnding('abc'), LineEnding.none);
      expect(TextCodec.lineColumn('ab\ncd\r\nef', 7), (3, 1));
      expect(TextCodec.lineColumn('ab\ncd', 4), (2, 2));
    });
  });

  group('runBounded', () {
    test('returns results from the worker', () async {
      final r = await runBounded(() => 6 * 7, timeout: const Duration(seconds: 5));
      expect(r, 42);
    });

    test('kills catastrophic regex backtracking at the time limit', () async {
      final sw = Stopwatch()..start();
      await expectLater(
        runBounded(() => _catastrophic('${'a' * 40}!'), timeout: const Duration(milliseconds: 300)),
        throwsA(isA<OperationTimedOut>()),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('cancellation stops the worker', () async {
      final token = CancellationToken();
      final f = runBounded(_slowSum, timeout: const Duration(seconds: 30), token: token);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      token.cancel();
      await expectLater(f, throwsA(isA<OperationCancelled>()));
    });

    test('propagates worker errors', () async {
      await expectLater(
        runBounded<int>(() => throw const FormatException('bad input'), timeout: const Duration(seconds: 5)),
        throwsA(predicate((e) => e.toString().contains('bad input'))),
      );
    });
  });

  group('command line parsing', () {
    test('tokenizer honours quotes and escapes', () {
      expect(tokenizeCommandLine(r'hash "hello world" --algo sha256'), ['hash', 'hello world', '--algo', 'sha256']);
      expect(tokenizeCommandLine(r"echo 'single \n' "), ['echo', r'single \n']);
      expect(tokenizeCommandLine(r'say "a \"quoted\" word"'), ['say', 'a "quoted" word']);
      expect(tokenizeCommandLine('   '), isEmpty);
      expect(() => tokenizeCommandLine('open "unterminated'), throwsFormatException);
    });

    test('parseArgs handles value options, flags and negative numbers', () {
      final a = parseArgs(['text', '--algo', 'md5', '--upper', '-n', '-5', '--x=1'], valueOptions: {'algo'});
      expect(a.positional, ['text', '-5']);
      expect(a.option('algo'), 'md5');
      expect(a.flag('upper'), isTrue);
      expect(a.flag('n'), isTrue);
      expect(a.option('x'), '1');
      final b = parseArgs(['--', '--not-an-option']);
      expect(b.positional, ['--not-an-option']);
    });
  });

  group('capability matrix', () {
    test('mobile platforms never get linked folders or in-place mod apply', () {
      for (final plat in [AppPlatform.android, AppPlatform.ios]) {
        final caps = CapabilityMatrix(plat);
        expect(caps.supports(Capability.linkFolder), isFalse);
        expect(caps.supports(Capability.inPlaceModApply), isFalse);
        expect(caps.supports(Capability.importFiles), isTrue);
        expect(caps.supports(Capability.exportSaveDialog), isTrue);
        expect(caps.alternativeFor(Capability.linkFolder), isNotNull);
      }
    });

    test('windows supports desktop workflows', () {
      const caps = CapabilityMatrix(AppPlatform.windows);
      expect(caps.supports(Capability.linkFolder), isTrue);
      expect(caps.supports(Capability.keyboardShortcuts), isTrue);
      expect(caps.supports(Capability.shareSheet), isFalse);
      expect(caps.alternativeFor(Capability.shareSheet), isNotNull);
    });

    test('every capability has a platform entry', () {
      for (final c in Capability.values) {
        expect(CapabilityMatrix.table.containsKey(c), isTrue, reason: c.name);
      }
    });
  });

  test('AppInfo version matches pubspec', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*([0-9.]+)\+(\d+)', multiLine: true).firstMatch(pubspec)!;
    expect(AppInfo.version, m.group(1));
    expect(AppInfo.buildNumber, int.parse(m.group(2)!));
    expect(AppInfo.fullName, 'J3NSONTOP BIGGEST MULTITOOL MADE');
    expect(AppInfo.fullNameLines.join(' '), AppInfo.fullName);
  });
}
