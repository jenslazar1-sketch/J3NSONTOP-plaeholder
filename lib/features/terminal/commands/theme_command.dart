import '../../../core/commands/terminal_command.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../core/theme/j3_colors.dart';
import 'command_support.dart';

/// `theme ...`: reads and changes the visual settings (persisted like the
/// Settings page does).
class ThemeCommand extends TerminalCommand {
  const ThemeCommand();

  static const List<String> subcommands = [
    'show',
    'accent',
    'effects',
    'intensity',
    'scanlines',
    'particles',
    'glow',
    'motion',
  ];
  static const List<String> _switches = ['on', 'off'];

  @override
  String get name => 'theme';

  @override
  String get summary => 'Show or change accent, effects and motion';

  @override
  String get usage =>
      'theme [show] | theme accent <neon|crimson|infrared|ember> | theme effects <low|full> | '
      'theme intensity <0-100> | theme scanlines|particles|glow <on|off> | theme motion <system|reduced|full>';

  @override
  List<CommandArg> get args => const [
    CommandArg('setting', 'What to show or change', optional: true, values: subcommands),
    CommandArg('value', 'New value for the setting (see usage)', optional: true),
  ];

  @override
  List<String> get examples => const [
    'theme',
    'theme accent crimson',
    'theme effects low',
    'theme intensity 40',
    'theme scanlines off',
    'theme motion reduced',
  ];

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    final sub = (args.at(0) ?? 'show').toLowerCase();
    final value = args.at(1)?.toLowerCase();
    final controller = ctx.read(settingsProvider.notifier);
    final current = ctx.read(settingsProvider);

    Future<CommandResult> apply(AppSettings Function(AppSettings s) change, String message) async {
      await controller.update(change);
      final s = ctx.read(settingsProvider);
      return CommandResult.ok([
        TermLine.ok('OK: $message'),
        if (s.lowEffects && const {'scanlines', 'particles', 'glow', 'intensity'}.contains(sub))
          TermLine.dim('Low-effects mode is on, so this stays off until `theme effects full`.'),
      ]);
    }

    CommandResult invalid(String what, List<String> allowed) => CommandResult.error(
      value == null ? '`theme $sub` needs a value: ${allowed.join('|')}.' : '"$value" is not a valid $what.',
      usage: 'theme $sub <${allowed.join('|')}>',
    );

    switch (sub) {
      case 'show':
        return CommandResult.ok(_show(current));
      case 'accent':
        final preset = AccentPreset.values.where((p) => p.name == value).firstOrNull;
        if (preset == null) return invalid('accent', [for (final p in AccentPreset.values) p.name]);
        return apply((s) => s.copyWith(accent: preset), 'accent set to ${preset.label} (${preset.name}).');
      case 'effects':
        final low = switch (value) {
          'low' => true,
          'full' => false,
          _ => null,
        };
        if (low == null) return invalid('effects mode', const ['low', 'full']);
        return apply(
          (s) => s.copyWith(lowEffects: low),
          low ? 'low-effects mode on (no scanlines, particles, bloom or glitches).' : 'full effects restored.',
        );
      case 'intensity':
        final n = int.tryParse(value ?? '');
        if (n == null || n < 0 || n > 100) return invalid('intensity (0-100)', const ['0-100']);
        return apply((s) => s.copyWith(intensity: n / 100), 'effect intensity set to $n%.');
      case 'scanlines' || 'particles' || 'glow':
        final on = parseSwitch(value);
        if (on == null) return invalid('switch', _switches);
        return apply(
          (s) => switch (sub) {
            'scanlines' => s.copyWith(scanlines: on),
            'particles' => s.copyWith(particles: on),
            _ => s.copyWith(glow: on),
          },
          '$sub ${on ? 'on' : 'off'}.',
        );
      case 'motion':
        final pref = MotionPreference.values.where((m) => m.name == value).firstOrNull;
        if (pref == null) return invalid('motion preference', [for (final m in MotionPreference.values) m.name]);
        return apply((s) => s.copyWith(motion: pref), 'motion set to ${pref.name} (${pref.label}).');
      default:
        return CommandResult.error('Unknown theme setting "$sub".', usage: 'theme <${subcommands.join('|')}> [value]');
    }
  }

  List<TermLine> _show(AppSettings s) {
    String sw(bool v) => v ? 'on' : 'off';
    return [
      const TermLine('THEME', TermStyle.accent),
      TermLine('  accent      ${s.accent.label} (${s.accent.name})'),
      TermLine('  effects     ${s.lowEffects ? 'low' : 'full'}'),
      TermLine('  intensity   ${(s.intensity * 100).round()}%'),
      TermLine('  scanlines   ${sw(s.scanlines)}'),
      TermLine('  particles   ${sw(s.particles)}'),
      TermLine('  glow        ${sw(s.glow)}'),
      TermLine('  motion      ${s.motion.name} (${s.motion.label})'),
      if (s.lowEffects) TermLine.dim('Low-effects mode overrides scanlines, particles, glow and intensity.'),
      TermLine.dim('Change with e.g. `theme accent crimson`. Settings page: `open settings`.'),
    ];
  }

  @override
  List<String> complete(CommandContext ctx, List<String> typedArgs) {
    if (typedArgs.length <= 1) return subcommands;
    if (typedArgs.length > 2) return const [];
    return switch (typedArgs.first.toLowerCase()) {
      'accent' => [for (final p in AccentPreset.values) p.name],
      'effects' => const ['low', 'full'],
      'intensity' => const ['0', '25', '50', '75', '100'],
      'scanlines' || 'particles' || 'glow' => _switches,
      'motion' => [for (final m in MotionPreference.values) m.name],
      _ => const [],
    };
  }
}
