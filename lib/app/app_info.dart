/// Static identity of the application. Every user-visible name and the
/// platform identifiers are defined here so they stay consistent across the
/// UI, documentation and platform configuration.
abstract final class AppInfo {
  /// The complete product name. Used on the splash/intro, dashboard and About.
  static const String fullName = 'J3NSONTOP BIGGEST MULTITOOL MADE';

  /// Short name for launchers, window titles and tight spaces.
  static const String shortName = 'J3NSONTOP Multitool';

  /// The same full name split with deliberate line breaks so it never clips
  /// on narrow screens. Rendered one line per entry.
  static const List<String> fullNameLines = <String>['J3NSONTOP', 'BIGGEST', 'MULTITOOL MADE'];

  /// Application identifier used for the Android applicationId/namespace,
  /// the iOS bundle identifier and signing documentation.
  static const String applicationId = 'com.j3nsontop.multitool';

  /// Kept in sync with `version:` in pubspec.yaml (verified by a unit test).
  static const String version = '1.0.0';
  static const int buildNumber = 1;

  static const String tagline = 'J3NSONTOP SYSTEM ONLINE';

  /// Short, honest description used on About and in the README.
  static const String description =
      'A local-first multitool for harmless modding of your own projects and '
      'games that support mods: mod profiles with backups and rollback, '
      'config editing, asset preparation, file utilities and developer tools.';

  static const String scopeStatement =
      'Harmless modding only: user-controlled files, supported game mod '
      'workflows, backups, asset tools and development utilities. No '
      'credential access, no anti-cheat bypasses, no multiplayer cheating, '
      'no telemetry and no cloud upload.';
}
