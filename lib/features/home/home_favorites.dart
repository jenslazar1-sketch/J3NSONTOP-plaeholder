import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/platform/capabilities.dart';
import '../../core/storage/user_data.dart';
import '../../core/theme/effects.dart';
import '../../core/theme/j3_colors.dart';
import '../../core/theme/j3_spacing.dart';
import '../../core/theme/j3_typography.dart';
import '../../core/tools/tool_definition.dart';
import '../../core/tools/tool_registry.dart';
import '../../core/widgets/widgets.dart';

/// Where a favourite moves in the grid.
enum FavoriteMove {
  left('Move left', Icons.arrow_back),
  right('Move right', Icons.arrow_forward),
  up('Move up', Icons.arrow_upward),
  down('Move down', Icons.arrow_downward);

  const FavoriteMove(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Target index of a move in a grid with [cols] columns and [count]
/// items, or null when the move is not possible. In a single column,
/// left/right are unavailable and up/down step by one.
int? favoriteMoveTarget(FavoriteMove move, {required int index, required int count, required int cols}) {
  if (count < 2 || index < 0 || index >= count) return null;
  final c = cols < 1 ? 1 : cols;
  switch (move) {
    case FavoriteMove.left:
      return c == 1 || index == 0 ? null : index - 1;
    case FavoriteMove.right:
      return c == 1 || index == count - 1 ? null : index + 1;
    case FavoriteMove.up:
      final t = index - c;
      return t < 0 ? null : t;
    case FavoriteMove.down:
      // Moving down from any row but the last lands in the next row (the
      // end of a partial last row when the column below is empty).
      if (index ~/ c >= (count - 1) ~/ c) return null;
      final t = index + c;
      return t > count - 1 ? count - 1 : t;
  }
}

/// Ordered favourite tools with drag-to-reorder, a per-card menu and
/// Alt+Arrow keys as alternatives. Order is persisted in userdata.json.
class FavoritesPanel extends ConsumerWidget {
  const FavoritesPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorites = ref.watch(userDataProvider.select((u) => u.favorites));
    return NeonPanel(
      kicker: '// FAVORITES',
      title: favorites.isEmpty ? 'Pinned tools' : 'Pinned tools (${favorites.length})',
      icon: Icons.star_outline_rounded,
      actions: [
        if (favorites.length > 1)
          const Tooltip(
            message:
                'Drag a card by its handle (or long-press it) to reorder. Keyboard: focus a card and press '
                'Alt+Arrow keys, or use its menu.',
            child: Padding(
              padding: EdgeInsets.all(J3Space.sm),
              child: Icon(Icons.help_outline, size: 18, color: J3Colors.textMuted),
            ),
          ),
      ],
      child: favorites.isEmpty
          ? EmptyState(
              title: 'No favourites yet',
              message:
                  'Open any tool and press the star button in its header to pin it here. Pinned tools can be '
                  'reordered by dragging, with Alt+Arrow keys or with their menu.',
              glyph: '[ * ]',
              action: IntrinsicWidth(
                child: NeonButton.secondary(
                  label: 'Browse all tools',
                  icon: Icons.apps,
                  onPressed: () => context.go('/tools'),
                ),
              ),
            )
          : FavoritesGrid(favorites: favorites),
    );
  }
}

class FavoritesGrid extends ConsumerStatefulWidget {
  const FavoritesGrid({super.key, required this.favorites});
  final List<String> favorites;

  @override
  ConsumerState<FavoritesGrid> createState() => _FavoritesGridState();
}

class _FavoritesGridState extends ConsumerState<FavoritesGrid> {
  String? _dragging;

  void _moveTo(String id, int target) {
    final from = widget.favorites.indexOf(id);
    if (from < 0 || target == from || target < 0 || target >= widget.favorites.length) return;
    ref.read(userDataProvider.notifier).reorderFavorites(from, target);
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(toolRegistryProvider);
    final caps = ref.watch(capabilitiesProvider);
    final favs = widget.favorites;
    return LayoutBuilder(
      builder: (context, c) {
        const gap = J3Space.sm;
        final cols = ((c.maxWidth + gap) / (250 + gap)).floor().clamp(1, 4);
        final w = (c.maxWidth - (cols - 1) * gap) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (var i = 0; i < favs.length; i++)
              SizedBox(
                key: ValueKey('fav-${favs[i]}'),
                width: w,
                child: _FavoriteSlot(
                  id: favs[i],
                  index: i,
                  count: favs.length,
                  cols: cols,
                  width: w,
                  tool: registry.byId(favs[i]),
                  available: registry.byId(favs[i])?.availableOn(caps) ?? false,
                  dimmed: _dragging == favs[i],
                  onDragState: (dragging) => setState(() => _dragging = dragging ? favs[i] : null),
                  onDropFrom: (from) => _moveTo(from, i),
                  onMove: (m) {
                    final t = favoriteMoveTarget(m, index: i, count: favs.length, cols: cols);
                    if (t != null) _moveTo(favs[i], t);
                  },
                  onRemove: () => ref.read(userDataProvider.notifier).toggleFavorite(favs[i]),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MoveIntent extends Intent {
  const _MoveIntent(this.move);
  final FavoriteMove move;
}

enum _MenuAction { open, left, right, up, down, remove }

class _FavoriteSlot extends StatefulWidget {
  const _FavoriteSlot({
    required this.id,
    required this.index,
    required this.count,
    required this.cols,
    required this.width,
    required this.tool,
    required this.available,
    required this.dimmed,
    required this.onDragState,
    required this.onDropFrom,
    required this.onMove,
    required this.onRemove,
  });

  final String id;
  final int index;
  final int count;
  final int cols;
  final double width;
  final ToolDefinition? tool;
  final bool available;
  final bool dimmed;
  final ValueChanged<bool> onDragState;
  final ValueChanged<String> onDropFrom;
  final ValueChanged<FavoriteMove> onMove;
  final VoidCallback onRemove;

  @override
  State<_FavoriteSlot> createState() => _FavoriteSlotState();
}

class _FavoriteSlotState extends State<_FavoriteSlot> {
  bool _hover = false;
  bool _focus = false;

  String get _name => widget.tool?.name ?? widget.id;

  void _open() {
    final t = widget.tool;
    if (t != null && widget.available) context.go(t.route);
  }

  bool _can(FavoriteMove m) =>
      favoriteMoveTarget(m, index: widget.index, count: widget.count, cols: widget.cols) != null;

  void _onMenu(_MenuAction a) {
    switch (a) {
      case _MenuAction.open:
        _open();
      case _MenuAction.left:
        widget.onMove(FavoriteMove.left);
      case _MenuAction.right:
        widget.onMove(FavoriteMove.right);
      case _MenuAction.up:
        widget.onMove(FavoriteMove.up);
      case _MenuAction.down:
        widget.onMove(FavoriteMove.down);
      case _MenuAction.remove:
        widget.onRemove();
    }
  }

  Widget _card(BuildContext context, {required bool highlighted, bool feedback = false}) {
    final fx = context.effects;
    final t = widget.tool;
    final active = !feedback && (_hover || _focus);
    final borderColor = highlighted
        ? fx.accentColor
        : _focus
        ? fx.accentColor
        : active
        ? fx.accentColor.withValues(alpha: 0.6)
        : J3Colors.border;
    final subtitle = t == null
        ? 'This tool is not part of this version.'
        : !widget.available
        ? 'Not available on this platform.'
        : t.description;

    // Built only for the real card (the drag feedback has no controls).
    Widget handle() => Draggable<String>(
      data: widget.id,
      feedback: _feedback(context),
      onDragStarted: () => widget.onDragState(true),
      onDragEnd: (_) => widget.onDragState(false),
      onDraggableCanceled: (_, _) => widget.onDragState(false),
      child: const Tooltip(
        message: 'Drag to reorder',
        child: SizedBox(
          width: 40,
          height: 44,
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: Icon(Icons.drag_indicator, size: 20, color: J3Colors.textMuted),
          ),
        ),
      ),
    );

    Widget menu() => PopupMenuButton<_MenuAction>(
      tooltip: 'Reorder or remove "$_name"',
      icon: const Icon(Icons.more_vert, size: 20),
      onSelected: _onMenu,
      itemBuilder: (context) => [
        if (t != null && widget.available) _menuItem(_MenuAction.open, 'Open', Icons.open_in_new, true),
        if (widget.cols > 1) ...[
          _menuItem(_MenuAction.left, FavoriteMove.left.label, FavoriteMove.left.icon, _can(FavoriteMove.left)),
          _menuItem(_MenuAction.right, FavoriteMove.right.label, FavoriteMove.right.icon, _can(FavoriteMove.right)),
        ],
        _menuItem(_MenuAction.up, FavoriteMove.up.label, FavoriteMove.up.icon, _can(FavoriteMove.up)),
        _menuItem(_MenuAction.down, FavoriteMove.down.label, FavoriteMove.down.icon, _can(FavoriteMove.down)),
        const PopupMenuDivider(),
        _menuItem(_MenuAction.remove, 'Remove from favourites', Icons.star_border_rounded, true),
      ],
    );

    return AnimatedContainer(
      duration: fx.motion(J3Durations.fast),
      padding: const EdgeInsets.fromLTRB(J3Space.md, J3Space.sm, 0, J3Space.sm),
      decoration: BoxDecoration(
        color: highlighted || active ? J3Colors.surfaceRaised : J3Colors.inputFill,
        borderRadius: J3Radius.medium,
        border: Border.all(color: borderColor, width: _focus || highlighted ? 2 : 1),
        boxShadow: (active || highlighted || feedback) && fx.glow
            ? [BoxShadow(color: fx.accentColor.withValues(alpha: 0.25), blurRadius: fx.glowBlur(18), spreadRadius: -4)]
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            margin: const EdgeInsets.only(top: J3Space.xs),
            decoration: BoxDecoration(
              color: J3Colors.surface,
              borderRadius: J3Radius.medium,
              border: Border.all(color: fx.accentColor.withValues(alpha: widget.available ? 0.6 : 0.25)),
            ),
            child: Icon(
              t?.icon ?? Icons.help_outline,
              size: 20,
              color: widget.available ? fx.accentText : J3Colors.textDisabled,
            ),
          ),
          const SizedBox(width: J3Space.md),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: J3Space.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '#${(widget.index + 1).toString().padLeft(2, '0')}  ${t?.section.label.toUpperCase() ?? 'UNKNOWN'}',
                    style: J3Type.kicker.copyWith(fontSize: 10, color: J3Colors.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _name,
                    style: J3Type.label.copyWith(color: widget.available ? J3Colors.text : J3Colors.textMuted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: J3Type.caption.copyWith(color: widget.available ? null : J3Colors.warning),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
          if (!feedback)
            Column(mainAxisSize: MainAxisSize.min, children: [handle(), menu()])
          else
            const SizedBox(width: J3Space.md),
        ],
      ),
    );
  }

  PopupMenuItem<_MenuAction> _menuItem(_MenuAction value, String label, IconData icon, bool enabled) =>
      PopupMenuItem<_MenuAction>(
        value: value,
        enabled: enabled,
        child: Row(
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: J3Space.sm),
            Flexible(child: Text(label)),
          ],
        ),
      );

  Widget _feedback(BuildContext context) => SizedBox(
    width: widget.width,
    child: Material(
      type: MaterialType.transparency,
      child: Opacity(opacity: 0.92, child: _card(context, highlighted: true, feedback: true)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final semantics =
        '$_name, favourite ${widget.index + 1} of ${widget.count}.'
        '${widget.available ? '' : ' Not available on this platform.'}';
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => d.data != widget.id,
      onAcceptWithDetails: (d) => widget.onDropFrom(d.data),
      builder: (context, candidates, _) {
        final card = _card(context, highlighted: candidates.isNotEmpty);
        return LongPressDraggable<String>(
          data: widget.id,
          feedback: _feedback(context),
          onDragStarted: () => widget.onDragState(true),
          onDragEnd: (_) => widget.onDragState(false),
          onDraggableCanceled: (_, _) => widget.onDragState(false),
          child: Opacity(
            opacity: widget.dimmed ? 0.35 : 1,
            child: Semantics(
              button: true,
              label: semantics,
              hint: 'Alt plus arrow keys move it',
              child: FocusableActionDetector(
                mouseCursor: widget.available ? SystemMouseCursors.click : SystemMouseCursors.basic,
                onShowHoverHighlight: (h) => setState(() => _hover = h),
                onShowFocusHighlight: (f) => setState(() => _focus = f),
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _MoveIntent(FavoriteMove.left),
                  SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): _MoveIntent(FavoriteMove.right),
                  SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): _MoveIntent(FavoriteMove.up),
                  SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): _MoveIntent(FavoriteMove.down),
                },
                actions: {
                  ActivateIntent: CallbackAction<ActivateIntent>(
                    onInvoke: (_) {
                      _open();
                      return null;
                    },
                  ),
                  _MoveIntent: CallbackAction<_MoveIntent>(
                    onInvoke: (i) {
                      // In one column, left/right behave like up/down.
                      final m = widget.cols == 1
                          ? switch (i.move) {
                              FavoriteMove.left => FavoriteMove.up,
                              FavoriteMove.right => FavoriteMove.down,
                              _ => i.move,
                            }
                          : i.move;
                      widget.onMove(m);
                      return null;
                    },
                  ),
                },
                child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _open, child: card),
              ),
            ),
          ),
        );
      },
    );
  }
}
