# J3NSONTOP BIGGEST MULTITOOL MADE

```
             _.--~~~~~~~--._
         _.-~'   '     ' , '~-._
      .-'   .             \ .   '-.
    .'   '                /    '   '.
  .'                       \_        '.
 /    .                      \    .    \
|                                       |
|   .-~~~~~~-._           _.-~~~~~~-.   |
| .'           '-.     .-'           '. |
| |               \   /               | |
| |                | |                | |
 \'.              .' '.              .'/
  \ '-._________.-'   '-._________.-' /
   '.              / \              .'
    '.            /_^_\            .'
      '-._______________________.-'
        | |_|_|_|_|_|_|_|_|_|_| |
        | |"|"|"|"|"|"|"|"|"|"| |
        | '-'-'-'-'-'-'-'-'-'-' |
        \                       /
         '.                   .'
           '-._____________.-'
          J3NSONTOP SYSTEM ONLINE
```

A local-first multitool for **harmless modding** of your own projects and games
that support mods, asset preparation, configuration editing, file utilities and
everyday developer tasks — wrapped in a black-and-neon-red terminal aesthetic
with a laughing ASCII skull.

* One Flutter/Dart codebase for **Android**, **iOS** and **Windows** (Linux is
  kept as a development/test target).
* Application id: `com.j3nsontop.multitool` · short name: **J3NSONTOP Multitool** ·
  version `1.0.0` (build 1).
* No login, no telemetry, no cloud upload. Network access happens only when you
  press *Send* in the HTTP developer tool.
* Scope: user-controlled files, supported game mod workflows, backups, asset
  tools and development utilities. It does **not** access other apps' data,
  credentials, anti-cheat systems or multiplayer games.

> STATUS SECTION — finalized at the end of the implementation run.

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

## Platform capability matrix

Generated from `lib/core/platform/capabilities.dart` (a test keeps this table in sync).

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

## Credits and licences

See [docs/ASSETS.md](docs/ASSETS.md). All art (ASCII skull, icon, splash) and the
intro sound are original to this project. Fonts: Chakra Petch and JetBrains Mono
(SIL Open Font License 1.1, texts in `assets/licenses/`).
