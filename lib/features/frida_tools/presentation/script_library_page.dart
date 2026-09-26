import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/frida_scripts.dart';

class ScriptLibraryPage extends ConsumerStatefulWidget {
  const ScriptLibraryPage({super.key});
  static const id = 'frida.scripts';

  @override
  ConsumerState<ScriptLibraryPage> createState() => _ScriptLibraryPageState();
}

class _ScriptLibraryPageState extends ConsumerState<ScriptLibraryPage> {
  FridaScriptCategory _category = FridaScriptCategory.discovery;
  FridaScriptTemplate? _selected;
  String _search = '';

  List<FridaScriptTemplate> get _filtered {
    var scripts = scriptsInCategory(_category);
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      scripts = kFridaScripts.where((s) =>
          s.name.toLowerCase().contains(q) || s.description.toLowerCase().contains(q)).toList();
    }
    return scripts;
  }

  @override
  Widget build(BuildContext context) {
    return ToolScaffold(
      toolId: ScriptLibraryPage.id,
      scrollable: false,
      body: Row(
        children: [
          SizedBox(width: 300, child: _buildSidebar()),
          const VerticalDivider(width: 1, color: J3Colors.border),
          Expanded(child: _buildDetail()),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    final scripts = _filtered;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(J3Space.sm),
          child: TextField(
            style: J3Type.code.copyWith(fontSize: 11),
            decoration: InputDecoration(
              hintText: 'Search scripts...',
              hintStyle: J3Type.code.copyWith(fontSize: 11, color: J3Colors.textMuted),
              prefixIcon: const Icon(Icons.search, size: 16),
              isDense: true,
              contentPadding: const EdgeInsets.all(J3Space.sm),
              filled: true,
              fillColor: J3Colors.inputFill,
              border: OutlineInputBorder(borderRadius: J3Radius.small, borderSide: BorderSide(color: J3Colors.border)),
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        if (_search.isEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: J3Space.sm),
            child: Row(
              children: FridaScriptCategory.values.map((c) => Padding(
                padding: const EdgeInsets.only(right: J3Space.xs),
                child: ChoiceChip(
                  label: Text(c.label, style: J3Type.code.copyWith(fontSize: 10)),
                  selected: _category == c,
                  onSelected: (_) => setState(() { _category = c; _selected = null; }),
                  selectedColor: J3Colors.darkRed,
                  visualDensity: VisualDensity.compact,
                ),
              )).toList(),
            ),
          ),
        const SizedBox(height: J3Space.sm),
        Expanded(
          child: ListView.builder(
            itemCount: scripts.length,
            itemBuilder: (ctx, i) {
              final s = scripts[i];
              final active = _selected?.id == s.id;
              return ListTile(
                dense: true,
                selected: active,
                selectedTileColor: J3Colors.surfaceRaised,
                leading: Icon(_iconForCategory(s.category), size: 16, color: active ? J3Colors.neonText : J3Colors.textMuted),
                title: Text(s.name, style: J3Type.label),
                subtitle: Text(s.description, style: J3Type.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => setState(() => _selected = s),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDetail() {
    if (_selected == null) {
      return const Center(child: EmptyState(title: 'Select a script from the library'));
    }
    final s = _selected!;
    return SingleChildScrollView(
      padding: J3Space.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NeonPanel(
            title: s.name,
            kicker: s.category.label.toUpperCase(),
            icon: _iconForCategory(s.category),
            actions: [
              NeonButton.ghost(label: 'Copy', icon: Icons.copy, dense: true, onPressed: () {
                Clipboard.setData(ClipboardData(text: s.code));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Script copied')));
              }),
              const SizedBox(width: J3Space.xs),
              NeonButton.secondary(label: 'Use in Console', icon: Icons.terminal, dense: true, onPressed: () {}),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.description, style: J3Type.body),
                if (s.requiresArgs) ...[
                  const SizedBox(height: J3Space.sm),
                  Row(
                    children: [
                      Icon(Icons.info_outline, size: 14, color: J3Colors.warning),
                      const SizedBox(width: J3Space.xs),
                      Expanded(child: Text('This script requires parameters — edit the %%PLACEHOLDERS%% before use', style: J3Type.caption.copyWith(color: J3Colors.warning))),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: J3Space.md),
          NeonPanel(
            kicker: 'SOURCE CODE',
            icon: Icons.code,
            emphasis: PanelEmphasis.subtle,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(J3Space.sm),
              decoration: BoxDecoration(
                color: J3Colors.background,
                borderRadius: J3Radius.small,
              ),
              child: SelectableText(
                s.code.trim(),
                style: J3Type.codeSmall,
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconForCategory(FridaScriptCategory cat) => switch (cat) {
    FridaScriptCategory.discovery => Icons.search,
    FridaScriptCategory.hooking => Icons.link,
    FridaScriptCategory.memory => Icons.memory,
    FridaScriptCategory.modding => Icons.games,
    FridaScriptCategory.spawner => Icons.rocket_launch,
    FridaScriptCategory.utility => Icons.build,
  };
}
