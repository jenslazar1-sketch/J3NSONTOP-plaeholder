/// Lazy, virtualised tree view of a JSON-like value. Only expanded nodes are
/// materialised as rows; rows are built on demand by a ListView with a fixed
/// extent (scaled with the text size) so it stays fast for large documents
/// and can scroll to a revealed node.
library;

import 'package:flutter/material.dart';

import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../domain/json_value.dart';

/// Type label/colour/preview for a node.
class TreeTypeInfo {
  const TreeTypeInfo({required this.label, required this.fullName, required this.color, required this.preview});
  final String label;
  final String fullName;
  final Color color;
  final String preview;
}

typedef TreeDescriber = TreeTypeInfo Function(Object? value, EffectsConfig fx);

TreeTypeInfo describeJsonNode(Object? v, EffectsConfig fx) => switch (v) {
  Map<Object?, Object?>() => TreeTypeInfo(
    label: 'obj',
    fullName: 'object',
    color: fx.accentText,
    preview: v.isEmpty ? '{}' : '{ ${v.length} ${v.length == 1 ? 'key' : 'keys'} }',
  ),
  List<Object?>() => TreeTypeInfo(
    label: 'arr',
    fullName: 'array',
    color: J3Colors.info,
    preview: v.isEmpty ? '[]' : '[ ${v.length} ${v.length == 1 ? 'item' : 'items'} ]',
  ),
  String() => TreeTypeInfo(
    label: 'str',
    fullName: 'string',
    color: J3Colors.success,
    preview: jsonPreview(v, max: 200),
  ),
  int() => TreeTypeInfo(label: 'int', fullName: 'integer number', color: J3Colors.warning, preview: '$v'),
  double() => TreeTypeInfo(label: 'num', fullName: 'number', color: J3Colors.warning, preview: jsonPreview(v)),
  bool() => TreeTypeInfo(label: 'bool', fullName: 'boolean', color: J3Colors.textSecondary, preview: '$v'),
  null => const TreeTypeInfo(label: 'null', fullName: 'null', color: J3Colors.textMuted, preview: 'null'),
  _ => TreeTypeInfo(label: 'val', fullName: v.runtimeType.toString(), color: J3Colors.info, preview: '$v'),
};

/// A row of the flattened tree.
class TreeRow {
  const TreeRow({
    required this.path,
    required this.pointer,
    required this.label,
    required this.value,
    required this.depth,
    required this.parentIsArray,
  });

  final List<Object> path;
  final String pointer;

  /// Key or index as displayed.
  final String label;
  final Object? value;
  final int depth;
  final bool parentIsArray;

  bool get isContainer => value is Map<Object?, Object?> || value is List<Object?>;
  bool get isRoot => path.isEmpty;
}

String _keySegment(Object? key) => key is String ? key : '$key';

/// Flattens [root] showing children of expanded pointers only.
List<TreeRow> flattenTree(Object? root, Set<String> expanded, {String rootLabel = 'root'}) {
  final rows = <TreeRow>[];
  void visit(Object? value, List<Object> path, String label, int depth, bool parentIsArray) {
    final pointer = formatJsonPointer(path);
    rows.add(
      TreeRow(path: path, pointer: pointer, label: label, value: value, depth: depth, parentIsArray: parentIsArray),
    );
    if (!expanded.contains(pointer)) return;
    if (value is Map<Object?, Object?>) {
      for (final e in value.entries) {
        final seg = _keySegment(e.key);
        visit(
          e.value,
          [...path, seg],
          e.key is String ? seg : '$seg (${jsonDetailedType(e.key)} key)',
          depth + 1,
          false,
        );
      }
    } else if (value is List<Object?>) {
      for (var i = 0; i < value.length; i++) {
        visit(value[i], [...path, i], '[$i]', depth + 1, true);
      }
    }
  }

  visit(root, const [], rootLabel, 0, false);
  return rows;
}

/// Pointers of every container in [root] (for "Expand all"), or null when
/// there are more than [limit].
Set<String>? allContainerPointers(Object? root, {int limit = 5000}) {
  final out = <String>{};
  final stack = <(Object?, List<Object>)>[(root, const [])];
  while (stack.isNotEmpty) {
    final (v, path) = stack.removeLast();
    if (v is Map<Object?, Object?>) {
      out.add(formatJsonPointer(path));
      for (final e in v.entries) {
        stack.add((e.value, [...path, _keySegment(e.key)]));
      }
    } else if (v is List<Object?>) {
      out.add(formatJsonPointer(path));
      for (var i = 0; i < v.length; i++) {
        stack.add((v[i], [...path, i]));
      }
    }
    if (out.length > limit) return null;
  }
  return out;
}

/// Pointers of all ancestors of [path] (to reveal a node).
Set<String> ancestorPointers(List<Object> path) => {
  for (var i = 0; i < path.length; i++) formatJsonPointer(path.sublist(0, i)),
};

enum TreeAction { editValue, renameKey, addProperty, addItem, delete, copyPath, copyValue }

class ValueTreeView extends StatefulWidget {
  const ValueTreeView({
    super.key,
    required this.root,
    required this.expanded,
    required this.onToggle,
    required this.onAction,
    this.describe = describeJsonNode,
    this.editable = false,
    this.selectedPointer,
    this.revealToken,
    this.height = 460,
    this.rootLabel = 'root',
  });

  final Object? root;
  final Set<String> expanded;
  final ValueChanged<String> onToggle;
  final void Function(TreeAction action, TreeRow row) onAction;
  final TreeDescriber describe;
  final bool editable;
  final String? selectedPointer;

  /// Change to scroll [selectedPointer] into view.
  final Object? revealToken;
  final double height;
  final String rootLabel;

  @override
  State<ValueTreeView> createState() => _ValueTreeViewState();
}

class _ValueTreeViewState extends State<ValueTreeView> {
  final ScrollController _scroll = ScrollController();
  List<TreeRow>? _rows;
  Object? _rowsRoot;
  Set<String>? _rowsExpanded;
  double _extent = 44;

  @override
  void didUpdateWidget(ValueTreeView old) {
    super.didUpdateWidget(old);
    if (old.revealToken != widget.revealToken && widget.selectedPointer != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<TreeRow> get _flat {
    if (_rows == null || !identical(_rowsRoot, widget.root) || !identical(_rowsExpanded, widget.expanded)) {
      _rows = flattenTree(widget.root, widget.expanded, rootLabel: widget.rootLabel);
      _rowsRoot = widget.root;
      _rowsExpanded = widget.expanded;
    }
    return _rows!;
  }

  void _reveal() {
    if (!mounted || !_scroll.hasClients) return;
    final i = _flat.indexWhere((r) => r.pointer == widget.selectedPointer);
    if (i < 0) return;
    final target = ((i - 2) * _extent).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final scaler = MediaQuery.textScalerOf(context);
    _extent = (scaler.scale(J3Type.code.fontSize! * 1.45) + 18).clamp(44.0, 200.0);
    final rows = _flat;
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: J3Colors.inputFill,
        borderRadius: J3Radius.small,
        border: Border.all(color: J3Colors.border),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Scrollbar(
          controller: _scroll,
          child: LayoutBuilder(
            builder: (context, c) {
              final maxIndent = c.maxWidth * 0.3;
              return ListView.builder(
                controller: _scroll,
                itemCount: rows.length,
                itemExtent: _extent,
                itemBuilder: (context, i) => _row(context, rows[i], fx, maxIndent),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, TreeRow r, EffectsConfig fx, double maxIndent) {
    final info = widget.describe(r.value, fx);
    final open = widget.expanded.contains(r.pointer);
    final selected = r.pointer == widget.selectedPointer;
    final indent = (r.depth * 14.0).clamp(0.0, maxIndent);
    return Semantics(
      label: '${r.label}, ${info.fullName}, ${info.preview}',
      selected: selected,
      child: Container(
        color: selected ? J3Colors.selection : null,
        padding: EdgeInsets.only(left: indent),
        child: Row(
          children: [
            if (r.isContainer)
              IconButton(
                tooltip: open ? 'Collapse ${r.label}' : 'Expand ${r.label}',
                onPressed: () => widget.onToggle(r.pointer),
                icon: Icon(open ? Icons.expand_more : Icons.chevron_right, size: 20),
              )
            else
              const SizedBox(width: 44),
            Flexible(
              flex: 3,
              child: Text(
                r.label,
                style: J3Type.code.copyWith(
                  color: r.parentIsArray || r.isRoot ? J3Colors.textSecondary : J3Colors.text,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: J3Space.sm),
            Flexible(
              flex: 2,
              child: TypeChip(label: info.label, color: info.color, tooltip: info.fullName),
            ),
            const SizedBox(width: J3Space.sm),
            Expanded(
              flex: 5,
              child: Text(
                info.preview,
                style: J3Type.code.copyWith(color: r.isContainer ? J3Colors.textMuted : J3Colors.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            PopupMenuButton<TreeAction>(
              tooltip: 'Actions for ${formatJsonPath(r.path)}',
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (a) => widget.onAction(a, r),
              itemBuilder: (context) => [
                if (widget.editable && !r.isContainer)
                  const PopupMenuItem(value: TreeAction.editValue, child: Text('Edit value…')),
                if (widget.editable && r.isContainer)
                  const PopupMenuItem(value: TreeAction.editValue, child: Text('Replace value…')),
                if (widget.editable && r.value is Map<Object?, Object?>)
                  const PopupMenuItem(value: TreeAction.addProperty, child: Text('Add property…')),
                if (widget.editable && r.value is List<Object?>)
                  const PopupMenuItem(value: TreeAction.addItem, child: Text('Add item…')),
                if (widget.editable && !r.isRoot && !r.parentIsArray)
                  const PopupMenuItem(value: TreeAction.renameKey, child: Text('Rename key…')),
                if (widget.editable && !r.isRoot)
                  PopupMenuItem(
                    value: TreeAction.delete,
                    child: Text(r.parentIsArray ? 'Delete item' : 'Delete property'),
                  ),
                const PopupMenuItem(value: TreeAction.copyPath, child: Text('Copy JSONPath')),
                const PopupMenuItem(value: TreeAction.copyValue, child: Text('Copy value as JSON')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Coloured type chip that always carries a text label.
class TypeChip extends StatelessWidget {
  const TypeChip({super.key, required this.label, required this.color, this.tooltip});
  final String label;
  final Color color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: J3Radius.small,
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Text(
        label,
        style: J3Type.codeSmall.copyWith(color: color, fontWeight: FontWeight.w500),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}
