import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/effects.dart';
import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/widgets.dart';
import '../data/mod_library.dart';
import 'mods_controller.dart';
import 'mods_flows.dart';
import 'mods_widgets.dart';
import 'package_view.dart';

/// LIBRARY: package cards, import, details drawer, remove.
class LibraryPane extends ConsumerWidget {
  const LibraryPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(modsProvider);
    return NeonPanel(
      kicker: 'LIBRARY',
      title: 'Mod packages (${s.library.length})',
      icon: Icons.inventory_2_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              NeonButton(
                label: 'Import package',
                icon: Icons.add_to_photos_outlined,
                onPressed: s.isBusy ? null : () => importPackageFlow(context, ref),
              ),
            ],
          ),
          const SizedBox(height: J3Space.md),
          if (s.library.isEmpty)
            const EmptyState(
              title: 'No packages yet',
              message:
                  'Import .j3mod packages from your device or from the workspace (for example its downloads/ folder).',
              glyph: '[ .j3mod ]',
            )
          else
            for (final e in s.library) ...[PackageCard(entry: e), const SizedBox(height: J3Space.sm)],
        ],
      ),
    );
  }
}

class PackageCard extends ConsumerStatefulWidget {
  const PackageCard({super.key, required this.entry});
  final LibraryEntry entry;

  @override
  ConsumerState<PackageCard> createState() => _PackageCardState();
}

class _PackageCardState extends ConsumerState<PackageCard> {
  bool _hover = false;

  void _details() {
    final e = widget.entry;
    final usedBy = [for (final p in ref.read(modsProvider).profilesUsing(e.id)) p.name];
    showModsSheet<void>(
      context,
      title: e.name,
      builder: (ctx) => PackageReportView(
        report: e.report,
        usedBy: usedBy,
        footer: [
          NeonButton.danger(
            label: 'Remove from library',
            icon: Icons.delete_outline,
            onPressed: () async {
              Navigator.of(ctx).pop();
              await removePackageFlow(context, ref, e);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final e = widget.entry;
    final r = e.report;
    final m = e.manifest;
    final busy = ref.watch(modsProvider.select((s) => s.isBusy));
    final badge = r.errorCount > 0
        ? StatusBadge(kind: StatusKind.error, text: '${r.errorCount} ERR', dense: true)
        : r.warningCount > 0
        ? StatusBadge(kind: StatusKind.warning, text: '${r.warningCount} WARN', dense: true)
        : const StatusBadge(kind: StatusKind.success, text: 'VALID', dense: true);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: fx.motion(J3Durations.fast),
        padding: const EdgeInsets.all(J3Space.md),
        decoration: BoxDecoration(
          color: _hover ? J3Colors.surfaceHigh : J3Colors.surfaceRaised,
          borderRadius: J3Radius.medium,
          border: Border.all(
            color: r.errorCount > 0
                ? J3Colors.error.withValues(alpha: 0.6)
                : (_hover ? fx.accentColor : J3Colors.border),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.extension_outlined, color: fx.accentText, size: 22),
                const SizedBox(width: J3Space.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.name, style: J3Type.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                      Text('${e.id} ${e.version ?? '?'}', style: J3Type.codeSmall),
                    ],
                  ),
                ),
                const SizedBox(width: J3Space.xs),
                Flexible(child: badge),
              ],
            ),
            const SizedBox(height: J3Space.sm),
            Wrap(
              spacing: J3Space.xs,
              runSpacing: J3Space.xs,
              children: [
                InfoChip(Fmt.count(r.mapped.length, 'file'), icon: Icons.description_outlined),
                InfoChip(Fmt.bytes(r.payloadBytes), icon: Icons.data_usage),
                if (m != null && !m.compatibility.isEmpty)
                  InfoChip('for ${m.compatibility}', icon: Icons.sports_esports_outlined),
                if (m != null)
                  for (final d in m.dependencies)
                    InfoChip('needs $d', icon: Icons.link, color: J3Colors.info, tooltip: 'Required dependency'),
                if (m != null)
                  for (final d in m.optionalDependencies)
                    InfoChip('can use $d', icon: Icons.link_off, tooltip: 'Optional dependency'),
                if (m != null)
                  for (final c in m.conflicts)
                    InfoChip('conflicts ${c.id}', icon: Icons.block, color: J3Colors.error, tooltip: c.reason),
                if (m != null)
                  for (final t in m.tags) InfoChip('#$t', color: fx.accentText),
              ],
            ),
            const SizedBox(height: J3Space.xs),
            Wrap(
              spacing: J3Space.xs,
              runSpacing: J3Space.xs,
              alignment: WrapAlignment.end,
              children: [
                NeonButton.ghost(label: 'Details', icon: Icons.chevron_right, onPressed: _details),
                NeonIconButton(
                  icon: Icons.delete_outline,
                  tooltip: 'Remove ${e.name} from the library',
                  onPressed: busy ? null : () => removePackageFlow(context, ref, e),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
