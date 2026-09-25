import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Platforms the app knows about. Android, iOS and Windows are the delivered
/// targets; Linux is supported as a development/test target.
enum AppPlatform {
  android('Android'),
  ios('iOS'),
  windows('Windows'),
  linux('Linux (dev/test)'),
  macos('macOS (unsupported)'),
  other('Other');

  const AppPlatform(this.label);
  final String label;

  bool get isMobile => this == android || this == ios;
  bool get isDesktop => this == windows || this == linux || this == macos;

  static AppPlatform detect() {
    if (kIsWeb) return AppPlatform.other;
    if (Platform.isAndroid) return AppPlatform.android;
    if (Platform.isIOS) return AppPlatform.ios;
    if (Platform.isWindows) return AppPlatform.windows;
    if (Platform.isLinux) return AppPlatform.linux;
    if (Platform.isMacOS) return AppPlatform.macos;
    return AppPlatform.other;
  }
}

/// A platform capability a tool or action may require.
enum Capability {
  linkFolder('Link an existing folder', 'Work directly on a folder chosen with the system folder picker.'),
  importFiles('Import files', 'Copy files chosen in the system document picker into a workspace.'),
  importFolder('Import a folder', 'Copy a whole folder chosen in the system folder picker.'),
  exportSaveDialog('Save/export dialog', 'Write results to a location chosen in the system save dialog.'),
  shareSheet('Share sheet', 'Hand results to other apps via the share sheet.'),
  inPlaceModApply('Apply mods in place', 'Apply mod profiles directly to a linked game folder.'),
  revealInFileManager('Reveal in file manager', 'Open the containing folder in the system file manager.'),
  keyboardShortcuts('Keyboard shortcuts', 'Ctrl+K palette and other shortcuts.'),
  networkRequests('Network requests', 'Send explicitly entered HTTP requests to development endpoints.'),
  backgroundIsolates('Background workers', 'Heavy work runs off the UI thread in Dart isolates.'),
  audio('Sound', 'Optional interface and intro sounds.');

  const Capability(this.label, this.description);
  final String label;
  final String description;
}

/// Which capabilities each platform provides, and what to offer instead when
/// one is missing. This is the single source of truth: UI code must ask
/// [CapabilityMatrix.supports] rather than checking `Platform.isX` directly.
class CapabilityMatrix {
  const CapabilityMatrix(this.platform, [this._overrides = const {}]);

  final AppPlatform platform;
  final Map<Capability, bool> _overrides;

  static const Map<Capability, Set<AppPlatform>> table = {
    Capability.linkFolder: {AppPlatform.windows, AppPlatform.linux},
    Capability.importFiles: {AppPlatform.android, AppPlatform.ios, AppPlatform.windows, AppPlatform.linux},
    Capability.importFolder: {AppPlatform.windows, AppPlatform.linux},
    Capability.exportSaveDialog: {AppPlatform.android, AppPlatform.ios, AppPlatform.windows, AppPlatform.linux},
    Capability.shareSheet: {AppPlatform.android, AppPlatform.ios},
    Capability.inPlaceModApply: {AppPlatform.windows, AppPlatform.linux},
    Capability.revealInFileManager: {AppPlatform.windows, AppPlatform.linux},
    Capability.keyboardShortcuts: {AppPlatform.windows, AppPlatform.linux, AppPlatform.macos},
    Capability.networkRequests: {AppPlatform.android, AppPlatform.ios, AppPlatform.windows, AppPlatform.linux},
    Capability.backgroundIsolates: {
      AppPlatform.android,
      AppPlatform.ios,
      AppPlatform.windows,
      AppPlatform.linux,
      AppPlatform.macos,
    },
    Capability.audio: {AppPlatform.android, AppPlatform.ios, AppPlatform.windows, AppPlatform.linux},
  };

  /// Supported alternative shown when a capability is unavailable.
  static const Map<Capability, String> alternatives = {
    Capability.linkFolder:
        'Mobile systems do not allow direct access to other folders. Import '
        'files or a ZIP into a workspace copy instead, then export results.',
    Capability.importFolder: 'Pick several files, or import a ZIP archive of the folder.',
    Capability.shareSheet:
        'Use Export to choose a location with the system '
        'save dialog.',
    Capability.inPlaceModApply:
        'Profiles are applied to the imported workspace copy. Export the '
        'modified files or the whole workspace as a ZIP afterwards.',
    Capability.revealInFileManager:
        'Use Export or Share to hand the file to '
        'another app.',
    Capability.keyboardShortcuts:
        'Use the search button to open the command '
        'palette.',
  };

  bool supports(Capability c) => _overrides[c] ?? (table[c]?.contains(platform) ?? false);

  String? alternativeFor(Capability c) => supports(c) ? null : alternatives[c];

  bool supportsAll(Iterable<Capability> caps) => caps.every(supports);

  CapabilityMatrix copyWithOverrides(Map<Capability, bool> overrides) =>
      CapabilityMatrix(platform, {..._overrides, ...overrides});
}

/// Current platform. Override in tests to simulate other platforms.
final appPlatformProvider = Provider<AppPlatform>((ref) => AppPlatform.detect());

final capabilitiesProvider = Provider<CapabilityMatrix>((ref) => CapabilityMatrix(ref.watch(appPlatformProvider)));
