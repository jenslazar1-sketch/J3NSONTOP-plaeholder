import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/settings/settings_controller.dart';
import '../core/storage/app_stores.dart';
import '../core/theme/effects.dart';
import '../core/theme/j3_theme.dart';
import '../core/widgets/backdrop.dart';
import '../features/sample/sample_workspace.dart';
import 'app_info.dart';
import 'router.dart';
import 'smoke_test.dart';

/// Root widget. Applies the accent theme and the resolved effects config
/// (user settings + system reduce-motion), and owns the router.
class J3App extends ConsumerStatefulWidget {
  const J3App({super.key, this.routerOverride});

  /// Tests may inject a router.
  final GoRouter? routerOverride;

  @override
  ConsumerState<J3App> createState() => _J3AppState();
}

class _J3AppState extends ConsumerState<J3App> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    final launch = ref.read(bootDataProvider).launchArgs;
    _router = widget.routerOverride ?? buildRouter(showIntro: !settings.skipIntro && !launch.skipIntro);
    // Real first-run work starts right away, in parallel with the intro.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (launch.isSmokeTest) {
        _runSmokeTest(launch.smokeTestReport!);
      } else {
        ensureSampleWorkspaceOnFirstRun(ref);
      }
    });
  }

  Future<void> _runSmokeTest(String reportPath) async {
    var ok = false;
    try {
      ok = await SmokeTestRunner(ref: ref, router: _router, reportPath: reportPath).run();
    } catch (e, st) {
      stderr.writeln('Smoke test crashed: $e\n$st');
    }
    exit(ok ? 0 : 1);
  }

  @override
  void dispose() {
    if (widget.routerOverride == null) _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    return MaterialApp.router(
      title: AppInfo.shortName,
      debugShowCheckedModeBanner: false,
      theme: J3Theme.build(settings.accent),
      darkTheme: J3Theme.build(settings.accent),
      themeMode: ThemeMode.dark,
      routerConfig: _router,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final config = EffectsConfig.resolve(
          settings,
          systemReduce: media.disableAnimations,
          systemHighContrast: media.highContrast,
        );
        return J3Effects(
          config: config,
          child: J3Backdrop(child: child ?? const SizedBox.shrink()),
        );
      },
    );
  }
}
