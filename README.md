# J3NSONTOP BIGGEST MULTITOOL MADE

```

A local-first multitool for **harmless modding** of your own projects and games
that support mods, asset preparation, configuration editing, file utilities and
everyday developer tasks — wrapped in a black-and-neon-red terminal aesthetic
with an animated, laughing ASCII skull.

* One Flutter/Dart codebase for **Android**, **iOS** and **Windows** (Linux is
  kept as a development/test target).
* Application id `com.j3nsontop.multitool` · short name **J3NSONTOP Multitool** ·
  version `1.0.0` (build 1).
* No login, no telemetry, no cloud upload. The network is only used when you
  press *Send* in the HTTP developer tool.
* Scope: user-controlled files, supported game mod workflows, backups, asset
  tools and development utilities. It does **not** access other apps' data or
  credentials, and it has nothing to do with anti-cheat systems or multiplayer
  cheating.

## Status

Version 1.0.0, ready for testing. **Testers: start with
[docs/TESTING.md](docs/TESTING.md)** (downloads, install steps, a 120-case
checklist and how to report problems).

Last full verification: commit `ad22533`, CI run
[#16](https://github.com/jenslazar1-sketch/J3NSONTOP-plaeholder/actions/runs/36228807116)
(build label `ci16-ad22533`) — all 7 jobs passed.

| Check | Result |
| --- | --- |
| Formatting, analyzer | clean |
| Unit and widget tests | 1318 passed |
| Integration tests, Linux desktop (xvfb) | 3 of 3 passed |
| Linux release bundle smoke test | passed (every section and all 43 tools render) |
| Android test APK | built, apksigner-verified (shared public test key), 16 KB page alignment OK |
| Android emulator, API 34 x86_64 | test APK installs, stays running, survives a relaunch; integration tests 3 of 3 |
| Windows x64 | portable ZIP and setup EXE built and verified |
| Windows clean machine (no Flutter) | portable smoke test and install/uninstall passed |
| iOS unsigned compile check | Runner.app compiles (not installable, not an IPA) |
| iOS Simulator, iPhone 17 Pro, iOS 26.5 | app installs, stays running, survives a relaunch; integration tests 3 of 3; that app is packaged for testers |

Test builds of that run (Actions > run #16 > Artifacts; kept 30 days;
SHA-256 of the files inside):

| File | SHA-256 |
| --- | --- |
| `J3NSONTOP-Multitool-1.0.0-android-test-debugsigned.apk` | `f9de9d11f66b2a9236385b5ef5aedabd44e3f2d5d8feb3bec3f0d562409e0162` |
| `J3NSONTOP-Multitool-1.0.0-windows-x64-portable.zip` | `4069aa4a03b56a0a892959e7dbb2c5ac4bd833c3d7697dc66f4f1196aa23fc6a` |
| `J3NSONTOP-Multitool-1.0.0-windows-x64-setup.exe` | `1fd8337044fa1a26626e6bfe0495b38406a18faa254702b09af92b90233892be` |
| `J3NSONTOP-Multitool-1.0.0-ios-simulator-debug.zip` (Simulator only, x86_64 + arm64) | `3c5751ef96600b74067d5f0f0f990e1f2305c62b5ff7042c200804207199ce91` |

Not produced yet: a release-signed Android APK/AAB and a signed IPA need
the secrets listed under [Signing](#signing) and are built by the manual
**Release** workflow. The Windows binaries are not Authenticode-signed
(no certificate configured), so SmartScreen may warn; compare the checksum
before running.

## Contents

- [Features](#features)
- [Platform capability matrix](#platform-capability-matrix)
- [Getting started](#getting-started)
- [Everyday use](#everyday-use)
- [Building locally](#building-locally)
- [CI and releases](#ci-and-releases)
- [Signing](#signing)
- [Supported formats](#supported-formats)
- [Architecture and adding a tool](#architecture-and-adding-a-tool)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Credits and licences](#credits-and-licences)

## Features

**Launch.** An original ASCII skull (cranium and jaw are separate, column-aligned
text layers) plays a ~4 s intro: darkness, a red signal flicker, a scanline
reveal, three laughs where the jaw and chin really drop and close, a short glitch
burst, then the full title and `J3NSONTOP SYSTEM ONLINE`. *Skip* is visible from
the first frame (Esc/Enter/Space work too), "Skip intro on launch" persists, the
optional synthesized laugh only plays when sound is enabled (instant mute), and
reduced motion shows a still version. The intro never replays on navigation or
resume; *Replay intro* is in Settings, About and the command palette.

**Shell.** Desktop: left navigation rail, top search (Ctrl+K command palette),
workspace switcher and a live activity panel (Ctrl+J). Tablets: compact rail.
Phones: bottom navigation, drawer, safe areas. The 10 most recently used tool
pages stay alive, so unfinished work survives switching tools. Real operations
(never decorative ones) are tracked with progress, cancel, history and toasts.

**Workspaces.** Link a folder (Windows/Linux) or import files, folders or a ZIP
as an app-owned copy (all platforms). Removing a record never deletes a linked
folder; imported copies are deleted only when you explicitly tick that option.

**Mods.** A documented package format (`.j3mod` = ZIP + `j3mod.json`), a library,
load-order profiles, dependency/cycle/conflict/compatibility checks, overlap
reports, an exact change plan, journaled apply with backups, resume or roll back
after interruption, and rollback that detects your later edits. Archives are
validated before extraction (traversal, absolute paths, symlinks, duplicates,
limits, CRC). On phones profiles apply to an imported copy that you export.

**Sample workspace.** On first run the app generates "NEON DUNGEON", a fictional
game with configs, saves + schema, sprites, logs, 7 mod packages and 4 profiles
(including an intentional overlap, a missing dependency and a cycle), so every
tool can be tried immediately. The same content is in [`samples/`](samples/).

### All tools

| Section | Tool | ID | What it does |
| --- | --- | --- | --- |
| Workspaces | Workspace Manager | `workspaces.manager` | Create, link, import (files, folder, ZIP), switch, export and remove workspaces. |
| Workspaces | File Browser | `workspaces.browser` | Browse workspace files: details, SHA-256, rename, new folder, export and a restorable trash. |
| Workspaces | Text Editor | `workspaces.editor` | Edit text and config files keeping encoding and line endings; find, go to line, backups on save. |
| Workspaces | Hex Viewer | `workspaces.hex` | Inspect any file byte by byte with paged reads, jump to offset and hex/text pattern search. |
| Workspaces | Find Files | `workspaces.find_files` | Find files by name with substring, glob (**/*.json) or regex patterns. |
| Workspaces | Search in Files | `workspaces.search_text` | Search file contents (plain or regex, whole word, glob filter) with results grouped by file. |
| Workspaces | Batch Rename | `workspaces.batch_rename` | Rename many files with find/replace, numbering and case rules; live preview, collisions and undo. |
| Workspaces | Replace in Files | `workspaces.replace` | Find and replace across files with a diff preview, per-file selection and automatic backups. |
| Mods | Mod Manager | `mods.manager` | Library, load-order profiles, dependency checks, apply plans with backups, rollback and journals. |
| Mods | Mod Package Inspector | `mods.inspector` | Check any .j3mod without importing it: archive safety, manifest rules, file mapping and issues. |
| Mods | Mod Package Builder | `mods.builder` | Create a .j3mod from workspace or device files with live manifest validation. |
| Config Lab | JSON Studio | `config.json` | Validate with exact line:column, format, minify, sort keys, browse and edit as a tree, search fields. |
| Config Lab | YAML Editor | `config.yaml` | Validate YAML, browse the parsed tree, convert YAML to JSON and JSON to verified YAML. |
| Config Lab | TOML Editor | `config.toml` | Validate TOML, browse tables, convert TOML to JSON and JSON to verified TOML. |
| Config Lab | INI Editor | `config.ini` | Lossless INI editing: change values line by line, detect duplicates, convert to and from JSON. |
| Config Lab | CSV / TSV Table | `config.csv` | Preview delimited tables, detect delimiters, find ragged rows, filter, and convert CSV, TSV and JSON. |
| Config Lab | Config Compare | `config.compare` | Semantic diff of two configs (JSON, YAML, TOML, INI) plus a unified or side-by-side text diff. |
| Config Lab | Config Presets | `config.presets` | JSON Merge Patch presets: preview the changes on a document, then save with a backup. |
| Config Lab | Save Data Editor | `config.save_editor` | Edit JSON save files through a form generated from their JSON schema, with live validation. |
| Asset Lab | Image Studio | `assets.image` | Inspect, resize, crop, rotate and flip images non-destructively, then export to PNG, JPEG, WebP... |
| Asset Lab | Sprite Sheet | `assets.sprites` | Cut sprite sheets on a grid, preview the animation and export frames or an animated GIF. |
| Asset Lab | Atlas Packer | `assets.atlas` | Pack images into a texture atlas PNG with a validated j3atlas JSON index. |
| Asset Lab | Color Lab | `assets.color` | HSV picker, HEX/RGB/HSL/HSV conversion, WCAG contrast, eyedropper and saved palettes. |
| Asset Lab | App Icon Export | `assets.icons` | Generate and verify Android, Google Play, iOS and Windows app icons from one artwork. |
| File Tools | Hash & Checksum | `files.hash` | SHA-256/512, SHA-1 and MD5 of text or files, compare with an expected digest, verify and create SHA256SUMS lists. |
| File Tools | Duplicate Finder | `files.duplicates` | Find identical files by size and SHA-256, pick keepers and move copies to a reversible quarantine. |
| File Tools | Line Endings | `files.line_endings` | Count LF, CRLF and CR, spot mixed endings and convert text or files, keeping their encoding. |
| File Tools | Whitespace Cleanup | `files.whitespace` | Trim trailing spaces, fix tabs, blank lines, final newline, BOM and invisible spaces with a live diff. |
| File Tools | ZIP Studio | `files.zip` | Create ZIP archives and inspect/extract them safely: every entry is checked before writing. |
| File Tools | Log Viewer | `files.logs` | Open big logs, filter by severity, search plain or regex, select and export lines with context. |
| Developer Tools | Base64 | `dev.base64` | Encode and decode Base64 (standard or URL-safe), files up to 10 MiB, binary hex preview. |
| Developer Tools | URL Encode/Decode | `dev.url` | Percent-encode components, full URIs and forms; decode with exact errors; inspect URL parts. |
| Developer Tools | UUID | `dev.uuid` | Generate v4/v7 UUIDs in bulk and inspect any UUID: version, variant and embedded time. |
| Developer Tools | Timestamp Converter | `dev.timestamp` | Live clock and Unix s/ms/us/ns <-> ISO-8601, RFC 2822 and HTTP dates, weeks and relative time. |
| Developer Tools | Text Stats | `dev.text_stats` | Characters, code points, graphemes, words, lines, bytes and reading time, live as you type. |
| Developer Tools | JSON Escape/Unescape | `dev.json_escape` | Turn any text into a JSON string literal and back, with precise errors for bad escapes. |
| Developer Tools | Regex Tester | `dev.regex` | Test patterns with flags, highlighted matches, groups and replace preview. Time-limited runs. |
| Developer Tools | Text Diff | `dev.diff` | Compare two texts or files: unified and side-by-side views, word highlights, patch export. |
| Developer Tools | HTTP Request | `dev.http` | Send requests to your own dev endpoints: headers, JSON bodies, timing, redacted history. |
| Developer Tools | Case Converter | `dev.case` | camelCase, PascalCase, snake_case, kebab-case, CONSTANT_CASE and more, with smart word splitting. |
| Developer Tools | Number Base Converter | `dev.number_base` | Binary, octal, decimal, hex and any base 2-36; two's complement, bytes and float bits. |
| Developer Tools | JWT Decoder | `dev.jwt` | Decode JWT header and claims with expiry badges. Decode only: signatures are not verified. |
| System | Terminal | `system.terminal` | Typed commands for this app's own tools. Not a system shell. |

### Terminal commands

The Terminal is an internal command interface for this app's own tools — it is
**not** a system shell. `help` lists the commands below (plus a hidden easter egg).

- `about` - App name, version, platform, tool and command counts
- `b64 enc|dec <text> [--url] [--no-pad]` - Base64 encode/decode UTF-8 text
- `clear` - Clear the screen (Ctrl+L)
- `colorfmt <colour> [--argb]` - Convert a colour between HEX, RGB, HSL and HSV
- `date` - Current local and UTC time (ISO 8601)
- `diff <a> <b> | diff --file-a <path> --file-b <path> [--ignore-case] [--ignore-space] [--context N]` - Unified diff of two texts or two workspace files
- `echo <text...>` - Print text
- `hash <text...> [--algo sha256|sha512|sha1|md5] [--check <digest>]  |  hash --file <workspace path> [--algo ...] [--check <digest>]` - Hash text or a workspace file (SHA-256 by default), optionally checking a digest
- `help [command]` - List commands, or show details for one
- `history [n] [--failed]` - Show recent operations (what tools actually did)
- `imginfo <workspace-relative path>` - Format, size, channels and frames of an image in the active workspace
- `json validate|format|minify [--indent 2|4|tab] ('<json text>' | --file <workspace path>)` - Validate, format or minify JSON text or a workspace file (read-only).
- `open <tool-id|section|route>` - Open a tool, section or page
- `profiles <list|show|check|plan> [profile-id] [--limit N]` - List, inspect, check and dry-run mod profiles of the active workspace (read-only)
- `theme [show] | theme accent <neon|crimson|infrared|ember> | theme effects <low|full> | theme intensity <0-100> | theme scanlines|particles|glow <on|off> | theme motion <system|reduced|full>` - Show or change accent, effects and motion
- `tools [section|query]` - List tools by section, or search them
- `ts [value] [--unit s|ms|us|ns] [--utc]` - Current time, or convert a Unix timestamp / ISO / HTTP date
- `url enc|dec <text> [--form] [--full]` - Percent-encode or decode text
- `uuid [count 1-1000] [--v7] [--upper] [--no-hyphens] [--braces]` - Generate UUIDs (v4 random or v7 time-ordered)
- `wcag <foreground> <background>` - WCAG contrast ratio of two colours with AA/AAA results
- `ws [list] | ws use <name|id> | ws info [name|id]` - List workspaces, switch the active one, check its folder

## Platform capability matrix

Generated from `lib/core/platform/capabilities.dart` (a test keeps this table in sync).
Unavailable actions are hidden or replaced by the listed alternative.

| Capability | Android | iOS | Windows | Linux (dev) | Alternative when unavailable |
| --- | :-: | :-: | :-: | :-: | --- |
| Link an existing folder | no | no | yes | yes | Mobile systems do not allow direct access to other folders. Import files or a ZIP into a workspace copy instead, then export results. |
| Import files | yes | yes | yes | yes | - |
| Import a folder | no | no | yes | yes | Pick several files, or import a ZIP archive of the folder. |
| Save/export dialog | yes | yes | yes | yes | - |
| Share sheet | yes | yes | no | no | Use Export to choose a location with the system save dialog. |
| Apply mods in place | no | no | yes | yes | Profiles are applied to the imported workspace copy. Export the modified files or the whole workspace as a ZIP afterwards. |
| Reveal in file manager | no | no | yes | yes | Use Export or Share to hand the file to another app. |
| Keyboard shortcuts | no | no | yes | yes | Use the search button to open the command palette. |
| Network requests | yes | yes | yes | yes | - |
| Background workers | yes | yes | yes | yes | - |
| Sound | yes | yes | yes | yes | - |

## Getting started

1. Install **Flutter 3.47.5** (stable, Dart 3.13.4). Pinned toolchain versions:
   [docs/TOOLCHAIN.md](docs/TOOLCHAIN.md).
2. Get the code and dependencies:
   ```
   git clone https://github.com/jenslazar1-sketch/J3NSONTOP-plaeholder
   cd J3NSONTOP-plaeholder
   flutter pub get --enforce-lockfile
   ```
3. Run it: `flutter run -d windows` (Windows), `flutter run -d <android-device>`,
   `flutter run -d <ios-device>` (macOS), or `flutter run -d linux` (dev target).

Useful launch arguments (desktop): `--skip-intro`, `--data-dir=<folder>` (isolated
data), `--smoke-test=<report.json>` (packaged self test; exits 0/1).

## Everyday use

1. **First launch** shows the intro (skip any time) and creates the sample
   workspace in the background; the dashboard shows real counts.
2. **Pick a workspace** from the top-bar chip or *Workspaces*. On Windows you can
   link your game/project folder; on phones import files or a ZIP.
3. **Mods:** import `.j3mod` packages (or build one), create a profile, order and
   enable packages, fix reported problems, open *Plan & apply* to see every file
   change, apply, and use *Roll back* to restore originals.
4. **Config Lab / Asset Lab / File Tools / Developer Tools:** open a tool from its
   section, the palette (Ctrl+K) or the terminal (`open <tool-id>`). Results offer
   copy, save to workspace, export (system save dialog) and share (mobile).
   Edits to workspace files always make a backup first; new outputs never
   overwrite existing files.
5. **Settings:** animation intensity, scanlines, particles, glow, low-effects
   mode, motion (follows the system reduce-motion setting by default), sound,
   accent colour, intro, data location, history and reset.

Keyboard (desktop): Ctrl+K palette · Ctrl+` terminal · Ctrl+1…9 sections ·
Ctrl+, settings · Ctrl+J activity panel · Esc closes dialogs.

Data lives in the platform app-support folder: Windows
`%APPDATA%\J3NSONTOP\J3NSONTOP Multitool`, Android/iOS app sandbox, Linux
`~/.local/share/com.j3nsontop.multitool`. Settings, favourites, history and
workspace records are versioned JSON files; a damaged file is kept as
`<name>.corrupt-<time>.json` and defaults are restored (you are told).

## Building locally

Full instructions: [docs/BUILD.md](docs/BUILD.md).

| Target | Command (from the repo root) | Output in `dist/` |
| --- | --- | --- |
| Checks | `scripts/check.ps1` or `scripts/check.sh` | format, analyze, tests |
| Windows | `scripts/build_windows.ps1` | portable ZIP (EXE + all DLLs + data) and Inno Setup installer, SHA256SUMS |
| Android | `scripts/build_android.ps1` / `.sh` (`--mode release` for signed) | debug-signed test APK or signed release APK + AAB |
| iOS (macOS) | `scripts/build_ios.sh` (`--signed --export-method ad-hoc` …) | unsigned compile check or signed IPA |

## CI and releases

[docs/CI.md](docs/CI.md) describes every job. Summary:

* **CI** (`.github/workflows/ci.yml`, every push/PR, no secrets): format,
  analyze, unit/widget tests, Linux integration tests + release build + headless
  smoke test; Android debug-signed test APK + emulator install/launch/relaunch
  smoke; Windows portable ZIP + setup EXE, then a **clean runner without Flutter**
  that runs the EXE from a Unicode path, installs, runs and uninstalls the setup;
  iOS unsigned compile check + simulator smoke.
* **Release** (`release.yml`, manual `workflow_dispatch` with inputs
  `platform` = all/android/ios/windows, `build_type` = test/release,
  `ios_export_method`): signed Android APK/AAB and signed IPA. A requested signed
  build fails clearly when its secrets are missing — it is never reported as
  signed. Nothing is published to stores or GitHub releases automatically.

Artifacts are named `J3NSONTOP-Multitool-<version>-<platform>-<kind>` and come
with `.sha256` files.

## Signing

[docs/SIGNING.md](docs/SIGNING.md) has step-by-step instructions (keystore
creation, base64 encoding on Windows, backups, Apple certificate/profile export,
export methods). Repository secrets used by `release.yml`:

* Android: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
  `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.
* iOS: `IOS_CERTIFICATE_P12_BASE64`, `IOS_CERTIFICATE_PASSWORD`,
  `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_TEAM_ID` (secret or variable),
  optional `IOS_KEYCHAIN_PASSWORD`. *development* and *ad-hoc* IPAs install on
  devices registered in the profile; *app-store* builds install only through
  TestFlight/App Store.
* Windows (optional Authenticode): `WINDOWS_CERTIFICATE_PFX_BASE64`,
  `WINDOWS_CERTIFICATE_PASSWORD`. Without them the EXE is reported as not
  code-signed.

Never paste keys or passwords into issues or chat; add them as GitHub secrets.

## Supported formats

| Area | Formats | Details |
| --- | --- | --- |
| Mod packages / profiles | `.j3mod` (ZIP + JSON manifest), `.j3profile.json` | [docs/MOD_FORMAT.md](docs/MOD_FORMAT.md) |
| Config | JSON, YAML, TOML, INI, CSV/TSV, JSON saves + JSON-schema subset | [docs/CONFIG_LAB.md](docs/CONFIG_LAB.md) (lossless vs representation-changing conversions) |
| Images | decode/encode matrix of `package:image` (PNG, JPEG, WebP, GIF, BMP, TGA, TIFF, ICO, …) | [docs/ASSET_LAB.md](docs/ASSET_LAB.md), [docs/ATLAS_FORMAT.md](docs/ATLAS_FORMAT.md) |
| Files | checksum lists (GNU/BSD), ZIP (Stored/Deflate), text encodings (UTF-8/16, Latin-1 fallback) | [docs/FILE_TOOLS.md](docs/FILE_TOOLS.md) |
| Developer | Base64, URL, UUID v1–v8 inspect / v4+v7 generate, JWT (decode only), HTTP | [docs/DEV_TOOLS.md](docs/DEV_TOOLS.md), [docs/HTTP_TOOL.md](docs/HTTP_TOOL.md) |

The save editor only supports JSON saves described by a schema; binary or
undocumented formats are never guessed.

## Architecture and adding a tool

Feature-oriented Flutter app: `lib/core` (widgets, theme, storage, platform
adapters, activity, archive/path safety), `lib/features/<feature>` (domain /
data / presentation + a `FeatureModule`), `lib/app` (router, catalog, smoke
test). Riverpod 3 for state, go_router for navigation. Details and the rules
every feature follows: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

To add a built-in tool: build a page with `ToolScaffold(toolId: ...)`, add a
`ToolDefinition` (id, name, section, description, keywords, platforms, required
capabilities, builder) to its feature's `FeatureModule`, and add tests.
Navigation, search, the palette, favourites and `open` pick it up automatically.
Terminal commands are `TerminalCommand` classes registered the same way
([docs/TERMINAL.md](docs/TERMINAL.md)).

## Testing

Manual testing (install steps for every platform, a 120-case checklist and the
bug-report flow): [docs/TESTING.md](docs/TESTING.md).

```
flutter analyze
flutter test                                   # unit + widget tests
flutter test integration_test -d windows       # end-to-end on a device/desktop
```

Widget tests cover every tool page at 320×568 with 2× text, malformed input and
the primary action; domain tests cover archive validation, mod resolution,
apply/rollback/interruption, conversions, parsers and more.

## Troubleshooting

* **Windows SmartScreen warns about the EXE/installer** — the CI binaries are
  not code-signed unless you configure a certificate (see Signing).
* **Android "App not installed"** over an older test APK — each CI run signs test
  APKs with its own debug key; uninstall first. Release builds keep one key.
* **iOS artifact from CI won't install** — the CI iOS artifact is an *unsigned
  compile check* (a ZIP, never an `.ipa`). Signed IPAs need the secrets above.
* **HTTP tool can't reach `localhost` from a phone** — on a phone, localhost is
  the phone. Use your computer's LAN IP (server bound to `0.0.0.0`, firewall
  open); the Android emulator reaches the host at `10.0.2.2`
  ([docs/HTTP_TOOL.md](docs/HTTP_TOOL.md)).
* **Settings reset after a crash** — look for `*.corrupt-*.json` next to the
  data files; the damaged file is kept for inspection.
* **Too much animation / battery** — Settings → Low-effects mode, or enable
  reduced motion in the OS.
* **Mod apply was interrupted** — reopen *Mods*; the banner offers Resume or
  Roll back from the journal.

More: [docs/BUILD.md](docs/BUILD.md#6-troubleshooting).

## Credits and licences

All art (ASCII skull, app icon, splash) and the intro sound are original to this
project — see [docs/ASSETS.md](docs/ASSETS.md) and [docs/INTRO.md](docs/INTRO.md).
Fonts: Chakra Petch and JetBrains Mono under the SIL Open Font License 1.1
(texts in `assets/licenses/`, also shown in the app's licence page).
Open-source package licences are listed in the app (About → Open-source licences).
