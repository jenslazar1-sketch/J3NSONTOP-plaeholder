import '../storage/json_store.dart';

/// How a workspace's files are accessed.
enum WorkspaceKind {
  /// A folder chosen with the system folder picker and used in place
  /// (desktop only). Removing the record never deletes this folder.
  linked('Linked folder', 'Files are edited in place in the folder you chose.'),

  /// Files copied into app storage via the system document picker.
  imported('Imported copy', 'Files were copied into app storage. Export to get results out.'),

  /// The disposable demo workspace generated on first run.
  sample('Sample (disposable)', 'Generated example files. Safe to modify, reset or delete.');

  const WorkspaceKind(this.label, this.explanation);
  final String label;
  final String explanation;

  /// Whether the files live inside app-owned storage.
  bool get isAppOwned => this != linked;
}

class Workspace {
  const Workspace({
    required this.id,
    required this.name,
    required this.kind,
    required this.rootPath,
    required this.createdAt,
    required this.lastOpenedAt,
    this.note,
  });

  final String id;
  final String name;
  final WorkspaceKind kind;

  /// Absolute path of the workspace root on this device.
  final String rootPath;
  final DateTime createdAt;
  final DateTime lastOpenedAt;
  final String? note;

  Workspace copyWith({String? name, DateTime? lastOpenedAt, String? note}) => Workspace(
    id: id,
    name: name ?? this.name,
    kind: kind,
    rootPath: rootPath,
    createdAt: createdAt,
    lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
    note: note ?? this.note,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'rootPath': rootPath,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'lastOpenedAt': lastOpenedAt.toUtc().toIso8601String(),
    if (note != null) 'note': note,
  };

  static Workspace? fromJson(Map<String, dynamic> j) {
    final id = JsonRead.optString(j, 'id');
    final root = JsonRead.optString(j, 'rootPath');
    if (id == null || root == null) return null;
    final created = JsonRead.dateTime(j, 'createdAt') ?? DateTime.now();
    return Workspace(
      id: id,
      name: JsonRead.string(j, 'name', 'Workspace'),
      kind: JsonRead.enumByName(j, 'kind', WorkspaceKind.values, WorkspaceKind.imported),
      rootPath: root,
      createdAt: created,
      lastOpenedAt: JsonRead.dateTime(j, 'lastOpenedAt') ?? created,
      note: JsonRead.optString(j, 'note'),
    );
  }
}
