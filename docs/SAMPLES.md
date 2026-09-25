# Sample workspace: NEON DUNGEON

On first run the app creates a disposable **sample workspace** (kind `sample`)
with real files so every tool can be tried immediately. It can be reset or
removed at any time. The same content is exported to `samples/` in the repo by
`dart run tool/export_samples.dart`.

"Neon Dungeon" is a fictional game invented for these samples.

```
README.txt
game/
  game.json                        {"id":"neon-dungeon","name":"Neon Dungeon","version":"1.4.2"}
  config/settings.ini              INI with [Display] [Audio] [Gameplay], ; and # comments
  config/graphics.json             nested JSON (resolution, quality, vsync, fov, postfx...)
  config/controls.yaml             YAML key bindings with comments
  config/balance.toml              TOML: [player], [economy], [[enemies]] tables
  data/items.csv                   ~20 items: id,name,type,damage,price,rarity
  data/enemies.tsv                 tab-separated enemy table
  data/ui/hud.json                 HUD layout/colours
  data/localization/en.json        UI strings
  saves/slot1.json                 documented save file
  saves/save.schema.json           schema for the save-data editor
  sprites/hero_walk.png            128x64 sprite sheet, 4x2 frames of 32x32 (8 frames)
  sprites/items/*.png              32x32 RGBA icons: potion, sword, shield, key, gem, skull
  textures/logo.png                256x128 RGBA with transparency
  logs/game.log                    ~300 lines mixing TRACE/DEBUG/INFO/WARN/ERROR/FATAL
  logs/crash-2026-09-01.log        stack-trace style crash log
downloads/                         the sample packages as files (importable)
  core-patch-1.0.0.j3mod
  neon-hud-1.2.0.j3mod             depends on nothing; restyles data/ui/hud.json
  hardcore-balance-2.0.1.j3mod     depends on core-patch ^1.0.0; edits config/balance.toml, data/items.csv
  brutal-mode-0.9.0.j3mod          ALSO edits config/balance.toml -> intentional overlap with hardcore-balance
  legacy-skin-0.3.0.j3mod          requires "retro-core" which does not exist -> missing dependency demo
  cycle-a-1.0.0.j3mod / cycle-b-1.0.0.j3mod   depend on each other -> cycle demo
duplicates/                        exact copies of some files for the duplicate finder
rename-demo/                       IMG_0001.png ... files for batch rename
notes/todo.md
notes/unicode-名前-ünïcødé.txt      Unicode file name demo
```

Pre-imported into the workspace's mod library (`meta/mods/`), with profiles in
`meta/profiles/`:

| Profile | Mods (in order) | Demonstrates |
| --- | --- | --- |
| `vanilla-plus` "Vanilla+ HUD" | neon-hud | simple apply/rollback |
| `hardcore-run` "Hardcore run" | core-patch, hardcore-balance, neon-hud | dependencies |
| `conflict-demo` "Conflict demo" | core-patch, hardcore-balance, brutal-mode | overlapping file changes (brutal-mode wins) |
| `broken-deps` "Broken dependencies" | legacy-skin, cycle-a, cycle-b | missing dependency + cycle errors |

All profiles target `game`.

## Save schema subset

`saves/save.schema.json` uses a documented subset of JSON Schema (draft-07
keywords): `type` (object, array, string, integer, number, boolean), `title`,
`description`, `properties`, `required`, `additionalProperties` (boolean),
`items`, `minimum`, `maximum`, `minLength`, `maxLength`, `pattern`, `enum`,
`default`.
