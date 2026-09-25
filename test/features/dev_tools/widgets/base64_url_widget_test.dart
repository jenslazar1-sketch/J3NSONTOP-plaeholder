import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/activity/activity_controller.dart';
import 'package:j3nsontop_multitool/core/platform/file_access.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/harness.dart';
import '../dev_test_utils.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  group('Base64 tool', () {
    testWidgets('renders with an empty state', (tester) async {
      await pumpDevTool(tester, env, 'dev.base64');
      expect(find.text('Base64'), findsWidgets);
      expect(find.text('Nothing to convert yet'), findsOneWidget);
      expect(find.text('File -> Base64'), findsOneWidget);
    });

    testWidgets('encodes live and decodes after switching mode', (tester) async {
      await pumpDevTool(tester, env, 'dev.base64');
      await enter(tester, 'dev.base64.input', 'Hello, modder!');
      expect(find.text('SGVsbG8sIG1vZGRlciE='), findsOneWidget);

      await tapVisible(tester, find.text('Decode'));
      await enter(tester, 'dev.base64.input', 'SGVsbG8s\nIG1vZGRlciE');
      expect(find.text('Hello, modder!'), findsOneWidget);
      expect(find.textContaining('no padding'), findsOneWidget);
    });

    testWidgets('URL-safe alphabet without padding', (tester) async {
      await pumpDevTool(tester, env, 'dev.base64');
      await tapVisible(tester, find.text('URL-safe'));
      await tapVisible(tester, find.text('Keep padding (=)'));
      await enter(tester, 'dev.base64.input', 'hello?>');
      expect(find.text('aGVsbG8_Pg'), findsOneWidget);
    });

    testWidgets('malformed Base64 shows the character position', (tester) async {
      await pumpDevTool(tester, env, 'dev.base64');
      await tapVisible(tester, find.text('Decode'));
      await enter(tester, 'dev.base64.input', 'aGVs*G8=');
      expect(find.textContaining('Not valid Base64'), findsOneWidget);
      expect(find.textContaining("Invalid Base64 character '*' (U+002A) at line 1, column 5"), findsOneWidget);
      expect(find.text('Go to line 1, col 5'), findsOneWidget);
    });

    testWidgets('binary output shows hex preview and saves as a file', (tester) async {
      final files = FakeFileAccess();
      await pumpDevTool(tester, env, 'dev.base64', files: files);
      await tapVisible(tester, find.text('Decode'));
      await enter(
        tester,
        'dev.base64.input',
        base64.encode([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 1, 0xFF]),
      );
      expect(find.textContaining('not valid UTF-8'), findsWidgets);
      expect(find.textContaining('looks like: PNG image'), findsOneWidget);
      await tapVisible(tester, find.text('Save as binary'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export...'));
      await tester.pumpAndSettle();
      expect(files.savedBytes.single.$1, 'decoded.png');
      expect(files.savedBytes.single.$2.length, 11);
    });

    testWidgets('File -> Base64 encodes a picked file in the background', (tester) async {
      final files = FakeFileAccess();
      final path = p.join(env.dir.path, 'icon.bin');
      File(path).writeAsBytesSync(List<int>.generate(300, (i) => i & 0xFF));
      files.queuedPicks.add([PickedLocalFile(name: 'icon.bin', path: path, size: 300)]);
      await pumpDevTool(tester, env, 'dev.base64', files: files);
      await tester.tap(find.text('File -> Base64'));
      await pumpUntil(tester, () => find.textContaining('of Base64').evaluate().isNotEmpty);
      expect(find.text('icon.bin'), findsOneWidget);
      expect(
        find.textContaining(base64.encode(List<int>.generate(300, (i) => i & 0xFF)).substring(0, 40)),
        findsOneWidget,
      );
    });

    testWidgets('files over 10 MiB are refused with a clear message', (tester) async {
      final files = FakeFileAccess();
      final path = p.join(env.dir.path, 'big.bin');
      final raf = File(path).openSync(mode: FileMode.write)
        ..setPositionSync(10 * 1024 * 1024 + 1)
        ..writeByteSync(0);
      raf.closeSync();
      files.queuedPicks.add([PickedLocalFile(name: 'big.bin', path: path, size: 10 * 1024 * 1024 + 2)]);
      final container = await pumpDevTool(tester, env, 'dev.base64', files: files);
      await tester.tap(find.text('File -> Base64'));
      String notices() => container.read(activityProvider).notices.map((n) => n.message).join('\n');
      await pumpUntil(tester, () => notices().isNotEmpty);
      expect(notices(), contains('the limit for this tool is 10.0 MB'));
      expect(find.textContaining('of Base64'), findsNothing);
    });

    testWidgets('fits a small phone at 2x text', (tester) async {
      await pumpDevTool(tester, env, 'dev.base64', size: smallPhone, textScale: 2);
      await enter(tester, 'dev.base64.input', 'Small screens still work');
      expect(find.text('U21hbGwgc2NyZWVucyBzdGlsbCB3b3Jr'), findsOneWidget);
    });
  });

  group('URL tool', () {
    testWidgets('renders and encodes components live', (tester) async {
      await pumpDevTool(tester, env, 'dev.url');
      expect(find.text('URL Encode/Decode'), findsWidgets);
      await enter(tester, 'dev.url.input', 'a b&c');
      expect(find.text('a%20b%26c'), findsOneWidget);
      await tapVisible(tester, find.text('Form (+ for spaces)'));
      expect(find.text('a+b%26c'), findsOneWidget);
    });

    testWidgets('decode reports malformed percent sequences with position', (tester) async {
      await pumpDevTool(tester, env, 'dev.url');
      await tapVisible(tester, find.text('Decode'));
      await enter(tester, 'dev.url.input', 'ok%2Gx');
      expect(find.textContaining('Malformed percent sequence "%2G" at line 1, column 3'), findsOneWidget);
    });

    testWidgets('inspector lists parts and decoded query parameters', (tester) async {
      await pumpDevTool(tester, env, 'dev.url');
      await tapVisible(tester, find.text('Inspect URL'));
      await enter(tester, 'dev.url.input', 'https://example.com:8443/a%20b?id=42&tag=x+y#top');
      expect(find.text('https://example.com:8443'), findsOneWidget);
      expect(find.text('example.com'), findsOneWidget);
      expect(find.text('8443'), findsOneWidget);
      expect(find.text('a b'), findsOneWidget);
      expect(find.text('x y'), findsOneWidget);
      expect(find.text('2 parameters'), findsOneWidget);
    });

    testWidgets('fits a small phone at 2x text in inspect mode', (tester) async {
      await pumpDevTool(tester, env, 'dev.url', size: smallPhone, textScale: 2);
      await tapVisible(tester, find.text('Inspect URL'));
      await enter(tester, 'dev.url.input', 'http://localhost/a/b?q=1');
      expect(find.text('localhost'), findsOneWidget);
    });
  });
}
