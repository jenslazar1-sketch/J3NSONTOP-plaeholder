# Architecture

J3NSONTOP BIGGEST MULTITOOL MADE is a single Flutter/Dart codebase for Android,
iOS and Windows (Linux is kept as a development/test target). It is local-first:
no backend, no login, no telemetry, no cloud upload.

## Layers

```
lib/
  main.dart                 bootstrap: data dir, load stores, build registry, runApp
  app/                      app widget, router, tool catalog, app identity
  core/                     shared, feature-agnostic building blocks
    activity/               real operation tracking, history, toasts
    archive/safe_zip.dart   hardened ZIP inspect/extract/create (ONLY zip entry point)
    commands/               typed terminal command interface + tokenizer
    diagnostics/            uncaught-error log
    drafts/                 session-lifetime tool drafts (unfinished work)
    platform/               capability matrix, file access adapter, app paths
    settings/               AppSettings + controller
    storage/                versioned JSON documents, migrations, user data
    tasks/                  cancellation, bounded isolate runner
    text/diff.dart          Myers line diff
    theme/                  colour/type/spacing tokens, effects, Material theme
    tools/                  ToolDefinition, FeatureModule, ToolRegistry
    utils/                  formatting, hashing, text decoding, path safety
    widgets/                the widget kit (import widgets/widgets.dart)
    workspace/              workspace records, active workspace, backup writer
  features/<feature>/
    <feature>_module.dart   registers tools, section landing and terminal commands
    domain/                 pure logic (no Flutter imports where possible)
    data/                   persistence / file IO for the feature
    presentation/           widgets and screens
```

Features never import each other. The only file that imports every feature is
`lib/app/tool_catalog.dart`; the router imports the few top-level screens.

## Adding a built-in tool

1. Implement the page as a widget inside `lib/features/<feature>/presentation/`
   using `ToolScaffold(toolId: ...)`.
2. Add a `ToolDefinition` to that feature's `FeatureModule` with a stable id
   (`<section>.<name>`), name, section, description, keywords, icon, platforms,
   required capabilities and `builder`.
3. That's it: navigation, section hubs, search, the command palette, favourites,
   recents and the terminal `open` command pick it up from the registry.
4. Add unit tests for the logic and a widget test for the page.

## State management

Riverpod 3 (`flutter_riverpod`) without code generation, used consistently:

* `Notifier`/`NotifierProvider` for mutable state, `Provider` for derived values.
* Tool input and results live in **non-autoDispose** providers (or
  `draftTextProvider('<toolId>/<field>')` / `draftValueProvider`) so unfinished
  work survives switching tools. The shell's `ToolHost` additionally keeps the
  10 most recent tool pages alive (offstage, tickers paused).
* Feature-owned persistent data: `featureDataProvider` (namespaced keys), or a
  dedicated `JsonDocumentStore` for larger documents.

## Routing

`go_router` with one `ShellRoute`: `/`, section routes (`/workspaces`, `/mods`,
`/config`, `/assets`, `/files`, `/dev`), `/tools`, `/activity`, `/settings`,
`/about`, `/tool/:id`, and `/intro` outside the shell. The intro is the initial
location only on cold start (unless skipped); it never replays on navigation or
resume. `/intro?replay=1` replays it on request.

## Rules every feature follows

* **Real operations only.** Long or file-changing work goes through
  `activityProvider.notifier.run(...)` / `start(...)`, reporting real progress,
  counts and errors. Decorative terminal text must be visibly cosmetic.
* **No blocking the UI.** CPU-heavy work runs in `Isolate.run`/`compute`, and
  anything that could run away (regex, user-controlled parsing of huge input)
  uses `runBounded` with a time limit. Large inputs are streamed or bounded.
* **Cancellation.** Long loops check a `CancellationToken`.
* **Platform checks** only through `capabilitiesProvider`
  (`caps.supports(Capability.x)`); never `Platform.isX` in feature code. Show
  `caps.alternativeFor(...)` when something is unavailable.
* **File access** only via user-granted scope: `fileAccessProvider`,
  `pickInputFile(...)`, `saveOutput(...)`, workspace roots. Never promise access
  to other apps' data or the unrestricted mobile filesystem.
* **Never overwrite silently.** Writes into a workspace use
  `WorkspaceFileWriter.replaceWithBackup`; new outputs use
  `SafePath.uniquePath`; originals are not replaced by default.
* **Untrusted paths/archives** go through `SafePath` and `SafeZip`.
* **UI kit + tokens.** `J3Colors`, `J3Type`, `J3Space`, `J3Radius` and the
  widgets in `core/widgets`. Status is always icon + text, never colour alone.
  Minimum 44 px targets, tooltips/semantics on icon buttons, visible focus.
  Layouts must work from 320 px wide and at 2x text scale.
* **Effects** read `context.effects` (reduced motion, intensity, glow, sound).

## Storage

All app-owned data lives in the platform application-support directory
(`AppPaths`), or in `--data-dir` for smoke tests:

| File | Content |
| --- | --- |
| `settings.json` | `AppSettings` |
| `userdata.json` | favourites, recent tools, presets, terminal history |
| `history.json` | last 300 finished operations |
| `workspaces.json` | workspace records + active id |
| `features.json` | namespaced feature data (palettes, HTTP history...) |
| `workspaces/<id>/files/` | imported/sample workspace files |
| `workspaces/<id>/meta/` | mod library, profiles, operation journals, backups |

Every JSON document is `{schema, version, savedAt, data}`, written atomically,
loaded with migrations, and damaged files are preserved as
`<name>.corrupt-<timestamp>.json` while defaults are restored (the user is told).

## Testing

* `test/core/**` - core units. `test/features/<feature>/**` - feature units and
  widget tests. `test/helpers/harness.dart` provides `TestEnv` (temp data dir +
  provider overrides), `FakeFileAccess`, `themed()`, `staticEffects`,
  `loadAppFonts()` and `setSurface()`; `test/helpers/raw_zip.dart` crafts
  hostile ZIPs.
* `integration_test/` - end-to-end flows on a real device/desktop.
