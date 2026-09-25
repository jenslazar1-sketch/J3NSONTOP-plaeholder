import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../commands/terminal_command.dart';
import '../platform/capabilities.dart';
import 'tool_definition.dart';

/// A scored search hit.
class ToolMatch {
  const ToolMatch(this.tool, this.score);
  final ToolDefinition tool;
  final double score;
}

/// Central registry of tools, section landings and terminal commands.
class ToolRegistry {
  ToolRegistry(List<FeatureModule> modules) : modules = List.unmodifiable(modules) {
    for (final m in modules) {
      for (final t in m.tools) {
        if (_byId.containsKey(t.id)) {
          throw StateError('Duplicate tool id ${t.id}');
        }
        _byId[t.id] = t;
      }
      for (final l in m.landings) {
        _landings[l.section] = l.builder;
      }
      for (final c in m.commands) {
        for (final name in [c.name, ...c.aliases]) {
          if (_commands.containsKey(name)) {
            throw StateError('Duplicate command name $name');
          }
          _commands[name] = c;
        }
      }
    }
  }

  final List<FeatureModule> modules;
  final Map<String, ToolDefinition> _byId = {};
  final Map<ToolSection, WidgetBuilder> _landings = {};
  final Map<String, TerminalCommand> _commands = {};

  Iterable<ToolDefinition> get all => _byId.values;

  ToolDefinition? byId(String id) => _byId[id];

  List<ToolDefinition> inSection(ToolSection s, [CapabilityMatrix? caps]) => [
    for (final t in _byId.values)
      if (t.section == s && (caps == null || t.availableOn(caps))) t,
  ];

  WidgetBuilder? landingFor(ToolSection s) => _landings[s];

  /// Unique commands (aliases collapsed), sorted by name.
  List<TerminalCommand> get commands {
    final seen = <TerminalCommand>{..._commands.values};
    return seen.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  TerminalCommand? command(String nameOrAlias) => _commands[nameOrAlias];

  /// Ranks tools against [query] by name, keywords and description.
  /// Empty query returns nothing (callers show favourites/recents instead).
  List<ToolMatch> search(String query, {CapabilityMatrix? caps, int limit = 50}) {
    final terms = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (terms.isEmpty) return const [];
    final hits = <ToolMatch>[];
    for (final t in _byId.values) {
      if (caps != null && !t.availableOn(caps)) continue;
      final name = t.name.toLowerCase();
      final id = t.id.toLowerCase();
      final desc = t.description.toLowerCase();
      final section = t.section.label.toLowerCase();
      final keywords = t.keywords.map((k) => k.toLowerCase()).toList();
      var score = 0.0;
      var allMatched = true;
      for (final term in terms) {
        var s = 0.0;
        if (name == term) {
          s = 100;
        } else if (name.startsWith(term)) {
          s = 60;
        } else if (name.split(RegExp(r'[\s/\-]+')).any((w) => w.startsWith(term))) {
          s = 45;
        } else if (name.contains(term)) {
          s = 30;
        } else if (keywords.any((k) => k == term)) {
          s = 40;
        } else if (keywords.any((k) => k.startsWith(term))) {
          s = 25;
        } else if (id.contains(term)) {
          s = 20;
        } else if (section.contains(term)) {
          s = 12;
        } else if (desc.contains(term)) {
          s = 10;
        } else if (_fuzzy(name, term)) {
          s = 5;
        }
        if (s == 0) {
          allMatched = false;
          break;
        }
        score += s;
      }
      if (allMatched) hits.add(ToolMatch(t, score));
    }
    hits.sort((a, b) {
      final c = b.score.compareTo(a.score);
      return c != 0 ? c : a.tool.name.compareTo(b.tool.name);
    });
    return hits.take(limit).toList();
  }

  /// Subsequence match ("b64" matches "base64").
  static bool _fuzzy(String haystack, String needle) {
    if (needle.length < 2) return false;
    var i = 0;
    for (final c in haystack.codeUnits) {
      if (c == needle.codeUnitAt(i)) {
        i++;
        if (i == needle.length) return true;
      }
    }
    return false;
  }
}

/// Overridden in `main()` with the catalog from `app/tool_catalog.dart`.
/// Tests override it with a small registry.
final toolRegistryProvider = Provider<ToolRegistry>(
  (ref) => throw UnimplementedError('toolRegistryProvider must be overridden'),
);
