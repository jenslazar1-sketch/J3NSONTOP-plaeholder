import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/activity/activity_controller.dart';
import '../../core/theme/effects.dart';
import '../../core/theme/j3_colors.dart';
import '../../core/theme/j3_spacing.dart';
import '../../core/theme/j3_typography.dart';
import '../../core/widgets/status.dart';

/// Readable operation notifications. Shows up to three toasts; each has an
/// icon, a text status label and a close button. Errors stay longer.
class ToastOverlay extends ConsumerWidget {
  const ToastOverlay({super.key, required this.alignment});

  final Alignment alignment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notices = ref.watch(activityProvider.select((s) => s.notices));
    final visible = notices.length > 3 ? notices.sublist(notices.length - 3) : notices;
    final width = MediaQuery.sizeOf(context).width;
    return SafeArea(
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.all(J3Space.lg),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width < 480 ? width - 32 : 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final n in visible) _Toast(key: ValueKey(n.id), notice: n)],
            ),
          ),
        ),
      ),
    );
  }
}

class _Toast extends ConsumerStatefulWidget {
  const _Toast({super.key, required this.notice});
  final Notice notice;

  @override
  ConsumerState<_Toast> createState() => _ToastState();
}

class _ToastState extends ConsumerState<_Toast> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final seconds = switch (widget.notice.kind) {
      NoticeKind.error => 9,
      NoticeKind.warning => 7,
      _ => 4,
    };
    _timer = Timer(Duration(seconds: seconds), _dismiss);
  }

  void _dismiss() {
    if (!mounted) return;
    ref.read(activityProvider.notifier).dismissNotice(widget.notice.id);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kind = switch (widget.notice.kind) {
      NoticeKind.success => StatusKind.success,
      NoticeKind.info => StatusKind.info,
      NoticeKind.warning => StatusKind.warning,
      NoticeKind.error => StatusKind.error,
    };
    final fx = context.effects;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: fx.motion(const Duration(milliseconds: 220)),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 12), child: child),
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: J3Space.sm),
        child: Semantics(
          liveRegion: true,
          child: Material(
            color: J3Colors.surfaceRaised,
            shape: RoundedRectangleBorder(
              borderRadius: J3Radius.medium,
              side: BorderSide(color: kind.color.withValues(alpha: 0.8)),
            ),
            elevation: 6,
            shadowColor: kind.color.withValues(alpha: 0.4),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(J3Space.md, J3Space.sm, J3Space.xs, J3Space.sm),
              child: Row(
                children: [
                  Icon(kind.icon, color: kind.color, size: 20),
                  const SizedBox(width: J3Space.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(kind.label, style: J3Type.codeSmall.copyWith(color: kind.color)),
                        Text(widget.notice.message, style: J3Type.bodySecondary.copyWith(color: J3Colors.text), maxLines: 4, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  IconButton(tooltip: 'Dismiss', onPressed: _dismiss, icon: const Icon(Icons.close, size: 18)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
