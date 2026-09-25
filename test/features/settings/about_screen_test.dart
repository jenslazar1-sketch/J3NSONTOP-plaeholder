import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/app/app_info.dart';
import 'package:j3nsontop_multitool/features/intro/skull_art.dart';
import 'package:j3nsontop_multitool/features/settings/licenses.dart';

import '../../helpers/harness.dart';
import '../home/experience_harness.dart';

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  double jawTop(WidgetTester tester) {
    final width = kSkullJaw.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    return tester.getTopLeft(find.text(kSkullJaw.first.padRight(width))).dy;
  }

  group('AboutScreen', () {
    testWidgets('shows identity, scope, matrix and credits', (tester) async {
      setSurface(tester, const Size(1400, 3000));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/about'));
      await tester.pump();

      for (final line in AppInfo.fullNameLines) {
        expect(find.text(line), findsOneWidget);
      }
      expect(find.text(AppInfo.applicationId), findsOneWidget);
      expect(find.text(AppInfo.version), findsOneWidget);
      expect(find.text('${AppInfo.buildNumber}'), findsOneWidget);
      expect(find.text('Linux (dev/test)'), findsOneWidget);
      expect(find.text(AppInfo.description), findsOneWidget);
      expect(find.text(AppInfo.scopeStatement), findsOneWidget);
      expect(find.textContaining('No telemetry'), findsOneWidget);
      // Matrix columns and a known row.
      for (final col in ['Android', 'iOS', 'Windows', 'Linux (dev)\n(this device)']) {
        expect(find.text(col), findsOneWidget, reason: col);
      }
      expect(find.text('Share sheet'), findsOneWidget);
      // Credits.
      expect(find.textContaining('tool/skull/skull_design.py'), findsOneWidget);
      expect(find.textContaining('tool/sound/generate_intro_sound.py'), findsOneWidget);
      expect(find.text('Chakra Petch - SIL Open Font License 1.1'), findsOneWidget);
      expect(find.text('JetBrains Mono - SIL Open Font License 1.1'), findsOneWidget);
    });

    testWidgets('font licence dialog shows the bundled OFL text', (tester) async {
      setSurface(tester, const Size(1400, 3000));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/about'));
      await tester.pump();
      await tester.ensureVisible(find.text('View licence').first);
      await tester.tap(find.text('View licence').first);
      await tester.pump();
      await pumpUntilFound(tester, find.textContaining('SIL OPEN FONT LICENSE'));
      expect(find.textContaining('Chakra Petch Project Authors'), findsWidgets);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.textContaining('SIL OPEN FONT LICENSE'), findsNothing);
    });

    testWidgets('replay intro navigates to the intro route', (tester) async {
      setSurface(tester, const Size(1400, 3000));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/about'));
      await tester.pump();
      await tester.tap(find.text('Replay intro'));
      await tester.pumpAndSettle();
      expect(find.text('INTRO replay=1'), findsOneWidget);
    });

    testWidgets('long-press makes the skull laugh; the jaw returns', (tester) async {
      setSurface(tester, const Size(1400, 3000));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/about', effects: motionEffects));
      await tester.pump();
      final rest = jawTop(tester);
      await tester.longPress(find.byKey(const ValueKey('about-skull')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 230));
      expect(jawTop(tester), greaterThan(rest));
      await tester.pump(const Duration(seconds: 2));
      expect(jawTop(tester), rest);
    });

    testWidgets('five quick taps also work; reduced motion keeps the jaw still', (tester) async {
      setSurface(tester, const Size(1400, 3000));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/about'));
      await tester.pump();
      final rest = jawTop(tester);
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byKey(const ValueKey('about-skull')));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.pump(const Duration(milliseconds: 200));
      expect(jawTop(tester), rest);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('fits a 320 px phone at 2x text without overflow', (tester) async {
      await loadAppFonts();
      usePhoneWithLargeText(tester);
      await tester.pumpWidget(buildExperienceApp(env, initial: '/about'));
      await tester.pump();
      await scrollThrough(tester);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('font licence entries carry the bundled OFL texts; registration is idempotent', (tester) async {
    // rootBundle caches futures; drop ones created in earlier tests' zones.
    for (final f in kBundledFontLicenses) {
      rootBundle.evict(f.asset);
    }
    final entries = (await tester.runAsync(() => appLicenseEntries().toList().timeout(const Duration(seconds: 10))))!;
    expect(entries.expand((e) => e.packages).toList(), ['Chakra Petch (font)', 'JetBrains Mono (font)']);
    for (final e in entries) {
      final text = e.paragraphs.map((p) => p.text).join('\n');
      expect(text, contains('SIL OPEN FONT LICENSE'));
    }
    expect(appLicensesRegistered, isFalse);
    registerAppLicenses();
    registerAppLicenses();
    expect(appLicensesRegistered, isTrue);
  });
}
