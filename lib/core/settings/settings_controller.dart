import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/app_stores.dart';
import 'app_settings.dart';

/// Holds [AppSettings] and persists every change atomically.
class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    // `--skip-intro` is handled by the router and never persisted here.
    return AppSettings.fromJson(ref.watch(bootDataProvider).settings.data);
  }

  Future<void> update(AppSettings Function(AppSettings s) change) async {
    final next = change(state);
    state = next;
    await ref.read(appStoresProvider).settings.save(next.toJson());
  }

  Future<void> resetToDefaults() => update((_) => const AppSettings());
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(SettingsController.new);
