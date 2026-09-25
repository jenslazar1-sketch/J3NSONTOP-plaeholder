# Neon Dungeon modding - to do

- [x] Back up the original `game/` folder (the Mods section does this for every apply)
- [x] Import the seven sample packages into the library
- [ ] Apply **Vanilla+ HUD** and compare `data/ui/hud.json` before/after
- [ ] Run **Hardcore run** and check that `core-patch` is applied first
- [ ] Try **Conflict demo** - who wins `config/balance.toml`?
- [ ] Look at **Broken dependencies**: `retro-core` does not exist, and `cycle-a` / `cycle-b` need each other
- [ ] Convert `config/controls.yaml` to JSON and find out what happened to `*look`
- [ ] Validate `saves/slot1.json` against `saves/save.schema.json`
- [ ] Set player gold to 1000000 and watch the validator complain (maximum is 999999)
- [ ] Slice `sprites/hero_walk.png` into 8 frames and preview the walk cycle
- [ ] Find the exact duplicates in `duplicates/` (one file only *looks* identical)
- [ ] Batch rename `rename-demo/` to `neon-shot-###.png`
- [ ] Find the first ERROR in `logs/game.log` and the root cause of the crash

## Notes

| What | Where |
| --- | --- |
| Game id / version | `game/game.json` -> neon-dungeon 1.4.2 |
| Mod library | workspace meta folder (managed by the Mods section) |
| Profiles | Vanilla+ HUD, Hardcore run, Conflict demo, Broken dependencies |

> Everything in this workspace is fictional and disposable. Reset it any time.
