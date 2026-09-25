import '../../../core/platform/capabilities.dart';
import '../../../core/tools/tool_definition.dart';
import '../../shell/destinations.dart';

/// Short, typeable keys for the tool sections (`tools dev`, `open mods`).
String sectionKey(ToolSection s) => s == ToolSection.system ? 'system' : s.route.substring(1);

/// Resolves a section from its key (`dev`), enum name (`devTools`) or label
/// (`Developer Tools`), case-insensitively.
ToolSection? sectionFromText(String text) {
  final q = text.trim().toLowerCase();
  if (q.isEmpty) return null;
  for (final s in ToolSection.values) {
    if (sectionKey(s) == q || s.name.toLowerCase() == q || s.label.toLowerCase() == q) return s;
  }
  return null;
}

List<String> get sectionKeys => [for (final s in ToolSection.values) sectionKey(s)];

/// Named navigation targets for `open`: home, the section routes and the
/// top-level pages. Derived from [ToolSection] so they always match the
/// router.
Map<String, String> openTargets() => {
  'home': '/',
  for (final s in ToolSection.values) s.route.substring(1): s.route,
  'activity': '/activity',
  'settings': '/settings',
  'about': '/about',
  'terminal': kTerminalRoute,
};

/// Static routes accepted by `open /...` (besides `/tool/<id>`).
Set<String> knownRoutes() => {
  for (final d in kDestinations) d.route,
  for (final s in ToolSection.values) s.route,
  '/tools',
  '/activity',
  '/settings',
  '/about',
  '/terminal',
  '/intro',
};

/// Why [tool] cannot be used on this platform, or null when it can.
String? unavailableReason(ToolDefinition tool, CapabilityMatrix caps) {
  if (tool.availableOn(caps)) return null;
  if (!tool.platforms.contains(caps.platform)) return 'not built for ${caps.platform.label}';
  final missing = [
    for (final c in tool.requiredCapabilities)
      if (!caps.supports(c)) c.label,
  ];
  return 'needs ${missing.join(', ')} (not available on ${caps.platform.label})';
}

/// Parses on/off style booleans.
bool? parseSwitch(String? v) => switch (v?.toLowerCase()) {
  'on' || 'true' || 'yes' || '1' || 'enable' || 'enabled' => true,
  'off' || 'false' || 'no' || '0' || 'disable' || 'disabled' => false,
  _ => null,
};

/// Width of the widest string (capped) for simple column alignment.
int columnWidth(Iterable<String> values, {int max = 28}) {
  var w = 0;
  for (final v in values) {
    if (v.length > w) w = v.length;
  }
  return w > max ? max : w;
}
