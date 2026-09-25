import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_stores.dart';
import 'json_store.dart';

/// A saved set of tool inputs/options ("preset").
class ToolPreset {
  const ToolPreset({
    required this.id,
    required this.toolId,
    required this.name,
    required this.values,
    required this.createdAt,
  });

  final String id;
  final String toolId;
  final String name;

  /// JSON-compatible values owned by the tool.
  final Map<String, dynamic> values;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'toolId': toolId,
    'name': name,
    'values': values,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  static ToolPreset? fromJson(Map<String, dynamic> j) {
    final id = JsonRead.optString(j, 'id');
    final toolId = JsonRead.optString(j, 'toolId');
    final name = JsonRead.optString(j, 'name');
    if (id == null || toolId == null || name == null) return null;
    return ToolPreset(
      id: id,
      toolId: toolId,
      name: name,
      values: JsonRead.object(j, 'values'),
      createdAt: JsonRead.dateTime(j, 'createdAt') ?? DateTime.now(),
    );
  }
}

class RecentTool {
  const RecentTool(this.toolId, this.openedAt);
  final String toolId;
  final DateTime openedAt;
}

/// Favourites (ordered, user-draggable), recently opened tools and presets.
class UserData {
  const UserData({
    this.favorites = const [],
    this.recentTools = const [],
    this.presets = const [],
    this.commandHistory = const [],
  });

  final List<String> favorites;
  final List<RecentTool> recentTools;
  final List<ToolPreset> presets;

  /// Terminal command history (newest last), capped.
  final List<String> commandHistory;

  List<ToolPreset> presetsFor(String toolId) => presets.where((p) => p.toolId == toolId).toList();

  Map<String, dynamic> toJson() => {
    'favorites': favorites,
    'recentTools': [
      for (final r in recentTools) {'toolId': r.toolId, 'openedAt': r.openedAt.toUtc().toIso8601String()},
    ],
    'presets': [for (final p in presets) p.toJson()],
    'commandHistory': commandHistory,
  };

  factory UserData.fromJson(Map<String, dynamic> j) {
    return UserData(
      favorites: JsonRead.stringList(j, 'favorites').toSet().toList(),
      recentTools: [
        for (final m in JsonRead.objectList(j, 'recentTools'))
          if (m['toolId'] is String)
            RecentTool(m['toolId'] as String, JsonRead.dateTime(m, 'openedAt') ?? DateTime.now()),
      ],
      presets: [for (final m in JsonRead.objectList(j, 'presets')) ?ToolPreset.fromJson(m)],
      commandHistory: JsonRead.stringList(j, 'commandHistory'),
    );
  }

  UserData copyWith({
    List<String>? favorites,
    List<RecentTool>? recentTools,
    List<ToolPreset>? presets,
    List<String>? commandHistory,
  }) => UserData(
    favorites: favorites ?? this.favorites,
    recentTools: recentTools ?? this.recentTools,
    presets: presets ?? this.presets,
    commandHistory: commandHistory ?? this.commandHistory,
  );
}

class UserDataController extends Notifier<UserData> {
  static const int recentLimit = 12;
  static const int commandHistoryLimit = 200;

  @override
  UserData build() => UserData.fromJson(ref.watch(bootDataProvider).userData.data);

  Future<void> _set(UserData next) async {
    state = next;
    await ref.read(appStoresProvider).userData.save(next.toJson());
  }

  bool isFavorite(String toolId) => state.favorites.contains(toolId);

  Future<void> toggleFavorite(String toolId) {
    final favs = [...state.favorites];
    if (!favs.remove(toolId)) favs.add(toolId);
    return _set(state.copyWith(favorites: favs));
  }

  Future<void> reorderFavorites(int oldIndex, int newIndex) {
    final favs = [...state.favorites];
    if (oldIndex < 0 || oldIndex >= favs.length) return Future.value();
    final item = favs.removeAt(oldIndex);
    favs.insert(newIndex.clamp(0, favs.length), item);
    return _set(state.copyWith(favorites: favs));
  }

  Future<void> recordToolOpened(String toolId) {
    final recents = [
      RecentTool(toolId, DateTime.now()),
      ...state.recentTools.where((r) => r.toolId != toolId),
    ].take(recentLimit).toList();
    return _set(state.copyWith(recentTools: recents));
  }

  Future<void> savePreset(ToolPreset preset) {
    final presets = [...state.presets.where((p) => p.id != preset.id), preset];
    return _set(state.copyWith(presets: presets));
  }

  Future<void> deletePreset(String presetId) =>
      _set(state.copyWith(presets: state.presets.where((p) => p.id != presetId).toList()));

  Future<void> recordCommand(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return Future.value();
    final history = [...state.commandHistory.where((c) => c != trimmed), trimmed];
    final capped = history.length > commandHistoryLimit
        ? history.sublist(history.length - commandHistoryLimit)
        : history;
    return _set(state.copyWith(commandHistory: capped));
  }
}

final userDataProvider = NotifierProvider<UserDataController, UserData>(UserDataController.new);

/// Namespaced, JSON-compatible storage for feature-owned data (palettes,
/// HTTP history, saved patterns...). Each feature owns its key and embeds
/// its own `"v"` field if it needs to migrate its payload later.
class FeatureDataController extends Notifier<Map<String, dynamic>> {
  @override
  Map<String, dynamic> build() => Map<String, dynamic>.from(ref.watch(bootDataProvider).features.data);

  Object? read(String key) => state[key];

  Future<void> write(String key, Object? value) async {
    final next = Map<String, dynamic>.from(state);
    if (value == null) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    state = next;
    await ref.read(appStoresProvider).features.save(next);
  }
}

final featureDataProvider = NotifierProvider<FeatureDataController, Map<String, dynamic>>(FeatureDataController.new);
