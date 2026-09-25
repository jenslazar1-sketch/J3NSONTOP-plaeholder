import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/platform/capabilities.dart';
import '../../core/storage/user_data.dart';
import '../../core/theme/j3_spacing.dart';
import '../../core/tools/tool_registry.dart';
import '../../core/widgets/widgets.dart';

/// Keeps recently used tool pages alive so unfinished work (inputs,
/// results, scroll position, running previews) survives switching between
/// tools and sections. Inactive tools are offstage with tickers disabled.
class ToolHost extends ConsumerStatefulWidget {
  const ToolHost({super.key, required this.activeToolId});

  /// Null when the current route is not a tool route.
  final String? activeToolId;

  static const int keepAlive = 10;

  @override
  ConsumerState<ToolHost> createState() => _ToolHostState();
}

class _ToolHostState extends ConsumerState<ToolHost> {
  final List<String> _alive = [];

  @override
  void initState() {
    super.initState();
    _activate(widget.activeToolId);
  }

  @override
  void didUpdateWidget(ToolHost old) {
    super.didUpdateWidget(old);
    if (old.activeToolId != widget.activeToolId) {
      FocusManager.instance.primaryFocus?.unfocus();
      _activate(widget.activeToolId);
    }
  }

  void _activate(String? id) {
    if (id == null) return;
    _alive.remove(id);
    _alive.insert(0, id);
    while (_alive.length > ToolHost.keepAlive) {
      _alive.removeLast();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(toolRegistryProvider).byId(id) != null) {
        ref.read(userDataProvider.notifier).recordToolOpened(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.activeToolId;
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final id in _alive)
          Offstage(
            key: ValueKey('host-$id'),
            offstage: id != active,
            child: TickerMode(
              enabled: id == active,
              child: FocusScope(
                canRequestFocus: id == active,
                child: _ToolPage(toolId: id),
              ),
            ),
          ),
      ],
    );
  }
}

class _ToolPage extends ConsumerWidget {
  const _ToolPage({required this.toolId});
  final String toolId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(toolRegistryProvider);
    final caps = ref.watch(capabilitiesProvider);
    final tool = registry.byId(toolId);
    if (tool == null) {
      return EmptyState(
        title: 'Unknown tool "$toolId"',
        message: 'This tool does not exist in this version.',
        glyph: '[ ?_? ]',
        action: NeonButton(label: 'Go home', icon: Icons.home, onPressed: () => context.go('/')),
      );
    }
    if (!tool.availableOn(caps)) {
      final missing = tool.requiredCapabilities.where((c) => !caps.supports(c)).toList();
      return Padding(
        padding: J3Space.pagePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StatusBanner(
              kind: StatusKind.info,
              title: '${tool.name} is not available on ${caps.platform.label}',
              message: missing.isEmpty
                  ? 'This tool is not supported on this platform.'
                  : missing.map((c) => '${c.label}: ${caps.alternativeFor(c) ?? 'not supported here.'}').join('\n'),
            ),
          ],
        ),
      );
    }
    return tool.builder(context);
  }
}
