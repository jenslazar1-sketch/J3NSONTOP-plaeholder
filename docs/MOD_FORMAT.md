# J3NSONTOP mod package and profile formats

This is the local mod format understood by the Mods section. It is a generic,
documented packaging of file replacements for **your own projects and games
that support file-based mods**. It does not claim to understand any specific
game's native mod system; compatibility is expressed only through the package
manifest.

## Package: `*.j3mod`

A ZIP archive (Stored or Deflate entries only; no encryption, no symlinks)
containing:

```
j3mod.json          required manifest (UTF-8 JSON, <= 1 MiB)
files/...           payload files (any layout; mapped by the manifest)
README.md           optional
preview.png         optional
```

### Manifest `j3mod.json` (formatVersion 1)

```json
{
  "format": "j3mod",
  "formatVersion": 1,
  "id": "neon-hud",
  "name": "Neon HUD",
  "version": "1.2.0",
  "description": "Recolours the HUD in neon red.",
  "author": "J3NSONTOP samples",
  "license": "CC0-1.0",
  "compatibility": {
    "game": "neon-dungeon",
    "gameVersion": ">=1.4.0 <2.0.0"
  },
  "files": [
    { "source": "files/data/ui/hud.json", "target": "data/ui/hud.json" }
  ],
  "dependencies": [ { "id": "core-patch", "version": "^1.0.0" } ],
  "optionalDependencies": [ { "id": "hd-icons", "version": ">=2.0.0" } ],
  "conflicts": [ { "id": "classic-hud", "reason": "Both replace the HUD layout." } ],
  "tags": ["ui"]
}
```

| Field | Rules |
| --- | --- |
| `format` | must be `"j3mod"` |
| `formatVersion` | must be `1`; higher versions are rejected with an explanation |
| `id` | `^[a-z0-9][a-z0-9._-]{1,63}$`, unique in a library |
| `name` | 1-80 characters |
| `version` | semantic version (`MAJOR.MINOR.PATCH[-pre][+build]`) |
| `description`, `author`, `license` | optional strings (description <= 2000 chars) |
| `compatibility.game` | optional game id; must equal the target's game id |
| `compatibility.gameVersion` | optional version constraint (see below) |
| `files` | non-empty; each `source` must be a file in the archive (not `j3mod.json`); each `target` must be a safe relative path; targets are unique within the package (case-insensitive) |
| `dependencies` | required packages: `{id, version?}`; `version` is a constraint, default `any` |
| `optionalDependencies` | used only if present; if present, must satisfy the constraint and are ordered before this package |
| `conflicts` | packages that must not be enabled together: `{id, version?, reason?}` |
| `tags` | optional strings |

Payload files not referenced by `files` produce a warning.

**Version constraints** use Dart/pub syntax: `any`, `1.2.3`, `^1.2.0`,
`>=1.0.0 <2.0.0`, `>1.0.0`, `<=2.1.0`.

### Target identification: `game.json`

A profile's target folder may contain `game.json`:

```json
{ "id": "neon-dungeon", "name": "Neon Dungeon", "version": "1.4.2" }
```

If absent, the profile's own `game` field is used; if neither exists,
compatibility checks for `compatibility.game`/`gameVersion` report "unknown
target" warnings instead of passing silently.

## Profile: `*.j3profile.json`

```json
{
  "format": "j3profile",
  "formatVersion": 1,
  "id": "hardcore-run",
  "name": "Hardcore run",
  "description": "Core patch + hardcore balance + neon HUD.",
  "target": "game",
  "game": { "id": "neon-dungeon", "version": "1.4.2" },
  "mods": [
    { "id": "core-patch", "enabled": true },
    { "id": "hardcore-balance", "enabled": true },
    { "id": "neon-hud", "enabled": false }
  ]
}
```

* `target` - folder relative to the workspace root (`"."` for the root).
* `mods` order is the **application order**: earlier entries are applied first,
  later entries win when several packages write the same target file.
* `game` is optional (overrides/replaces `game.json`).

## Storage inside a workspace

```
<app data>/workspaces/<workspaceId>/meta/
  mods/<id>-<version>.j3mod        imported library (one version per id)
  profiles/<profileId>.j3profile.json
  operations/<operationId>/        journals, staged files and backups
```

## Resolution

For the enabled entries of a profile, in order:

1. every enabled id exists in the library (else **missing package**);
2. every required dependency is enabled, satisfies its version constraint and
   appears **earlier** in the order (else **missing / version mismatch /
   ordered after dependent**; a stable topological "sort by dependencies"
   fix is offered);
3. dependency cycles are reported with the full cycle path;
4. declared `conflicts` between two enabled packages are errors;
5. `compatibility` is checked against the target game id/version;
6. **overlaps** (several packages writing the same target) are reported with
   the winning package (the last one) - allowed, but always shown.

Errors block applying; warnings are shown and must be acknowledged.

## Apply plan, journal, backup and rollback

Before anything is written the user sees the exact plan: for each target file,
`create`, `overwrite` or `unchanged` (identical SHA-256), its size, and the
package that provides it.

Applying creates `operations/<opId>/`:

```
journal.json     status, target root, profile, every change with
                 action, packageId, newSha256, originalSha256, backup path, done
staged/<path>    new content extracted and hash-verified before touching targets
backup/<path>    originals of every file that will be overwritten
```

Statuses: `staging` -> `applying` -> `applied`, or `rolling_back` ->
`rolled_back`; `failed` records the error. The journal is rewritten atomically
after each change so an interrupted run (crash, power loss, app killed) can be
**rolled back** or **resumed** the next time the Mods section opens.

Rollback / restore:

* `overwrite` changes: the backup is restored **only if** the current file
  still has `newSha256`; otherwise it was edited after applying and the user
  chooses: keep their edit, or restore the original (their edited copy is saved
  next to the backup first).
* `create` changes: the file is deleted only if it still has `newSha256`.
* Directories created by the operation are removed only if empty.
* Files not recorded in the journal are never touched.

Only the most recent applied operation on a target can be rolled back; applying
a new profile to a target that has an applied operation asks to roll that back
first.

Mobile (Android/iOS) cannot modify other apps' folders. Profiles there are
applied to an **imported workspace copy** in app storage, and the result is
exported (ZIP or individual files) through the system save dialog/share sheet.
