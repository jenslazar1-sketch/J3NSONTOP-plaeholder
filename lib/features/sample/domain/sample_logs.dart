import 'pixel_canvas.dart';
import 'sample_texts.dart';

/// `game/logs/game.log` and `game/logs/crash-2026-09-01.log`.
class SampleLogs {
  const SampleLogs(this.gameLog, this.crashLog, this.lineCount);
  final String gameLog;
  final String crashLog;
  final int lineCount;
}

class _LogWriter {
  _LogWriter(this.rng);

  final SampleRng rng;
  final List<String> lines = [];

  /// Milliseconds since 2026-09-01 00:00:00.000 (local game time).
  int clock = 12 * 3600 * 1000;

  String get stamp {
    final h = clock ~/ 3600000;
    final m = clock ~/ 60000 % 60;
    final s = clock ~/ 1000 % 60;
    final ms = clock % 1000;
    String two(int v) => v.toString().padLeft(2, '0');
    return '2026-09-01 ${two(h)}:${two(m)}:${two(s)}.${ms.toString().padLeft(3, '0')}';
  }

  void advance(int minMs, int maxMs) => clock += rng.range(minMs, maxMs);

  void log(String level, String subsystem, String message, [List<String> stack = const []]) {
    lines.add('[$stamp] [$level] [$subsystem] $message');
    for (final frame in stack) {
      lines.add('    at $frame');
    }
  }
}

const List<String> _enemies = ['slime', 'bat', 'skeleton', 'skeleton-archer', 'ghoul', 'wraith', 'mimic'];
const List<String> _aiStates = ['idle', 'patrol', 'chase', 'attack', 'flee', 'stunned'];
const List<String> _loot = ['small-potion', 'mana-potion', 'dungeon-key', 'red-gem', 'lucky-coin', 'torch', 'bomb'];
const List<String> _sfx = ['step_stone', 'sword_swing', 'hit_flesh', 'hit_bone', 'coin', 'door_open', 'potion_drink'];
const List<String> _assets = [
  'sprites/hero_walk.png',
  'sprites/items/potion.png',
  'sprites/items/sword.png',
  'textures/tiles/crypt_floor.png',
  'textures/fx/spark_03.png',
  'data/ui/hud.json',
];

/// Builds a ~300 line session log ending in a crash, plus the matching crash
/// report. Fully deterministic (fixed seed, fixed start time).
SampleLogs buildSampleLogs() {
  final w = _LogWriter(SampleRng(0x0DDBA11));
  // Boot.
  w.log('INFO', 'boot', '$sampleGameName $sampleGameVersion (build $sampleGameBuild) starting');
  w.advance(2, 9);
  w.log('DEBUG', 'boot', 'Command line: --lang=en --data=./game');
  w.advance(1, 5);
  w.log('TRACE', 'boot', 'Heap reserved: 512 MiB, job threads: 6');
  w.advance(10, 40);
  w.log('INFO', 'config', 'Loaded config/settings.ini (4 sections, 27 keys)');
  w.advance(1, 4);
  w.log('DEBUG', 'config', 'Display: 1920x1080 borderless @ 144 Hz, vsync on, ui_scale 1.25');
  w.advance(1, 4);
  w.log('WARN', 'config', "settings.ini [Gameplay] 'seed' is empty, using a random dungeon seed");
  w.advance(3, 12);
  w.log('INFO', 'config', 'Loaded config/graphics.json (preset high, bloom on, scanlines on)');
  w.advance(3, 12);
  w.log('INFO', 'config', 'Loaded config/controls.yaml (keyboard + gamepad, alias *look used 2x)');
  w.advance(3, 12);
  w.log('INFO', 'config', 'Loaded config/balance.toml ("Vanilla", 5 enemy types)');
  w.advance(40, 120);
  w.log('INFO', 'render', 'Renderer: NeonGL 4.6 on Neon GFX 3000 (driver 31.0.15)');
  w.advance(5, 20);
  w.log('DEBUG', 'render', 'Swapchain created: 1920x1080, 3 buffers, format RGBA8');
  w.advance(5, 20);
  w.log('DEBUG', 'render', 'Compiled 42 shaders in 318 ms (12 from cache)');
  w.advance(5, 30);
  w.log('INFO', 'audio', 'Audio device: Default (48000 Hz, stereo, 256 frame buffer)');
  w.advance(5, 30);
  w.log('DEBUG', 'input', 'Gamepad connected: Xbox-compatible controller #0');
  w.advance(100, 300);
  w.log('INFO', 'assets', 'Indexed 1284 assets in 312 ms');
  w.advance(2, 10);
  w.log('DEBUG', 'assets', 'Atlas sprites/hero_walk.png: 8 frames of 32x32');
  w.advance(2, 10);
  w.log('INFO', 'mods', 'Mods folder scanned: 0 packages enabled (vanilla)');
  w.advance(10, 40);
  w.log('INFO', 'save', 'Save slots: 1 = valid, 2 = empty, 3 = damaged');
  w.advance(1, 5);
  w.log('ERROR', 'save', 'Failed to read saves/slot3.json: unexpected end of JSON input at line 41, column 3', [
    'JsonReader.expect (core/json_reader.nd:188)',
    'SaveSystem.readSlot (save/save_system.nd:212)',
    'SaveSystem.scanSlots (save/save_system.nd:97)',
    'Game.boot (core/game.nd:64)',
  ]);
  w.advance(5, 20);
  w.log('INFO', 'save', 'Loaded saves/slot1.json (J3NSONTOP, necromancer, level 14, floor 6)');
  w.advance(200, 900);
  w.log('INFO', 'ui', 'Main menu shown');
  w.advance(2000, 5000);
  w.log('INFO', 'ui', 'Continue pressed');
  w.advance(100, 400);
  w.log('INFO', 'world', 'Entering floor 6: The Humming Crypt (seed 0x5EED0006)');

  // Gameplay.
  var frame = 1200;
  var nextId = 101;
  final alive = <String>[];
  var room = 1;
  var scripted = 0;
  while (w.lines.length < 288) {
    w.advance(30, 4200);
    frame += w.rng.range(20, 600);
    if (alive.length < 3 || w.rng.chance(0.08)) {
      final e = '${w.rng.pick(_enemies)}#${nextId++}';
      alive.add(e);
      w.log('DEBUG', 'world', 'Spawned $e at (${w.rng.range(2, 60)},${w.rng.range(2, 40)})');
      continue;
    }
    final roll = w.rng.nextInt(100);
    final e = w.rng.pick(alive);
    if (roll < 14) {
      w.log('TRACE', 'physics', 'tick $frame: ${w.rng.range(20, 90)} bodies, ${w.rng.range(0, 14)} contacts');
    } else if (roll < 22) {
      w.log(
        'TRACE',
        'render',
        'frame $frame: ${w.rng.range(3, 6)}.${w.rng.range(0, 9)} ms, ${w.rng.range(180, 420)} draw calls',
      );
    } else if (roll < 27) {
      w.log('TRACE', 'input', 'move axis = (${w.rng.range(-10, 10) / 10}, ${w.rng.range(-10, 10) / 10})');
    } else if (roll < 38) {
      final from = w.rng.pick(_aiStates);
      var to = w.rng.pick(_aiStates);
      if (to == from) to = 'chase';
      w.log('DEBUG', 'ai', '$e state $from -> $to');
    } else if (roll < 45) {
      w.log('DEBUG', 'audio', 'play sfx/${w.rng.pick(_sfx)}.ogg (voice ${w.rng.range(1, 32)})');
    } else if (roll < 50) {
      w.log('DEBUG', 'assets', 'cache hit ${w.rng.pick(_assets)}');
    } else if (roll < 63) {
      final dmg = w.rng.range(3, 24);
      final crit = w.rng.chance(0.15);
      w.log('INFO', 'combat', '$e hit for $dmg${crit ? ' (CRIT)' : ''}');
    } else if (roll < 71) {
      alive.remove(e);
      w.log('INFO', 'combat', '$e defeated (+${w.rng.range(4, 40)} XP)');
    } else if (roll < 77) {
      w.log('INFO', 'loot', 'Picked up ${w.rng.pick(_loot)} x${w.rng.range(1, 3)}');
    } else if (roll < 81) {
      room++;
      w.log('INFO', 'world', 'Entered room $room of floor 6');
    } else if (roll < 84) {
      w.log('INFO', 'save', 'Autosave to slot 1 (${w.rng.range(90, 420)} ms)');
    } else if (roll < 89) {
      w.log('WARN', 'render', 'Frame $frame took ${w.rng.range(18, 64)}.${w.rng.range(0, 9)} ms (budget 6.9 ms)');
    } else if (roll < 92) {
      w.log('WARN', 'audio', 'Buffer underrun (${w.rng.range(64, 512)} samples)');
    } else if (roll < 95) {
      w.log('WARN', 'ai', 'Path search for $e gave up after ${w.rng.range(900, 4096)} nodes');
    } else if (scripted == 0) {
      scripted++;
      w.log('ERROR', 'audio', 'Failed to decode sfx/lich_laugh.ogg: invalid Vorbis header', [
        'VorbisDecoder.open (audio/vorbis.nd:77)',
        'SoundBank.load (audio/sound_bank.nd:140)',
        'AudioSystem.preload (audio/audio_system.nd:58)',
      ]);
    } else if (scripted == 1) {
      scripted++;
      w.log('ERROR', 'script', "Unhandled error in scripts/traps/room_12.nds: attempt to index nil value 'lever'", [
        'room_12.onEnter (scripts/traps/room_12.nds:23)',
        'ScriptVm.call (script/vm.nd:301)',
        'World.enterRoom (world/world.nd:412)',
      ]);
    } else if (scripted == 2) {
      scripted++;
      w.log('WARN', 'save', 'Autosave took 812 ms (limit 500 ms); disk may be slow');
    } else {
      w.log('WARN', 'assets', 'Missing texture textures/fx/spark_0${w.rng.range(4, 9)}.png, using fallback');
    }
  }

  // The crash.
  w.advance(500, 1500);
  w.log('WARN', 'render', 'GPU did not respond for 2000 ms, attempting recovery');
  w.advance(1500, 2500);
  w.log('ERROR', 'render', 'Device reset failed: NGL_DEVICE_LOST (0x887A0005)');
  w.advance(1, 5);
  final crashStamp = w.stamp;
  final tail = List<String>.of(w.lines.sublist(w.lines.length - 10));
  const crashStack = [
    'RenderDevice.present (render/device.nd:512)',
    'Renderer.endFrame (render/renderer.nd:233)',
    'Game.frame (core/game.nd:130)',
    'Game.run (core/game.nd:88)',
    'main (core/main.nd:12)',
  ];
  w.log('FATAL', 'render', 'GPU device lost (reason: TDR timeout) while presenting frame $frame', crashStack);
  w.advance(5, 20);
  w.log('FATAL', 'boot', 'Crash report written to logs/crash-2026-09-01.log');
  w.advance(5, 20);
  w.log('INFO', 'boot', 'Shutting down (exit code 3)');
  final gameLog = '${w.lines.join('\n')}\n';

  final uptimeSec = (w.clock - 12 * 3600 * 1000) ~/ 1000;
  String two(int v) => v.toString().padLeft(2, '0');
  final uptime = '${two(uptimeSec ~/ 3600)}:${two(uptimeSec ~/ 60 % 60)}:${two(uptimeSec % 60)}';
  final crash = StringBuffer()
    ..writeln('==============================================================')
    ..writeln(' NEON DUNGEON CRASH REPORT')
    ..writeln('==============================================================')
    ..writeln('Game:       $sampleGameName $sampleGameVersion (build $sampleGameBuild)')
    ..writeln('Time:       $crashStamp (local)')
    ..writeln('Session:    8f3a1c2e')
    ..writeln('Uptime:     $uptime')
    ..writeln('Exception:  GpuDeviceLostError: GPU device lost (reason: TDR timeout)')
    ..writeln('Thread:     render (id 7)')
    ..writeln()
    ..writeln('Stack trace (most recent call first):');
  for (var i = 0; i < crashStack.length; i++) {
    crash.writeln('  #$i  ${crashStack[i]}');
  }
  crash
    ..writeln()
    ..writeln("Caused by: ShaderCompileError: postfx/bloom.frag:41: 'threshhold' undeclared identifier")
    ..writeln('  #0  ShaderCache.compile (render/shader_cache.nd:96)')
    ..writeln('  #1  PostFx.rebuild (render/postfx.nd:61)')
    ..writeln('  #2  Renderer.applySettings (render/renderer.nd:118)')
    ..writeln()
    ..writeln('Other threads:')
    ..writeln('  [main]    waiting   Game.tick (core/game.nd:130)')
    ..writeln('  [audio]   running   AudioMixer.mix (audio/mixer.nd:77)')
    ..writeln('  [loader]  idle')
    ..writeln('  [jobs x6] idle')
    ..writeln()
    ..writeln('System:')
    ..writeln('  OS:       Fictional OS 11 (x64)')
    ..writeln('  CPU:      8 cores @ 3.6 GHz')
    ..writeln('  GPU:      Neon GFX 3000 (driver 31.0.15, 8192 MiB)')
    ..writeln('  RAM:      16384 MiB total, 5120 MiB used by the game')
    ..writeln('  Display:  1920x1080 @ 144 Hz, borderless')
    ..writeln()
    ..writeln('Configuration:')
    ..writeln('  config/settings.ini   config_version 3, difficulty normal')
    ..writeln('  config/graphics.json  preset high, bloom on (threshold 0.8)')
    ..writeln('  Loaded mods:          (none)')
    ..writeln()
    ..writeln('Last 10 log lines before the crash:');
  for (final l in tail) {
    crash.writeln('  $l');
  }
  crash
    ..writeln()
    ..writeln('Please attach this file when reporting the problem. (Neon Dungeon is fictional;')
    ..writeln('this report was generated as sample data by J3NSONTOP.)');
  return SampleLogs(gameLog, crash.toString(), w.lines.length);
}
