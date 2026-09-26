# Testing J3NSONTOP Multitool

This guide is for people who test **J3NSONTOP BIGGEST MULTITOOL MADE** (short
name J3NSONTOP Multitool, version 1.0.0) on Android, Windows or iOS. It says
where to get a build, how to install it, what to check and how to report what
you find. A full pass of the checklist takes about 3-4 hours; one section
takes 20-40 minutes, so splitting sections between testers works well.

The app is local-only: no account, no telemetry, no cloud. Nothing you do in
it is uploaded; only the HTTP tool contacts the addresses you type.

Contents: [1. Get a build](#1-get-a-build) ·
[2. Install](#2-install) · [3. Before you start](#3-before-you-start) ·
[4. Report a problem](#4-report-a-problem) · [5. Checklist](#5-checklist) ·
[6. Known limitations of test builds](#6-known-limitations-of-test-builds)

## 1. Get a build

Every push runs the **CI** workflow, which builds and self-tests the app on
every platform. Its builds are the test builds:

1. Sign in to GitHub, open the repository's **Actions** tab and choose the
   **CI** workflow.
2. Open the newest run with a green check for the branch you were asked to
   test (for example `main`).
3. Scroll to **Artifacts** and download the one for your platform. Artifacts
   are ZIP files and are deleted after 30 days; ask for a new run if they are
   gone.

| Platform | Artifact | Inside |
| --- | --- | --- |
| Android 7.0 or newer | `J3NSONTOP-Multitool-1.0.0-android-test-apk` | `…-android-test-debugsigned.apk`, its `.sha256`, `android-build-info.txt` |
| Windows 10/11 x64, no install | `J3NSONTOP-Multitool-1.0.0-windows-x64-portable` | `…-windows-x64-portable.zip`, its `.sha256`, `windows-build-info.txt` |
| Windows 10/11 x64, installer | `J3NSONTOP-Multitool-1.0.0-windows-x64-setup` | `…-windows-x64-setup.exe` and its `.sha256` |
| iOS Simulator on a Mac with Xcode | `J3NSONTOP-Multitool-1.0.0-ios-simulator-app` | `…-ios-simulator-debug.zip` (Runner.app + install note) and its `.sha256` |
| iPhone / iPad | not available as a test build | see [iPhone and iPad](#iphone-and-ipad) |

The artifact `J3NSONTOP-Multitool-1.0.0-ios-UNSIGNED-compile-check` only
proves that the iOS app compiles. It cannot be installed anywhere.

**Check the download.** Each file comes with `<file>.sha256`. Compare:

- Windows (PowerShell): `Get-FileHash .\<file> -Algorithm SHA256`
- macOS: `shasum -a 256 <file>`
- Linux: `sha256sum -c <file>.sha256`

If the checksum differs, do not install it; download it again.

## 2. Install

### Android

1. Unzip the artifact on your computer or phone (the Files app can open ZIPs).
2. Either copy the `.apk` to the phone and open it (allow "Install unknown
   apps" for the app you open it with when Android asks), or with USB
   debugging: `adb install -r J3NSONTOP-Multitool-1.0.0-android-test-debugsigned.apk`.
3. Open **J3NSONTOP Multitool** from the launcher.

Test APKs are signed with the project's public test key, so a newer test APK
installs over an older one and keeps your data. If Android refuses the
update ("App not installed"), you have an older test build signed with a
different key: uninstall it first. A release-signed build cannot replace a
test build either; uninstall the test build first (this deletes its data).

### Windows

Portable ZIP: unzip anywhere you can write to (a folder with non-English
letters in its name is fine) and run `j3nsontop_multitool.exe`. Keep the
files next to the EXE together.

Installer: run `…-windows-x64-setup.exe`. It installs to Program Files for all
users (administrator rights) or, if you choose so in its first dialog, for you
only. It adds a Start-menu entry and an uninstaller (Settings > Apps).

The test builds are not code-signed, so Windows SmartScreen may say "Windows
protected your PC": choose **More info** > **Run anyway** after checking the
SHA-256 as above. The app keeps its data in your user profile's AppData
folder, not next to the EXE.

### iOS Simulator (Mac)

You need a Mac with Xcode. Unzip `…-ios-simulator-debug.zip`, then:

```sh
open -a Simulator
xcrun simctl install booted <unzipped folder>/Runner.app
xcrun simctl launch booted com.j3nsontop.multitool
```

or drag `Runner.app` onto the simulator window. `INSTALL-SIMULATOR.txt` in the
ZIP names the simulator it was verified on. It is a debug build: it runs
slower than a release build, so judge features, not speed.

### iPhone and iPad

Apple only runs signed apps on devices, and signing needs an Apple Developer
account. Two ways:

- **Release workflow** (maintainers): after the signing secrets in
  [SIGNING.md](SIGNING.md) are added to the repository, run **Actions >
  Release** with platform `ios` and build type `release` to get a signed IPA
  for ad-hoc devices or TestFlight.
- **From source** (one developer device): clone the repository on a Mac, run
  `flutter pub get`, open `ios/Runner.xcworkspace` in Xcode, choose your team
  under Signing & Capabilities (a free Apple ID works for 7 days; change the
  bundle identifier if Xcode says it is taken) and press Run.

### Linux (development only)

Build and run from source as described in [BUILD.md](BUILD.md)
(`flutter run -d linux`).

## 3. Before you start

- **Fresh start.** On the first launch the laughing-skull intro plays and the
  app creates a sample workspace, **NEON DUNGEON (sample)**: a small fictional
  game with config files, sprites, logs, 7 mod packages and 4 mod profiles.
  Almost every case uses its files by their paths, for example
  `game/config/graphics.json`. The exact content is listed in
  [samples/README.md](../samples/README.md).
- **Reset when needed.** Cases change files on purpose. **Workspaces > NEON
  DUNGEON (sample) > Reset sample** restores everything as on first run.
- **Note your build label.** About > Build label (for example `ci16-ad22533`)
  names the exact build. Put it in every report.
- **Test like a user**, including the unhappy paths: cancel dialogs, rotate
  the phone, switch apps, use large system text, go offline for the HTTP tool.
  Anything confusing is worth reporting, not only crashes.
- **Platform differences are intended.** Phones cannot open other apps'
  folders, so on Android and iOS the app works on imported copies inside its
  own storage and exports results through the share sheet or save dialog.
  About > "What works where" shows the full capability matrix.

## 4. Report a problem

1. Reproduce it once more if you can and write down the steps.
2. In the app open **About > Report a problem** and tap **Copy diagnostics**
   (version, build label, system, display, settings and recent errors, with
   your home folder shortened to `~`). After a crash, reopen the app and use
   **Save diagnostics file**, which also contains the error log.
3. On GitHub open **Issues > New issue > Bug report (testers)**, fill in the
   form, paste the diagnostics and attach screenshots or a screen recording.
   Quote the checklist ID (for example `MD-04`) when a case failed.

Never attach private files, passwords or keys. Suggestions and "this was
confusing" notes are welcome as issues too.

## 5. Checklist

120 cases. IDs are stable: quote them in bug reports. "Platforms" says where a case applies: **all**, **desktop** (Windows, Linux) or **mobile** (Android, iOS). Mark each case pass / fail / blocked in your notes; the [summary table](#summary-table) lists every ID.

### SH · App shell: intro, Home, navigation, palette, terminal, settings, activity, About

Before you start:

- Fresh install (or cleared app data) for case 1 so the intro and the first-run sample workspace appear; later cases assume the sample workspace "NEON DUNGEON (sample)" exists and is active.
- Desktop = Windows (or Linux dev build) with a physical keyboard; window at least 1200 px wide for the activity-panel case. Mobile = Android or iOS phone.
- For the small-screen case: a phone (or emulator) 320-360 px wide and the OS font size set to the largest value.
- Sound case: device volume up; Sound is OFF by default in the app.

#### SH-01 · First launch: laughing-skull intro plays once, then the sample workspace appears on Home

Platforms: **all**

1. Install and launch the app for the first time.
2. Watch the intro without touching anything (about 4 s).
3. On Home, read the "// SYSTEM STATUS" / "Live status" panel.
4. Open Activity (sidebar or bottom tab) and expand the "Create sample workspace" entry.

**Expected:** Intro: dark screen, red SIGNAL line, skull decoded top to bottom, jaw drops three times (HA-ha-HA!), short glitch, then "J3NSONTOP / BIGGEST / MULTITOOL MADE" and typed "J3NSONTOP SYSTEM ONLINE", then a wipe into Home. SKIP &gt;&gt; is visible top-right from the first frame and a "Skip intro on launch" switch at the bottom. Home: WORKSPACES 1 ("1 active"), MOD PACKAGES 7 and PROFILES 4 with caption in "NEON DUNGEON (sample)", TOOLS ONLINE shows available/total with "available on &lt;platform&gt;". The active-workspace chip in the top bar shows NEON DUNGEON (sample). Activity: a Done operation "Create sample workspace" with summary "&lt;n&gt; files, 7 mod packages and 4 profiles" and details Workspace/Files/Mod library/Profiles.

#### SH-02 · Skip the intro (button, Esc) and it never replays on navigation

Platforms: **all**

1. Relaunch the app (Skip intro on launch still off).
2. Immediately tap "SKIP &gt;&gt;" (desktop: alternatively press Esc).
3. Navigate Home -&gt; Settings -&gt; Activity -&gt; Home; put the app in the background and resume it.

**Expected:** SKIP &gt;&gt; (tooltip "Skip intro (Esc)") lands on the Home dashboard instantly and any intro sound stops. The intro does not play again on navigation or resume; it only returns on the next cold start.

#### SH-03 · Skip-intro setting persists (intro toggle and Settings switch)

Platforms: **all**

1. During the intro, turn on the "Skip intro on launch" switch at the bottom, then tap SKIP &gt;&gt;.
2. Fully close the app and relaunch it.
3. Open Settings, panel "// INTRO" / "Laughing-skull intro"; turn "Skip intro on launch" off.
4. Close and relaunch the app.

**Expected:** After the first relaunch the app opens directly on Home with no intro, and the Settings switch "Skip intro on launch" is on. After turning it off and relaunching, the intro plays again.

#### SH-04 · Replay intro from About, Settings, Home and the palette

Platforms: **all**

1. Open About (Settings &gt; "About this app", or palette entry "About") and tap "Replay intro".
2. Let it finish or tap SKIP &gt;&gt;.
3. Repeat from Settings &gt; "Replay intro now" and from Home &gt; Quick actions "Replay intro".

**Expected:** The intro plays again with a small "REPLAY" label at the top-left; it works even when "Skip intro on launch" is on. When it ends or is skipped, the app goes to Home (not back to the page it was started from).

#### SH-05 · Intro sound on, mute from the intro

Platforms: **all**

1. Settings &gt; "// SOUND": turn on "Sound effects" and set Volume (label shows e.g. "60 %").
2. Tap "Replay intro now".
3. While the laugh plays, tap the speaker icon (tooltip "Mute") left of SKIP &gt;&gt;.
4. After the intro, open Settings &gt; Sound.

**Expected:** With sound on, the synthesized laugh/glitch sting plays in sync with the intro. Mute stops the sound instantly and hides the speaker icon; the animation continues. Back in Settings, "Sound effects" is now off and Volume shows "sound is off" with the slider disabled. With sound off (default) no speaker icon appears and nothing plays.

#### SH-06 · Reduced motion gives a static intro with Continue

Platforms: **all**

1. Settings &gt; "// EFFECTS" &gt; MOTION: select "Always reduce".
2. Check the two info lines under it.
3. Tap "Replay intro now" and watch; repeat and tap "Continue" quickly.
4. Set MOTION back to "Follow system".

**Expected:** Info line reads "Result: motion is reduced - no glitches, drifting particles or laughing jaw." The intro shows a static skull (closed jaw), full title and tagline, a "Continue" button, no sound, and continues to Home automatically after about 1.2 s (or immediately on Continue). With "Follow system" the result follows the OS reduce-motion/remove-animations setting ("System setting: reduce motion is ON/OFF.").

#### SH-07 · Effects settings: intensity, low-effects, scanlines, particles, glow, accent (live preview)

Platforms: **all**

1. Settings &gt; "// EFFECTS": drag "Animation intensity" to 40 % and release.
2. Toggle "Scanlines", "Particles" and "Glow" off one by one while watching the "// LIVE PREVIEW" badges and the app background.
3. Turn "Low-effects mode" on.
4. Under "// THEME" / ACCENT tap "Crimson".

**Expected:** Preview badge shows "INTENSITY 40%"; SCANLINES/PARTICLES/GLOW badges switch to OFF and the whole UI loses scanlines, drifting glyphs and neon bloom. With Low-effects mode on, the intensity label reads "0 % (low-effects mode)", the slider and the three switches are disabled with description "Disabled by low-effects mode." but keep their own values. Crimson shows a check icon and "ACTIVE" and the accent colour of the whole app changes immediately.

#### SH-08 · Settings persist after relaunch; Reset settings to defaults

Platforms: **all**

1. With the changes from the previous case (Crimson, scanlines off, low-effects on), fully close and relaunch the app.
2. Open Settings and verify the values.
3. In "// DATA & PRIVACY" tap "Reset settings to defaults", then "Reset settings" in the dialog.

**Expected:** After relaunch Crimson is still ACTIVE, Low-effects mode and the other switches keep their values. The reset dialog title is "Reset settings to defaults?" with the note "Workspaces, favourites, presets and history are not affected"; after confirming, a toast "Settings reset to defaults" appears, accent returns to Neon red, intensity 75 %, scanlines/particles/glow on, sound off, MOTION "Follow system". The sample workspace is NOT recreated on the next launch.

#### SH-09 · Home favourites and recents

Platforms: **all**

1. On Home, check the "// FAVORITES" panel (should say "No favourites yet").
2. Open the Terminal and tap the star in its header (tooltip "Add to favourites"); do the same for "Base64" (Developer Tools).
3. Go back to Home.
4. Open the menu (three dots, tooltip 'Reorder or remove "Terminal"') on the first card and choose "Move down" (or "Move right" on wide screens), then "Remove from favourites" on one card.

**Expected:** Title becomes "Pinned tools (2)" with the two cards in pin order; the move swaps their order (desktop: Alt+Arrow keys on a focused card do the same; drag by handle works too). Remove leaves "Pinned tools (1)". "// RECENT TOOLS" / "Recently opened" lists Base64 and Terminal with section and relative time. Order and favourites survive a relaunch.

#### SH-10 · Navigation: sidebar/rail on desktop, bottom bar + drawer on phones, Android back

Platforms: **all**

1. Desktop (&gt;= 1200 px): click each sidebar entry Home, Workspaces, Mods, Config Lab, Asset Lab, File Tools, Developer Tools, Activity, Settings and Terminal; narrow the window below 1200 px, then below 600 px.
2. Phone: use bottom tabs Home, Workspaces, Mods, Tools, Activity; open the hamburger drawer and pick Settings and Terminal.
3. Android: from Settings press the system Back button, then Back again on Home.

**Expected:** Wide window shows the full sidebar with the skull logo and "J3NSONTOP / MULTITOOL"; 600-1200 px shows an icon rail with short labels; &lt; 600 px shows an app bar, drawer and bottom navigation. The selected entry is highlighted and the title matches the page. Android Back from any section returns to Home; Back on Home leaves the app. On a phone, Config Lab, Asset Lab, File Tools, Developer Tools and every tool page keep the Tools tab highlighted; on Settings and About no tab is highlighted.

#### SH-11 · Command palette: Ctrl+K and keyboard shortcuts (desktop)

Platforms: **desktop**

1. Press Ctrl+K, type "base64", press Enter.
2. Press Ctrl+Shift+P, type "zzzz".
3. Press Esc, then try Ctrl+1 ... Ctrl+9, Ctrl+, and Ctrl+\`.
4. Open the palette, type "&gt; hel", press Tab, then Enter.

**Expected:** Ctrl+K (and Ctrl+Shift+P) opens the palette with hint "Search tools and actions, or &gt; for commands"; matches are underlined; Enter opens the Base64 tool. "zzzz" shows 'No match for "zzzz"'. Esc closes it. Ctrl+1..9 go to Home, Workspaces, Mods, Config Lab, Asset Lab, File Tools, Developer Tools, Activity, Settings; Ctrl+, opens Settings; Ctrl+\` opens the Terminal. In &gt; mode rows read "Run in terminal: help"; Tab completes to "&gt; help "; Enter opens the Terminal and runs help there. Footer shows "&lt;n&gt; results | Up/Down select | Enter open ...| Esc close".

#### SH-12 · Command palette on mobile (search button) and shortcuts panel alternative

Platforms: **mobile**

1. Tap the search icon (tooltip "Search") in the app bar.
2. Type "terminal" and tap the "Terminal" row.
3. Open the palette again, tap "Run a terminal command", type "about" after the "&gt; " and tap the row.
4. Open Settings and scroll to "// KEYBOARD".

**Expected:** The palette opens with the on-screen keyboard; footer reads "&lt;n&gt; results | tap to open | type &gt; for terminal commands" (no keycaps). Tapping Terminal opens the Terminal. "Run a terminal command" fills "&gt; " and stays open; the "Run in terminal: about" row opens the Terminal and prints the app name, version 1.0.0 (build 1), platform and tool/command counts. Settings shows "Keyboard shortcuts are not available on Android. Use the search button to open the command palette." (iOS on iPhone).

#### SH-13 · Terminal: help, open, theme, invalid commands

Platforms: **all**

1. Open the Terminal (nav entry "Terminal"); read the banner.
2. Run: help
3. Run: hlep
4. Run: ls
5. Run: theme accent purple, then theme accent ember
6. Run: open settings

**Expected:** Banner: mini skull and "J3NSONTOP // internal command interface — runs this app's own tools. This is not a system shell." help lists commands grouped by section under "COMMANDS // internal command interface (not a system shell)". "hlep" prints 'ERROR: Unknown command "hlep".' and "Did you mean: help?". "ls" prints the ERROR line, "Did you mean: cls, ts or ws?" and 'This is not a system shell: OS programs such as "ls" cannot run here.' "theme accent purple" prints 'ERROR: "purple" is not a valid accent.' plus "usage: theme accent &lt;neon|crimson|infrared|ember&gt;"; "theme accent ember" prints "OK: accent set to Ember (ember)." and the app accent changes. "open settings" prints "Opening settings  -&gt;  /settings" and navigates there. The prompt reads j3nsontop@NEON DUNGEON (sample)$ (just "$" on narrow screens).

#### SH-14 · Terminal history, completion, toolbar and session survival

Platforms: **all**

1. In the Terminal type "th" and press Tab (touch: the "Tab" key under the input).
2. Run "echo hello", then press Up (touch: up-arrow key) twice and Down.
3. Navigate to Home and back to the Terminal.
4. Tap the toolbar "Clear screen (Ctrl+L)" icon; then use "Copy all output" after running help.

**Expected:** Tab completes to "theme". Up/Down walk earlier commands; walking past the newest restores the line being typed. The transcript and unfinished input are still there after navigating away and back. Clear empties the output; Copy all puts the transcript on the clipboard. Touch/narrow screens show 44 px keys Tab, Up, Down and quick commands help, tools, open, history, ws, clear.

#### SH-15 · Activity page and live activity panel

Platforms: **all**

1. Open Activity: check the header line and the "// FILTER" panel.
2. Type "sample" in the search field, then tap the status chip "Done".
3. Tap "Clear history" and confirm with "Clear history".
4. Desktop &gt;= 1200 px: press Ctrl+J twice; also click the close button (tooltip "Hide activity panel") in the right-hand panel. Phone: tap the heart-monitor icon (tooltip "Activity") in the app bar.

**Expected:** Header shows "&lt;n&gt; operations in history | &lt;r&gt; running | &lt;t&gt; today". Search "sample" leaves "Create sample workspace"; "Showing x of y" updates; the Done chip filters by status. Clear dialog "Clear operation history?" says files, workspaces, backups and mod journals are not touched; afterwards toast "Cleared &lt;n&gt; operations from history" and the empty state "No operations yet". Ctrl+J hides/shows the "// LIVE ACTIVITY" panel (same as Settings switch "Show the activity panel on wide screens"); on phones the panel opens as an end drawer.

#### SH-16 · About screen and hidden skull laugh

Platforms: **all**

1. Open About (Settings &gt; "About this app").
2. Check "// BUILD" / "Version and identity".
3. Tap the skull five times quickly (or long-press it).
4. Tap "Open-source licences" and go back.

**Expected:** About shows J3NSONTOP BIGGEST MULTITOOL MADE, tagline J3NSONTOP SYSTEM ONLINE, and a table with Version 1.0.0, Build 1, Application id com.j3nsontop.multitool, the current Platform and "Local only (no account, no cloud)". Five quick taps or a long-press make the skull's jaw drop and close three times with glowing eyes (with reduced motion only the eyes light up). The licence page opens with name "J3NSONTOP Multitool" and version "1.0.0 (build 1)".

#### SH-17 · Small phone (320-360 px) with largest system text

Platforms: **mobile**

1. Set the OS font size to maximum; use a 320-360 px wide phone.
2. Replay the intro (Home &gt; "Replay intro").
3. Scroll through Home, Settings (ACCENT grid) and Activity.
4. Open the palette and the Terminal; tap the input to open the soft keyboard.

**Expected:** Intro title lines, SKIP &gt;&gt; and the "Skip intro on launch" toggle stay visible and unclipped; skull art never reflows. Home, Settings and Activity scroll with no clipped/overlapping text; accent swatches fall to 2 columns; the bottom navigation labels stay readable. Palette rows grow with the text size. The Terminal becomes scrollable instead of overflowing when the keyboard is open, and the input shows "$" as the prompt.

#### SH-18 · Report a problem: copy and save diagnostics

Platforms: **all**

1. Open About (Settings &gt; "About this app").
2. In "// DIAGNOSTICS" / "Report a problem", note the Build label (also in "Version and identity").
3. Tap "Copy diagnostics" and paste into any text field or note.
4. Tap "Save diagnostics file" and save it (workspace, save dialog or share sheet).

**Expected:** The panel shows Build label, System, "Errors this session" ("none" on a clean run) and the error log path with your home folder shortened to \~. The toast reads "Diagnostics copied - paste them into your bug report". The pasted text starts with "J3NSONTOP Multitool diagnostics" and lists App (version, build, label), Platform, Display, Settings, Data folder and Errors. The saved file is named j3nsontop-diagnostics-&lt;time&gt;.txt and also contains the error log if one exists. Nothing is uploaded.

#### SH-19 · Home quick action "Create sample workspace" keeps your active workspace

Platforms: **all**

1. With NEON DUNGEON (sample) (or any workspace) active, open Home &gt; Quick actions.
2. Tap "Create sample workspace" and wait for the toast.
3. Check the workspace chip in the top bar, then open Workspaces.

**Expected:** The toast reads 'Sample workspace "NEON DUNGEON (sample)" is ready; your current workspace stays active (switch in Workspaces)'. The top-bar chip still shows the previous workspace. Workspaces lists a second sample card without the ACTIVE badge. (With no workspace at all, the new sample becomes active and the toast says "is ready and active".)

### WS · Workspaces

Before you start:

- A fresh sample workspace named "NEON DUNGEON (sample)" (created on first run; files identical to samples/neon-dungeon/, 42 files). If earlier cases changed it, press "Create sample workspace" in Workspaces, then "Set active" on the new card. A new sample is only activated automatically when no workspace was active before.
- Run the cases in order within one install. Cases that change files (browser trash, editor save, rename, replace) leave the sample modified, so later counts assume the sample has no extra files. Run the ZIP import into a NEW workspace, never into the sample, or the Find Files counts will change.
- Open tools from the Workspaces section landing ("Workspace tools" hub) or with the command palette. Every tool except the manager needs an active workspace and otherwise shows "No active workspace" with an "Open Workspaces" button.
- Desktop = Windows or Linux build, mobile = Android or iOS build. On narrow screens (phones), tapping a file in the File Browser opens a details bottom sheet instead of the side panel.
- Watch the Activity log and toasts: many results (backup path, hash copied, cancellations) appear there.
- Have a text file on the device (any .txt) for the device-import cases.

#### WS-01 · Manager: create an empty workspace, switch the active workspace, rename with validation

Platforms: **all**

1. Open Workspaces and press "New empty workspace". Keep "My project" in "Workspace name" and confirm with OK.
2. Check the new card, then press "Set active" on the "NEON DUNGEON (sample)" card.
3. On the "My project" card press "Rename", clear the field and try to confirm.
4. Enter "My project 2" and confirm.

**Expected:** Step 1 shows the success banner 'Created "My project"' with the message "Files were copied into app storage. Export to get results out." The new card has the badges "IMPORTED COPY" and "REACHABLE", and the header counts one more workspace (for example "2 workspaces"). A new empty workspace becomes active ("ACTIVE" badge). After "Set active", the ACTIVE badge moves to the sample card and its "Set active" button disappears. In the Rename dialog an empty name shows "Enter a name" and cannot be confirmed; "My project 2" renames the card.

#### WS-02 · Manager: Export ZIP of the sample, then Import ZIP into a new workspace (with cancel of the preview)

Platforms: **all**

1. On the "NEON DUNGEON (sample)" card press "Export ZIP" (enabled only after the badge reads REACHABLE).
2. In the "Save "NEON DUNGEON (sample).zip"" sheet choose "Export..." (desktop) or "Share..."/"Export..." (mobile) and save the file outside the app.
3. Press "Import ZIP" and pick the saved ZIP. In the "Import ..." preview dialog press "Cancel".
4. Press "Import ZIP" again, pick the same ZIP and press "New workspace". Keep the proposed name and confirm.

**Expected:** The export ends with the banner "Exported 42 files to ...". Choosing Cancel in the save sheet instead gives "ZIP created (...) but not saved". The preview dialog shows chips Files 42, Blocking 0, a Warnings count, the green banner "Safe to extract" and a "// ENTRIES" list. Cancel extracts nothing. With "New workspace", the name dialog "Name the new workspace" suggests "NEON DUNGEON (sample)". Extraction ends with the banner "Extracted 42 files (...) into "NEON DUNGEON (sample)"", and the new workspace becomes active. Switch back to the original sample afterwards with "Set active".

#### WS-03 · Manager: remove a record but keep its files, then recover it from App storage

Platforms: **all**

1. On the "My project 2" card (from the first case) press "Remove".
2. In "Remove workspace?" leave "Also delete the imported copy (...)" unchecked and press "Remove record".
3. In the "Unused workspace storage" panel press "Scan app storage".
4. On the listed folder press "Recover as workspace".

**Expected:** The dialog measures the copy first (label shows file count and size), and the checkbox is unchecked by default. When it is ticked, the button text changes to "Remove and delete files". After "Remove record" the banner reads 'Removed "My project 2"' with "Files were kept in app storage.", and the card disappears. The scan lists one folder (an id, then "N files, size") with the buttons "Recover as workspace" and "Delete". Recovering shows 'Recovered as "Recovered xxxxxxxx"' (the first 8 characters of the id) and adds a new card. The storage panel then rescans and shows "No unused storage" / "Every folder belongs to a workspace." if nothing else is left.

#### WS-04 · Manager on mobile: no link/import folder, app-storage copy via Import files

Platforms: **mobile**

1. Open Workspaces on Android or iOS and look at the "Create or import" panel.
2. Press "Import files". In the sheet "Import files into..." choose 'Active workspace "NEON DUNGEON (sample)"'.
3. Pick one small text file from the device.
4. Repeat steps 2-3 with the same file.

**Expected:** The "Link folder" and "Import folder" buttons are not shown. An info banner reads "Linking folders is not available on Android" (or "iOS") with the message "Mobile systems do not allow direct access to other folders. Import files or a ZIP into a workspace copy instead, then export results." The first import ends with the banner "Imported 1 file (...) into "NEON DUNGEON (sample)"". The second import does not overwrite: its details list "&lt;name&gt; already existed, imported as &lt;name&gt; (2)". The workspace card has no "Show in file manager" icon.

#### WS-05 · Manager on desktop: link a folder, then remove the linked record without touching the folder

Platforms: **desktop**

1. Create a scratch folder on disk containing one text file.
2. In Workspaces press "Link folder", choose the scratch folder and keep the proposed name (the folder name) in the "Link folder" dialog.
3. Press "Remove" on the new linked card and confirm "Remove record" in "Remove linked workspace?".
4. Check the scratch folder on disk.

**Expected:** After linking, the banner reads 'Linked "&lt;folder&gt;"' with the message "Files are edited in place in the folder you chose. Removing this workspace later never deletes the folder." The card shows a link icon, "LINKED FOLDER" and REACHABLE, and the linked workspace becomes active. The remove dialog says that only the record is removed and that the linked folder is NOT deleted or changed. The banner then reads 'Removed "&lt;folder&gt;"' with "Your folder was not touched." The folder and its file still exist. Set the sample active again afterwards.

#### WS-06 · File Browser: navigate, filter, details and SHA-256 of the near-duplicate files

Platforms: **all**

1. With the sample active, open File Browser and tap the "duplicates" folder.
2. Type "backup" in "Filter names".
3. Select "hud\_backup.json" (on a phone the details sheet opens) and press "Compute SHA-256".
4. Repeat for "hud\_backup\_old.json", then press the "Up one folder" arrow.

**Expected:** The breadcrumb shows "NEON DUNGEON (sample) / duplicates". The filter reduces the list to 2 entries, and the summary reads "2 items matching". The details show Content Text, Encoding and Line endings. Both files are 1.4 KB (1422 bytes) but their hashes differ: hud\_backup.json gives "SHA-256 d455cb4b5ec2bb1e633ba77e40e7dc6900da459a242223e9637d145b45fbcfc0", and hud\_backup\_old.json gives "SHA-256 2071ed980f3489cb0978e9ff7765cecebfe8765c34dcf67e55b6f7202163a876" (these match samples/SHA256SUMS.txt). "Up one folder" returns to the workspace root.

#### WS-07 · File Browser: rename validation, move to trash, Undo, and restore from the Trash view

Platforms: **all**

1. In "duplicates" open the row menu ("Actions for potion (copy).png") and choose "Rename...". Enter "a/b.png", then "hud\_backup.json", then "potion-copy.png" and confirm.
2. Open the row menu of "potion-copy.png" and choose "Move to trash...", then confirm "Move to trash".
3. Press "Undo" in the banner.
4. Move the file to trash again, press the "Show trash" icon and use the restore icon ("Restore potion-copy.png").

**Expected:** In the "Rename file" dialog, "a/b.png" is rejected with "Name must not contain / or \\", and "hud\_backup.json" is rejected with 'Something named "hud\_backup.json" already exists here'. "potion-copy.png" is accepted with the toast "Renamed to potion-copy.png". The trash confirm dialog is titled "Move to trash?". Afterwards the banner reads 'Moved "potion-copy.png" to trash' / "It can be restored until the trash is emptied." Undo brings the file back and shows the toast "Restored duplicates/potion-copy.png". The Trash view shows "1 item in trash" with the path and "deleted ...", and restoring returns the file to duplicates/.

#### WS-08 · Text Editor: edit and save game/config/settings.ini with backup, then revert unsaved changes

Platforms: **all**

1. In File Browser go to game/config and choose "Open in Text Editor" from the menu of settings.ini.
2. Change "difficulty = normal" to "difficulty = hard".
3. Press "Save".
4. Type any extra character, press "Revert" and confirm "Revert".

**Expected:** The header shows "NEON DUNGEON (sample)/game/config/settings.ini" with the badges SAVED, the encoding, "Endings: LF" and the size. After the edit the badge turns to MODIFIED and Save becomes enabled (Save is disabled while nothing is changed). Saving writes the file, the badge returns to SAVED, and an info toast shows "Backup: &lt;timestamp&gt;/game/config/settings.ini". The activity entry reads "Saved ... ; previous version backed up". Revert asks "Revert to the saved file?" and reloads the saved content (difficulty = hard stays, the extra character is gone).

#### WS-09 · Text Editor: CRLF file game/data/items.csv, find, and Go to line out of range

Platforms: **all**

1. Open game/data/items.csv in the Text Editor (row menu "Open in Text Editor").
2. Press the "Find (Ctrl+F)" icon and type "potion".
3. Press the "Go to line (Ctrl+G)" icon, enter 9999 and try to confirm.
4. Enter 2 and confirm.

**Expected:** The badges show "Endings: CRLF", and the save-ending menu reads "Line endings: CRLF" (options "Save with LF/CRLF/CR"). The find bar (field "Find", chip "Aa") shows a counter "1 / N" and highlights the first match. "No matches" appears for text that is not present. The "Go to line" dialog label is "Line (1-N)", and 9999 is rejected with "Enter a line between 1 and N". Line 2 (rusty-sword) scrolls into view with the cursor on it.

#### WS-10 · Text Editor: binary warning for a PNG, and a device copy that cannot be saved in place

Platforms: **all**

1. From File Browser open game/textures/logo.png with "Open in Text Editor".
2. Press "View as text (read-only)".
3. Close the file, press "Open file" in the header, choose "From device" and pick any .txt from the device.
4. Change the text and press "Save".

**Expected:** Step 1 shows the warning "This looks like a binary file" / "logo.png contains binary data. Editing it as text would corrupt it." with the buttons "Open in Hex Viewer" and "View as text (read-only)". The read-only view shows the READ-ONLY badge and a "Read-only" banner "Binary file shown as text (read-only).", and Save stays disabled. The device file shows the info banner "Device copy". Pressing Save opens the dialog "This is a copy" with the button "Save as...", which leads to the save sheet. The original file on the device is not changed.

#### WS-11 · Hex Viewer: open logo.png, byte search, count, and input errors

Platforms: **all**

1. From File Browser open game/textures/logo.png with "Open in Hex Viewer".
2. With "Search for" on "Hex bytes", type "49 48 44 52" in "Bytes, e.g. DE AD ?? EF" and press the "Next match" arrow, then press "Count".
3. Replace the pattern with "ABC" and press "Next match".
4. In "Offset (dec or 0x hex)" enter 0x10000 and press "Go", then enter 0x10 and press "Go".

**Expected:** The status line shows "10.2 KB (10404 bytes)"-style size text, the page and the cached pages. The search reports "Match at 0x0000000C (12)" (the PNG IHDR chunk) and highlights the bytes. Count shows a "N match(es)" line. "ABC" shows the field error '"ABC" has an odd number of hex digits; write bytes as two digits (0A, not A)'. 0x10000 shows "Offset is beyond the end of the file (10404 bytes)". 0x10 selects and scrolls to row 0x00000010, and "Copy rows" becomes enabled.

#### WS-12 · Find Files: glob, contains and an invalid regex

Platforms: **all**

1. Open Find Files. Leave "Match mode" on "Glob", type "\*.json" in "Pattern" and press "Search".
2. Switch "Match mode" to "Contains", type "backup" and press "Search".
3. Switch to "Regex", type "(" and press "Search".
4. On a result from step 2 open its menu and choose "Show in File Browser".

**Expected:** Glob "\*.json" matches file names at any depth: the results title is "8 matches" (game.json, graphics.json, en.json, hud.json, save.schema.json, slot1.json and the two duplicates/hud\_backup\*.json), plus the caption "N entries scanned in ...". Contains "backup" gives "2 matches". The regex "(" shows the error banner "Invalid input" with "Invalid regular expression: ...", and no scan starts. "Show in File Browser" opens the browser in duplicates/ with the file selected.

#### WS-13 · Search in Files: regex with a glob filter, open the hit at its line, and an invalid regex

Platforms: **all**

1. Open Search in Files and turn on "Regular expression".
2. Type max\_(health|mana)\\s\*=\\s\*\\d+ in the "Regular expression" field and \*.toml in "Only files matching (glob, optional)", then press "Search".
3. Tap the result line "12".
4. Go back, change the pattern to max\_(health and press "Search".

**Expected:** The results panel title is "2 matches in 1 file", with the file row "game/config/balance.toml" (count 2) and the lines 12 (max\_health = 100) and 13 (max\_mana = 50) highlighted. The chips show Searched / Binary skipped / Over 10 MiB / Filtered out / Time. Tapping line 12 opens the Text Editor on game/config/balance.toml at line 12. The broken pattern shows the error banner "Invalid input" / "Invalid regular expression: ..." and no scan runs.

#### WS-14 · Batch Rename: preview, apply and undo on rename-demo/

Platforms: **all**

1. Open Batch Rename, press "Change..." under Folder, open rename-demo and press "Use this folder".
2. Type \*.png in "Only files matching (glob)", "IMG\_" in "Find" and "shot-" in "Replace with".
3. Press "Apply 6 renames" and confirm "Rename".
4. In "Undo a batch rename" press the "Undo this rename" icon and confirm "Undo rename".

**Expected:** The preview title is "6 files will change". Rows show IMG\_0001.png -&gt; shot-0001.png ... IMG\_0006.png -&gt; shot-0006.png, each with the status OK (chip "OK 6"). The confirm dialog is titled "Rename 6 files?" and lists every old -&gt; new name. Afterwards the green banner "Done" reads "Renamed 6 files. Journal: &lt;id&gt;", and the history shows the row "&lt;date&gt; | 6 files" with the badge APPLIED. Undo shows "Restored 6 files", the files are named IMG\_000N.png again, and the journal badge reads UNDONE.

#### WS-15 · Batch Rename: duplicate names and an invalid template token block Apply

Platforms: **all**

1. Keep folder rename-demo and filter \*.png, and clear "Find" and "Replace with".
2. Type "photo" in "Name template (optional)".
3. Change the template to "photo\_{x}".
4. Change the template to "photo\_{n:2}".

**Expected:** With "photo", every row has the status "Duplicate in batch" and the message '6 files would be named "photo.png" (names are compared ignoring case)'. The warning under the list reads "Apply is disabled: fix 6 problems (collisions, duplicates or invalid names)." and Apply is disabled. "photo\_{x}" shows the error banner "Rule problem" with "Template: Unknown token {x}. Use {n}, {n:3}, {name}, {ext}, {parent} or {date}." "photo\_{n:2}" gives photo\_01.png ... photo\_06.png, all OK, and "Apply 6 renames" is enabled (do not apply).

#### WS-16 · Replace in Files: diff preview, per-file selection and apply with backup

Platforms: **all**

1. Open Replace in Files. Enter "permadeath = false" in "Find", "permadeath = true" in "Replace with" and \*.{ini,toml} in "Only files matching (glob, optional)".
2. Press "Preview changes".
3. Untick the checkbox of game/config/settings.ini, then tick it again.
4. Press "Apply to 2 files (2)" and confirm "Replace".

**Expected:** Nothing is written by the preview. The preview title is "2 replacements in 2 files" with the rows game/config/balance.toml and game/config/settings.ini ("1 replacement(s) | &lt;encoding&gt; | LF"). The diffs are expanded, showing a red -permadeath = false and a green +permadeath = true. Unticking changes the button to "Apply to 1 file (1)". The confirm dialog is "Replace in 2 files?" / "2 replacement(s). Every file is backed up first ...". The result banner is "2 replacements in 2 files" with "Originals were backed up to &lt;timestamp&gt; in this workspace's backups (app storage).", the details "changed game/config/..." for both files, and a "Copy backup path" button.

#### WS-17 · Replace in Files: regex on a CRLF file, and a preview that is out of date

Platforms: **all**

1. Turn on "Regular expression". Enter rusty-(\\w+) in "Find (regular expression)", old-$1 in "Replace with" and \*.csv as the glob, then press "Preview changes".
2. Without applying, open game/data/items.csv in the Text Editor, add a character anywhere, save, and return to Replace in Files.
3. Press "Apply to 1 file (1)" and confirm "Replace".
4. Press "Preview changes" again and apply.

**Expected:** The preview lists only game/data/items.csv with "1 replacement(s) | &lt;encoding&gt; | CRLF" and the diff -rusty-sword,... / +old-sword,... . Because the file changed after the preview, the first apply writes nothing to it. The warning banner lists "skipped game/data/items.csv: changed since the preview; preview again". A fresh preview applies cleanly, and reopening items.csv in the editor still shows "Endings: CRLF".

#### WS-18 · Reset sample restores the original files after confirmation

Platforms: **all**

1. In the File Browser or Text Editor, change game/config/settings.ini and delete README.txt in the sample workspace.
2. Open Workspaces and tap "Reset sample" on the NEON DUNGEON (sample) card.
3. Read the dialog, then tap "Reset sample" in it.
4. Open game/config/settings.ini and the workspace root again.

**Expected:** The dialog 'Reset "NEON DUNGEON (sample)"?' explains that every file, imported mod package, profile, journal and backup of this sample is regenerated and that only this sample copy is touched; Cancel changes nothing. After confirming, the report reads 'Sample workspace "NEON DUNGEON (sample)" was reset' with "Restored N files, 7 mod packages and 4 profiles.", settings.ini has its original content and README.txt is back. Only sample workspaces have this button.

### MD · Mods

Before you start:

- The sample workspace "NEON DUNGEON (sample)" is the active workspace. The app creates it on first run; if it is missing, use Mods &gt; "Create sample workspace". Its mod library already holds all 7 packages from samples/packages, and it has the 4 profiles vanilla-plus, hardcore-run, conflict-demo and broken-deps. All 4 target game/.
- Open Mods &gt; Mod Manager. At 900 px or wider the Library, Operations and Profiles panes sit side by side. On a narrower window or a phone they are tabs named "Library (N)", "Profiles (N)" and "Operations (N)".
- Before each profile case, make sure no profile shows the APPLIED badge. If one does, press "Roll back" in that profile's editor. Only one operation per target can be active.
- Package paths below are relative to the workspace root, for example downloads/neon-hud-1.2.0.j3mod. Target paths are relative to game/.
- On Android and iOS, apply works on the app-owned sample workspace copy. Linked folders can only be modified on Windows/Linux.

#### MD-01 · Profile list shows the correct status for each sample profile

Platforms: **all**

1. Open Mods &gt; Mod Manager (on a narrow screen, open the "Profiles (4)" tab).
2. Read the badge on each profile tile in the "Mod profiles (4)" panel.

**Expected:** Each tile shows its name, then "&lt;id&gt;  |  target game  |  X/Y enabled". The badges are: "Vanilla+ HUD" READY, "Hardcore run" READY, "Conflict demo" 1 WARN, "Broken dependencies" 2 ERR. The ⋮ menu on each tile offers Duplicate, Rename, Export .j3profile.json and Delete.

#### MD-02 · vanilla-plus: exact plan dialog, cancel, then apply

Platforms: **all**

1. Tap the "Vanilla+ HUD" tile.
2. In PROFILE EDITOR, check Target "game/" and that the Game row shows Neon Dungeon 1.4.2 read from game.json.
3. Press "Plan & apply".
4. Check the dialog, then press "Cancel".
5. Press "Plan & apply" again and press "Apply 1 change(s)".

**Expected:** The dialog shows "// APPLY PLAN" and "Apply "Vanilla+ HUD"", then "Target: game  |  neon-hud@1.2.0". Chips read "0 CREATE", "1 OVERWRITE", "0 SAME", "0 new folder(s)" and "&lt;size&gt; to write". There is one row: OVERWRITE data/ui/hud.json with "&lt;old size&gt; -&gt; &lt;new size&gt;  |  from neon-hud 1.2.0". Cancel writes nothing and creates no journal. After Apply, a success banner reads "Applied "Vanilla+ HUD"" with "0 files created, 1 file overwritten, 0 unchanged, 0 folders created" and "Operation &lt;id&gt;". The tile gets an APPLIED badge and a red "Roll back" button appears.

#### MD-03 · Journal and backups after an apply

Platforms: **all**

1. With vanilla-plus applied, look at the OPERATIONS panel (narrow screen: the "Operations (1)" tab).
2. On the operation card, press "Details".

**Expected:** The panel is titled "Journal (1)". The card shows an APPLIED badge, "Vanilla+ HUD", then "&lt;date&gt;  |  target game  |  0 create, 1 overwrite, 0 folder(s)", plus "Details" and "Roll back". The card has no delete icon while the operation is open. The "Operation &lt;id&gt;" sheet lists Profile "Vanilla+ HUD (vanilla-plus)", Target game, Packages neon-hud@1.2.0, the Created and Applied times, Unchanged "0 identical file(s) not touched" and the Journal folder path. Under Changes it shows OVERWRITE data/ui/hud.json with "neon-hud 1.2.0  |  &lt;size&gt;  |  applied  |  backup kept".

#### MD-04 · Applying a second profile on the same target asks you to roll back first

Platforms: **all**

1. With vanilla-plus still applied, select "Hardcore run".
2. Press "Plan & apply".
3. Press "Roll back" in the prompt.

**Expected:** A prompt titled "Roll back the applied profile first?" says ""Vanilla+ HUD" is applied to "game". Only one operation per target can be active, so it must be rolled back before "Hardcore run" can be applied. Roll it back now?". Pressing Roll back rolls vanilla-plus back without another confirmation, and the Hardcore run plan dialog opens next. Cancelling the prompt changes nothing.

#### MD-05 · vanilla-plus rollback restores the original

Platforms: **all**

1. Apply "Vanilla+ HUD" without touching any file afterwards.
2. Press "Roll back" in the profile editor.
3. Confirm with "Roll back".

**Expected:** A confirmation titled "Roll back "Vanilla+ HUD"?" says "Restores 1 original file(s) from verified backups and removes 0 created file(s)...". A success banner then reads "Rolled back" with "1 restored, 0 removed, 0 folders removed". game/data/ui/hud.json matches the original sample again. The APPLIED badge and the Roll back button disappear. The journal card now shows ROLLED BACK and a delete icon ("Delete this journal and its backups"), which opens "Delete journal?".

#### MD-06 · Rollback detects a user edit made after applying

Platforms: **all**

1. Apply "Vanilla+ HUD".
2. Open Config Lab &gt; JSON Studio, press "Open" and choose From workspace &gt; game/data/ui/hud.json. Change a value, press "Save" and confirm with "Save with backup".
3. Back in Mod Manager, press "Roll back" on Vanilla+ HUD.
4. Keep the default "Keep my edit" and press "Roll back".
5. Repeat steps 1-3 and choose "Restore original (save my edit first)" before pressing "Roll back".

**Expected:** Instead of the plain confirmation, a "// ROLLBACK CONFLICTS" dialog titled "Files changed after applying" opens. It says "1 file(s) no longer match what "Vanilla+ HUD" wrote..." and has the buttons "Keep all my edits" and "Restore all originals". The entry reads data/ui/hud.json with "Edited after applying  |  overwrite by neon-hud". With Keep my edit, the result is "Rolled back" with "0 restored, 0 removed, 0 folders removed, 1 edit(s) kept", and the edited file stays. With Restore original, the result ends with "1 edit(s) saved then reverted" and adds a detail "Your edit of data/ui/hud.json was saved as operations/&lt;op-id&gt;/...", and the original is restored. Cancel in the dialog does nothing.

#### MD-07 · hardcore-run: dependency order and a 5-file plan

Platforms: **all**

1. Select "Hardcore run" and check LOAD ORDER, DEPENDENCY CHAINS and the resolution banner.
2. On the hardcore-balance row, press the up arrow (tooltip "Move hardcore-balance up (applied earlier)").
3. Read the new error, then press "Sort by dependencies".
4. Press "Plan & apply", check the plan, then press "Apply 5 change(s)".

**Expected:** At first the load order is 01 core-patch, 02 hardcore-balance, 03 neon-hud, and a "Ready" banner reads "All 3 enabled package(s) resolve...". After the move, the tile shows "1 ERR" and "Errors (block applying)" lists "Ordered after dependent: core-patch must be applied before hardcore-balance (use "Sort by dependencies")". The chain shows ORDER and "Plan & apply" is disabled. Sort shows the notice "Load order sorted by dependencies" and restores the original order. The plan shows "1 CREATE", "4 OVERWRITE", "0 SAME" with rows config/balance.toml (hardcore-balance), data/core\_patch.json CREATE (core-patch), data/items.csv, data/localization/en.json and data/ui/hud.json (neon-hud). The result reads "1 file created, 4 files overwritten, 0 unchanged, 0 folders created". Roll back afterwards.

#### MD-08 · hardcore-run: disabling a required dependency blocks apply

Platforms: **all**

1. Select "Hardcore run".
2. Turn off the switch on the core-patch row.
3. Turn it back on.

**Expected:** With core-patch off, the tile shows "1/3" in "2/3 enabled" is wrong; it shows "2/3 enabled", and the error "Missing dependency: hardcore-balance requires core-patch, which is not enabled in this profile" appears. The core-patch row reads "core-patch 1.0.0  |  disabled". "Plan & apply" is disabled with the tooltip "Fix the errors above first". Turning it back on returns the profile to Ready.

#### MD-09 · conflict-demo: overlap report and the warning acknowledgement in the plan

Platforms: **all**

1. Select "Conflict demo".
2. Expand "Overlaps (last one wins)".
3. Press "Plan & apply".
4. Try the Apply button, then tick the checkbox and press "Apply 4 change(s)".
5. Roll back afterwards.

**Expected:** The tile badge is "1 WARN". The overlap group lists config/balance.toml as "hardcore-balance (overridden)" ──&gt; "brutal-mode WINS". In the plan, the config/balance.toml row is OVERWRITE "... | from brutal-mode 0.9.0  |  overrides hardcore-balance". The chips read "1 CREATE" and "3 OVERWRITE". "Apply 4 change(s)" stays disabled, with the tooltip "Confirm that you reviewed the warnings first", until "I reviewed 1 warning(s) and overlap(s)" is ticked. After applying, game/config/balance.toml has brutal-mode's content. Rollback reports "3 restored, 1 removed, 0 folders removed".

#### MD-10 · broken-deps: missing retro-core and the cycle block apply

Platforms: **all**

1. Select "Broken dependencies".
2. Read "Errors (block applying)" and DEPENDENCY CHAINS.
3. Try "Plan & apply".

**Expected:** The tile badge is "2 ERR". The errors list "Missing dependency: legacy-skin requires retro-core ^1.0.0, which is not in the library" and "Dependency cycle: cycle-a -&gt; cycle-b -&gt; cycle-a". The chains mark retro-core MISSING and the cycle-a and cycle-b links CYCLE. "Plan & apply" is disabled with the tooltip "Fix the errors above first", and nothing is written.

#### MD-11 · Import a .j3mod: identical, removed and then re-imported

Platforms: **all**

1. In LIBRARY press "Import package", choose "From workspace "NEON DUNGEON (sample)"" and pick downloads/neon-hud-1.2.0.j3mod.
2. On the Neon HUD card press the delete icon ("Remove Neon HUD from the library") and confirm with "Remove".
3. Check the Vanilla+ HUD profile.
4. Import downloads/neon-hud-1.2.0.j3mod again.
5. On the Neon HUD card press "Details".

**Expected:** The first import shows the info notice "Neon HUD 1.2.0 is already in the library" and adds nothing. The "Remove Neon HUD?" dialog lists "Used by profile "Vanilla+ HUD" (it will report a missing package)" and does the same for Hardcore run. After removal, the vanilla-plus row reads "neon-hud  |  MISSING FROM LIBRARY" with the error "Missing package: neon-hud is not in the library". The re-import shows "imported Neon HUD 1.2.0", the card returns with a VALID badge, and the profiles are READY again. The Details sheet shows the file mapping, "Used by: ..." and "Remove from library".

#### MD-12 · Importing a ZIP that is not a package is rejected

Platforms: **all**

1. Select "Hardcore run" and press "Export result". Save the ZIP to the device (file game-result-&lt;timestamp&gt;.zip).
2. In LIBRARY press "Import package", choose "From device" and pick that ZIP.

**Expected:** A dialog titled "game-result-&lt;timestamp&gt;.zip was not imported" says "The package failed validation. Nothing was copied.". It lists the error j3mod.json "missing: every package needs j3mod.json at the archive root". The library is unchanged.

#### MD-13 · Mod Package Inspector: a valid package and a blocked ZIP

Platforms: **all**

1. Open Mods &gt; Mod Package Inspector and press "Choose package".
2. Choose From workspace, go to downloads/ and pick brutal-mode-0.9.0.j3mod.
3. Check SUMMARY, ISSUES, FILES, RELATIONS, MANIFEST and REPORT.
4. Press "Choose package" again and pick the game-result-&lt;timestamp&gt;.zip from the previous case (From device).

**Expected:** brutal-mode gives "Valid package" and "Brutal Mode 0.9.0 can be imported and applied.", "Validation: 0 error(s), 0 warning(s)" with "No issues found.", and "Mapping (1 file(s))" config/balance.toml &lt;- files/config/balance.toml. README.md is not listed as unmapped. The page also shows the j3mod.json panel and an "Inspection report" containing "result:   VALID". The buttons "Inspect again" and "Import to library" appear. The ZIP gives "Blocked: 1 error(s)" and "This package cannot be imported or applied until the errors below are fixed.", with the missing-j3mod.json error. "Import to library" is not shown for it.

#### MD-14 · Mod Package Builder: live validation, then build into the library

Platforms: **all**

1. Open Mods &gt; Mod Package Builder and type "Bad ID" in "Id".
2. Replace it with "my-hud" and set "Name" to "My HUD" (Version defaults to 1.0.0).
3. Type "data/ui" in "Target prefix (optional)", press "Choose base folder" and pick game/data/ui.
4. Leave "Add to the workspace library" on and press "Build package".

**Expected:** With "Bad ID", the Id field shows ""Bad ID" is not a valid id (2-64 characters: lowercase letters, digits, '.', '\_' or '-', starting with a letter or digit)". The VALIDATION panel reads "N problem(s) to fix" (it also reports that files must not be empty) and "Build package" is disabled. After the fixes, "Files (1/1)" lists hud.json with target data/ui/hud.json and "Base: game/data/ui/", and the panel reads "Ready to build". The j3mod.json preview shows source files/data/ui/hud.json. Building shows the notice "imported My HUD 1.0.0" and a banner "Package built" with "My HUD 1.0.0: 1 file" and the details "Built my-hud-1.0.0.j3mod" and "library: imported My HUD 1.0.0". My HUD then appears in the Mod Manager library.

#### MD-15 · Mobile: apply to the workspace copy, then export the result

Platforms: **mobile**

1. Open Mods &gt; Mod Manager on Android/iOS.
2. Read the info banner at the top.
3. In the Profiles tab, apply "Vanilla+ HUD" with "Plan & apply" &gt; "Apply 1 change(s)".
4. Press "Export result (game/)" in the banner (or "Export result" in the profile editor) and save or share the ZIP.

**Expected:** The banner is titled "Profiles apply to the workspace copy on Android" (or iOS) and says "Profiles are applied to the imported workspace copy. Export the modified files or the whole workspace as a ZIP afterwards. This device cannot modify other apps' folders, so linked workspaces are desktop-only." The apply works on the sample workspace, as on desktop. The export offers game-result-&lt;YYYYMMDD-HHMMSS&gt;.zip, which contains the game/ files including the modified data/ui/hud.json. Roll back afterwards.

### CF · Config Lab

Before you start:

- The sample workspace "NEON DUNGEON (sample)" exists and is the active workspace. Reset it before a test run, because several cases save into it.
- Open each tool from the Config Lab section (/config) by its name: JSON Studio, YAML Editor, TOML Editor, INI Editor, CSV / TSV Table, Config Compare, Config Presets, Save Data Editor.
- To open a sample file: tap "Open" (or "Open file" / "Open document" / "Open JSON file"), choose 'From workspace "NEON DUNGEON (sample)"' in the sheet, browse the folders and tap the file. All paths below are relative to the workspace root.
- Wide windows show the editor and the panes side by side. Narrow screens and phones show one chip row instead ("Editor" plus the tool's panes such as "Tree", "To JSON", "From JSON"). Tap a chip to switch.
- Config Lab has no platform restrictions in the capability matrix. Every case runs on Android, iOS, Windows and Linux unless it is marked otherwise.

#### CF-01 · JSON Studio: open, stats, format with 4 spaces and undo

Platforms: **all**

1. Open JSON Studio, tap "Open" and pick game/config/graphics.json.
2. Check the document bar and the status line.
3. Open the "Stats" pane.
4. Under "Indent (format, sort and tree edits)" pick "4 spaces", then tap "Format".
5. Tap the undo button, which now reads "Undo format".

**Expected:** The document bar shows game/config/graphics.json with the WORKSPACE and UTF-8 badges and no MODIFIED badge. The status line shows a VALID badge and '&lt;n&gt; objects, &lt;n&gt; arrays, &lt;n&gt; keys, depth &lt;n&gt;, &lt;size&gt;'. The Stats pane (STATISTICS / "Document shape") lists Size, Lines, Max depth, Objects, Arrays, Properties, Strings, Numbers, Booleans, Nulls (2: customShader, gpuOverride), Longest array and Warnings. Format re-indents the text with 4 spaces and the MODIFIED badge appears. "Undo format" restores the original text; the undo button goes back to a disabled "Undo" and MODIFIED disappears.

#### CF-02 · JSON Studio + terminal: trailing comma is reported with line:column and Jump to error

Platforms: **all**

1. In JSON Studio, tap "Clear" if the editor has text (confirm "Clear"), then type {"a": 1,}
2. Look at the status line and the PARSE ERROR panel.
3. Tap "Jump to error".
4. Open the Terminal (Ctrl+\` on desktop, or the Terminal tool) and run: json validate '{"a": 1,}'

**Expected:** The status shows an INVALID badge with 'line 1, column 8: Trailing comma is not allowed in JSON'. The PARSE ERROR panel is titled "Line 1, column 8" and shows the message and a caret snippet. Format, Minify and Sort keys are disabled (tooltip 'Needs valid, validated JSON'). "Jump to error" moves the cursor to the comma; on a phone it first switches to the "Editor" chip. The terminal prints the error line 'input:1:8: Trailing comma is not allowed in JSON' followed by the snippet, with exit code 1.

#### CF-03 · JSON Studio: tree edit, undo and field search

Platforms: **all**

1. Open game/config/graphics.json in JSON Studio and open the "Tree" pane. Tap "Expand all".
2. Open the actions menu of the fpsLimit row (tooltip 'Actions for $.display.fpsLimit') and choose "Edit value…".
3. In the dialog 'Edit $.display.fpsLimit', keep Type Number, enter 60 and tap "Apply".
4. Tap "Undo edit value".
5. Open the "Search" pane, type bloom in "Find in keys and values" and tap "Search".
6. On one hit, tap the "Show in tree" icon.

**Expected:** After Apply the whole document is re-serialised with the selected indent and fpsLimit is 60 in the text. MODIFIED appears and the undo button reads "Undo edit value". Undo restores the previous text (fpsLimit 144). Search lists matches such as $.postfx.bloom and $.presets\[0\].bloom, each marked 'KEY = …'. The pane chip shows the hit count ('Search (n)'). "Show in tree" switches to the Tree pane and reveals that node.

#### CF-04 · YAML Editor: controls.yaml to JSON itemises comments and expanded aliases

Platforms: **all**

1. Open YAML Editor, tap "Open" and pick game/config/controls.yaml.
2. Tap "Validate".
3. Open the "Tree" pane and expand keyboard &gt; look.
4. Tap "Convert to JSON" in the toolbar.

**Expected:** The notice reads 'Valid YAML (1 document)' and the status shows VALID with '1 document'. The read-only tree (root 'document') shows keyboard.look already expanded to sensitivity / invert\_y / deadzone. The app switches to the "To JSON" pane. The CONVERSION REPORT 'YAML -&gt; JSON' shows the CHANGES REPRESENTATION badge with groups 'CHANGE // Comments dropped (n)' (each with its line, e.g. L1) and 'CHANGE // Anchors/aliases expanded (2)' ('Alias … expanded into a full copy of the anchored value…', paths $.keyboard.look and $.gamepad.look). An OUTPUT panel holds the JSON.

#### CF-05 · YAML Editor on a phone: pane chips and From JSON (verified YAML)

Platforms: **mobile**

1. On a phone, open YAML Editor and check the chip row under the toolbar.
2. Tap the "From JSON" chip and type {"answer": "yes", "count": 3} in the JSON field.
3. Tap "Convert to YAML".
4. Tap the 'Use as editor text' icon on the OUTPUT panel, then tap the "Editor" chip.

**Expected:** Phones start on the "Editor" chip; the chips are Editor, Tree, To JSON, From JSON. The report 'JSON -&gt; YAML' shows LOSSLESS and ROUND TRIP VERIFIED with a 'NOTE // Quoting added' entry for $.answer. The output is answer: "yes" and count: 3 ("yes" is quoted so that YAML 1.1 readers keep it a string). If the editor had unsaved text, 'Replace the editor text?' asks first. Then the notice 'Editor text replaced with the converted output' appears and the Editor chip shows the YAML.

#### CF-06 · TOML Editor: balance.toml tree and TOML to JSON date-time report

Platforms: **all**

1. Open TOML Editor, tap "Open" and pick game/config/balance.toml.
2. Tap "Validate".
3. Open the "Tree" pane and look at last\_tuned and season\_start.
4. Tap "Convert to JSON".

**Expected:** The notice reads 'Valid TOML (9 top-level keys)' and the status shows VALID with '9 top-level key(s)'. The tree (root 'document') labels last\_tuned and season\_start with a 'date' chip, and enemies is an array of 5 tables. The report 'TOML -&gt; JSON' shows CHANGES REPRESENTATION with 'CHANGE // Comments dropped' (lines 1-2), 'CHANGE // Date-time converted to string (2)' (… became the ISO-8601 string "2026-09-01T12:00:00Z" / "2026-09-01") and a NOTE 'Number notation normalised' for the max\_gold = 999\_999 line.

#### CF-07 · TOML Editor: JSON to TOML refuses nulls unless "Drop null properties" is on

Platforms: **all**

1. In TOML Editor open the "From JSON" pane, tap "Open JSON file" and pick game/config/graphics.json.
2. Leave "Drop null properties" off and tap "Convert to TOML".
3. Turn "Drop null properties" on and tap "Convert to TOML" again.

**Expected:** First run: FAILED badge, '… error(s): conversion refused.', 'ERROR // Null not supported (2)' for $.customShader and $.gpuOverride with 'TOML has no null value; remove it, give it a value, or enable "Drop null properties"'. No OUTPUT panel. Second run: CHANGES REPRESENTATION plus ROUND TRIP VERIFIED, with the same two paths now as CHANGE 'null property dropped (TOML has no null)' and a 'Key order changed' change for $. An OUTPUT 'TOML (&lt;size&gt;)' panel appears.

#### CF-08 · INI Editor: lossless value edit and save with backup

Platforms: **all**

1. Open INI Editor, tap "Open" and pick game/config/settings.ini.
2. Open the "Table" pane and tap the edit icon of width (tooltip 'Edit value of width').
3. In 'Edit \[Display\] width' (field 'Value (line 10)') enter 2560 and tap "Apply".
4. Tap "Save" in the document bar.
5. In the 'Replace game/config/settings.ini?' dialog tap "Save with backup".

**Expected:** The status shows VALID with '27 keys in 4 sections'. After Apply the notice reads 'Line 10 updated; every other line is unchanged.' and only line 10 of the text changes (comments, spacing and blank lines are untouched); MODIFIED appears. The confirm dialog explains the backup and lists '1 line(s) added, 1 line(s) removed' and 'Encoding: UTF-8'. After saving, the SAVED badge and a receipt line 'SAVED &lt;time&gt; -&gt; game/config/settings.ini  |  backup: backups/&lt;timestamp&gt;/game/config/settings.ini' appear, with a 'Copy backup path' button.

#### CF-09 · INI Editor: INI to JSON report and invalid section header

Platforms: **all**

1. With game/config/settings.ini open in INI Editor, tap "Convert to JSON" (leave 'Infer numbers and booleans (changes representation)' off).
2. Turn 'Infer numbers and booleans (changes representation)' on and tap "Convert to JSON" again.
3. In the editor, type \[Broken on the empty last line (line 44).
4. Tap "Validate".

**Expected:** First conversion: CHANGES REPRESENTATION with 'CHANGE // Comments dropped (8)' and a 'NOTE // Quotes removed' entry for output\_device ('Quotes "…" removed'); all values are JSON strings. With inference on, a 'Types inferred' group is added (for example "1920" became an integer 1920). After typing \[Broken, the status shows INVALID '1 invalid line(s)'. The Problems list shows L44 'Unterminated section header (missing "\]")', and Validate shows the notice '1 invalid line(s); first at line 44'.

#### CF-10 · CSV / TSV Table: items.csv preview, filter, stats and CSV to JSON

Platforms: **all**

1. Open CSV / TSV Table, tap "Open" and pick game/data/items.csv.
2. Open the "Table" pane and type legendary in "Filter rows".
3. Open the "Stats" pane.
4. Open the "Convert" pane, choose Target "JSON" and JSON shape 'Array of objects (header keys)', then tap "Convert".
5. Turn on 'Infer numbers, booleans and null (changes representation)' and tap "Convert" again.

**Expected:** The status shows VALID with '21 records, 6 columns, comma-separated (detected)' and the Delimiter chip reads 'Auto (Comma)'. The table header shows id/name/type/damage/price/rarity; one cell holds Bow, Short and another holds The "Laughing" Skull. The filter shows '2 of 20 rows match' (void-gem, laughing-skull). Stats shows Records '21 (1 header + 20 data)', Ragged rows 0, Line endings 'CRLF, final newline' and Byte order mark 'none'. The first conversion is LOSSLESS (all values are strings). With inference on, it is CHANGES REPRESENTATION with a 'Types inferred' group and damage/price become numbers.

#### CF-11 · CSV / TSV Table: enemies.tsv to CSV, and an unterminated quote

Platforms: **all**

1. Open game/data/enemies.tsv in CSV / TSV Table and open the "Stats" pane.
2. Open "Convert", choose Target 'CSV (comma)' and tap "Convert".
3. Tap "Clear" (confirm "Clear"), then type two lines: id,name and 1,"Potion
4. Tap "Parse".

**Expected:** The status shows '10 records, 8 columns, tab-separated (detected)'. Stats shows 'Delimiter Tab (auto-detected)' and 'Empty cells 1 of 80' (mimic has no weakness). The conversion is LOSSLESS with ROUND TRIP VERIFIED, and the output uses commas. With the broken text, the status turns INVALID with 'Quoted field is never closed (missing ")'. The 'Parse problems' list shows the error at line 2, column 3, and Parse shows the notice 'Parse error: Quoted field is never closed (missing ") (line 2)'.

#### CF-12 · Config Compare: semantic and text diff of the HUD backup, side-by-side view and report export

Platforms: **all**

1. Open Config Compare. In panel 'A // BEFORE' tap "Open file" and pick game/data/ui/hud.json.
2. In panel 'B // AFTER' tap "Open file" and pick duplicates/hud\_backup\_old.json.
3. Tap "Compare".
4. Under "Text diff view" choose "Side by side".
5. Tap "Export report" and save it to the workspace.

**Expected:** The Format chips read 'Auto (JSON)'. The SUMMARY shows '+0 ADDED', '-0 REMOVED', '\~1 CHANGED', '!0 TYPE' and 'TEXT +1 -1'. The SEMANTIC DIFF panel reads '1 change(s) in the data' with a CHANGED entry $.elements\[0\].x (16 -&gt; 18). The TEXT DIFF panel is titled '+1 / -1 lines' and shows the x line in red and green, in two columns after switching to Side by side. Export report opens the save sheet 'Save "config-comparison.txt"'.

#### CF-13 · Config Compare: JSON vs YAML with the same data, then a parse error

Platforms: **all**

1. In Config Compare, clear both sides. In Document A type {"a": 1, "b": "x"}
2. In panel B pick the Format chip "YAML" and type two lines in Document B: b: x and a: 1.0
3. Tap "Compare".
4. Change Document B to b: \[x and tap "Compare" again.

**Expected:** The SUMMARY title reads 'A (JSON) vs B (YAML)'. Badges show 'SAME DATA', '+0 ADDED', '-0 REMOVED', '\~0 CHANGED', '!0 TYPE' (key order is ignored and 1 equals 1.0). The hint 'Same data, different text: only formatting, order or comments differ.' is shown and there is no SEMANTIC DIFF panel. After the second compare, a 'B: PARSE ERROR' panel appears with a line/column title and a "Jump to error" button.

#### CF-14 · Config Presets: create a preset, preview and apply to graphics.json with backup

Platforms: **all**

1. Open Config Presets and tap "New preset".
2. Enter Name FPS 60 and 'Merge patch (JSON)' {"display": {"fpsLimit": 60}, "debug": {"showFps": true}}, then tap "Save preset".
3. In the APPLY panel tap "Open sample graphics.json".
4. Tap "Preview changes".
5. Tap "Apply & save with backup", then tap "Save with backup" in 'Replace game/config/graphics.json?'.

**Expected:** While typing, the dialog shows 'Valid patch: 2 change(s) - $.display.fpsLimit = 60; $.debug.showFps = true'. The notice reads 'Preset "FPS 60" created' and the preset is selected (panel 'Apply "FPS 60"'). The target bar shows game/config/graphics.json with a WORKSPACE badge. The PREVIEW panel '"FPS 60": 2 change(s)' shows '+0 ADDED', '-0 REMOVED', '\~2 CHANGED' and a TEXT badge, lists '\~ $.display.fpsLimit: 144 -&gt; 60' and '\~ $.debug.showFps: false -&gt; true', and shows the changed lines. After saving, a receipt line 'SAVED &lt;time&gt; -&gt; game/config/graphics.json  |  backup: backups/&lt;timestamp&gt;/game/config/graphics.json' appears under the target bar.

#### CF-15 · Config Presets: built-ins are read-only, duplicate works, a non-preset import is refused

Platforms: **all**

1. In Config Presets, open the actions menu of "Potato mode" (tooltip 'Actions for Potato mode').
2. Choose "Duplicate as my preset".
3. Open the actions menu of "Potato mode (copy)".
4. Tap "Import" and pick game/config/graphics.json.

**Expected:** The Potato mode tile shows 'EXAMPLE · BUILT-IN', '13 change(s)' and 'Written for: game/config/graphics.json'. Its menu offers only "Duplicate as my preset" and "Export…". Duplicating shows the notice 'Created editable copy "Potato mode (copy)"', and the copy's menu also has "Edit…", "Rename…" and "Delete…". "Export mine" becomes enabled. Importing graphics.json shows the error notice 'Import: Not a preset file. Expected {"v":1,"items":\[...\]}, a list of presets, or {"name":..., "patch":...}' and adds nothing.

#### CF-16 · Save Data Editor: sample save, schema form, bound violation, confirm on save, stepper clamp

Platforms: **all**

1. Open Save Data Editor and tap "Open sample save" in the document bar.
2. In the "Form" pane, open the Player panel and set the gold field to 1000000.
3. Open the "Issues" pane.
4. Tap "Save" and then "Cancel" in the dialog.
5. Back in "Form", tap the "Increase gold" (+) button next to gold.

**Expected:** The support banner reads 'Supported: JSON save files described by a JSON schema (subset)…'. The notice 'Schema found next to the save: save.schema.json' appears, the schema bar reads 'Schema: save.schema.json' and the status shows 'VALID SAVE' with 'Matches the schema.'. The gold helper reads 'min 0 · max 999999 · whole number'. After entering 1000000 the status shows '1 ISSUE' with 'Does not match the schema. See the Issues tab.' and the chip reads 'Issues (1)'. The Issues pane lists '/player/gold  \[maximum\] must be &lt;= 999999 (is 1000000)' with a 'Show /player/gold in the raw JSON' button. Save opens 'Save with 1 schema issue(s)?' ('Save anyway'); Cancel writes nothing. The + button clamps gold to 999999 and the status returns to VALID SAVE.

#### CF-17 · Built-in preset "Potato mode" on the sample graphics.json keeps the file structure

Platforms: **all**

1. Open Config Presets and tap the "Potato mode" tile so the panel reads 'Apply "Potato mode"'.
2. Tap "Open sample graphics.json", then "Preview changes".
3. Tap "Apply & save with backup", then "Save with backup".
4. Open game/config/graphics.json in JSON Studio.

**Expected:** The preview is titled '"Potato mode": 12 change(s)' with '+0 ADDED', '-0 REMOVED' and '\~12 CHANGED' and no type changes; it includes '\~ $.display.fpsLimit: 144 -&gt; 30'. After saving, display.fpsLimit is 30, resolution.renderScale 0.5, quality.preset "low", and every postfx entry is still an object (for example bloom keeps "intensity": 0.65 with "enabled": false). A backup of the previous file is written. "Ultra" works the same way (9 changes on the unmodified sample).

### AS · Asset Lab

Before you start:

- The sample workspace "NEON DUNGEON (sample)" exists and is the active workspace (the app creates it on first run). All paths below are relative to that workspace root, for example game/sprites/hero\_walk.png. The same files are in the repo under samples/neon-dungeon/.
- Open an image by pressing the tool's open button, choosing 'From workspace "NEON DUNGEON (sample)"' in the bottom sheet and browsing to the file. 'From device' uses the system picker and imports a copy.
- Every Save / export button opens a sheet titled Save "&lt;file name&gt;". It offers 'Save to workspace "NEON DUNGEON (sample)"' and 'Export...' on all platforms, and 'Share...' only on Android/iOS. Saving to the workspace never overwrites: an existing name brings up a 'File already exists' dialog with 'Save as new file'.
- Sample facts: game/sprites/hero\_walk.png is 128x64 (4x2 frames of 32x32). game/sprites/items/\*.png are six 32x32 RGBA icons (gem, key, potion, shield, skull, sword). game/textures/logo.png is 256x128 RGBA with transparency. Pixel (0,0) of potion.png is fully transparent.

#### AS-01 · Asset Lab landing lists the five tools and the format matrix

Platforms: **all**

1. Open the Asset Lab section from the navigation.
2. Look at the tool grid.
3. Scroll to the 'What the Asset Lab reads and writes' panel.

**Expected:** The grid shows Image Studio, Sprite Sheet, Atlas Packer, Color Lab and App Icon Export. The 'Formats' panel has a 'Reads' row listing the decodable extensions in upper case. Its 'Writes' row reads: PNG, JPEG (no alpha), WebP, GIF (no alpha), BMP, TGA, TIFF, ICO (&lt;=256px).

#### AS-02 · Image Studio: open logo and read its metadata

Platforms: **all**

1. Open Image Studio and press 'Open image'.
2. Choose 'From workspace "NEON DUNGEON (sample)"' and pick game/textures/logo.png.
3. Read the table in the Input panel.

**Expected:** The panel title becomes 'logo.png' and the button changes to 'Open another'. The table shows Format PNG, Dimensions '256 x 128 px', Channels '4 (has alpha)', Bits/channel 8, Frames 1 and Location 'workspace: ...'. The Preview panel shows 'Before (source)' or 'After (256 x 128)' with a Before/After 'Compare' choice.

#### AS-03 · Image Studio: pipeline with undo, redo and reset

Platforms: **all**

1. With logo.png open, choose 'Flip' under 'Add an operation' and press 'Flip horizontal'.
2. Choose 'Rotate' and press '90°'.
3. Press the Undo icon, then the Redo icon.
4. Press the 'Reset (remove all operations)' icon, then Undo.

**Expected:** Step 01 'Flip horizontal' shows '-&gt; 256 x 128' and step 02 'Rotate 90°' shows '-&gt; 128 x 256'. Undo removes step 02 and Redo restores it. Reset removes every step and shows 'No operations yet: the export equals the source.'. Undo after Reset brings both steps back. The Export 'Result' row follows the final size (128 x 256 px).

#### AS-04 · Image Studio: an out-of-bounds crop is rejected

Platforms: **all**

1. With logo.png open and no operations, choose 'Crop'.
2. Enter X 200, Y 0, Width 100, Height 50.
3. Press 'Add crop'.

**Expected:** A red status line reads 'Crop: X + width = 300 exceeds the image width 256.' and no crop step is added. Change Width to 56 and press 'Add crop' again: the step 'Crop 56x50 at (200, 0)' is added with '-&gt; 56 x 50'.

#### AS-05 · Image Studio: JPEG flattening warning and default output name

Platforms: **all**

1. With logo.png open, choose 'JPEG' in the Export panel's 'Format' row.
2. Read the warning and the File name field.
3. Press 'Save / export' and cancel the sheet.

**Expected:** A 'Flatten onto' colour field appears, set to #FFFFFF by default, together with a 'Quality: 90' slider. A warning titled 'JPEG has no transparency' says the transparent pixels will be flattened onto #FFFFFF. The File name reads 'logo\_edited.jpg'. The result table shows 'Alpha: flattened onto #FFFFFF'. Cancelling the save sheet writes no file.

#### AS-06 · Image Studio: ICO export blocks images over 256 px

Platforms: **all**

1. Open game/sprites/hero\_walk.png in Image Studio.
2. Choose 'Resize', enter Width px 512 (aspect lock on: Height px changes to 256) and press 'Add resize'.
3. In the Export panel choose 'ICO'.

**Expected:** A caption reads 'ICO supports up to 256 x 256 px.'. An error banner titled 'Cannot export yet' says 'ICO images can be at most 256x256 px; this image is 512x256. Add a resize step first.', and 'Save / export' is disabled.

#### AS-07 · Image Studio: 'Save next to original' writes a new file

Platforms: **all**

1. Open game/textures/logo.png from the workspace and add 'Flip vertical'.
2. Leave Format on PNG and press 'Save next to original'.
3. Press it a second time.

**Expected:** The first save shows 'Saved as game/textures/logo\_edited.png (original untouched).'. The second save writes 'logo\_edited (2).png' and does not overwrite the first. logo.png itself is unchanged.

#### AS-08 · Sprite Sheet: auto grid, animation and frames ZIP

Platforms: **all**

1. Open Sprite Sheet, press 'Open sheet' and pick game/sprites/hero\_walk.png from the workspace.
2. Check the grid status line and the Animation panel.
3. Press Play, then Pause, then 'Next frame'.
4. Press 'Export frames (ZIP)' and save through the sheet.

**Expected:** The sheet line reads 'Sheet: 128 x 64 px, RGBA'. 'Grid by' is 'Frame size' with Frame W 32 and Frame H 32. The status line reads '4 x 2 grid of 32 x 32 px, 8 of 8 cells used.' and the overlay title is 'Grid overlay (8 frames)'. 'Base name' is 'hero\_walk' and the preview reads 'hero\_walk\_000.png, hero\_walk\_001.png ... hero\_walk\_007.png'. The animation title goes 'Frame n / 8'. The save sheet is titled 'Save "hero\_walk\_frames.zip"' and the ZIP holds 8 PNGs of 32x32 each.

#### AS-09 · Sprite Sheet: a grid or frame count that does not fit is refused

Platforms: **all**

1. With hero\_walk.png open, type 5 into 'Columns (auto)'.
2. Clear Columns, then type 9 into 'Frames (all)'.

**Expected:** With 5 columns, an error banner 'Grid does not fit' reads 'The grid needs 160x64 px but the sheet is 128x64 (columns exceed the width by 32 px).' With Frames 9 it reads 'Frame count 9 is larger than the 8 cells of a 4 x 2 grid.' While either error shows, the export buttons are disabled and the Animation panel shows 'Preview unavailable'.

#### AS-10 · Sprite Sheet: animated GIF export

Platforms: **all**

1. With hero\_walk.png open and a valid 4 x 2 grid, find the 'Animated GIF' section.
2. Pick the 'Black' preset under 'GIF background'.
3. Press 'Export animated GIF' and save through the sheet.

**Expected:** At the default 12 FPS the caption reads 'Delay 8/100 s per frame (12.5 fps), loops forever. GIF has no partial transparency: frames are flattened onto the background.' The save sheet is titled 'Save "hero\_walk.gif"'. The saved GIF plays 8 frames of 32x32 on black and loops.

#### AS-11 · Atlas Packer: pack the item icons and check the JSON

Platforms: **all**

1. Open Atlas Packer and press 'Add workspace folder'.
2. Browse to game/sprites/items and press 'Use this folder'.
3. Leave the defaults ('Atlas name' atlas, 'Padding px' 2, 'Extrude edges' Off, 'Maximum atlas size' 2048) and press 'Pack atlas'.
4. Read the result panel and the 'atlas.json' panel, and tap a sprite in the preview.

**Expected:** The panel title reads 'Sprites (6)' with the rows gem, key, potion, shield, skull and sword, each 32x32. A green banner 'Validator passed' reads '6 frames, no overlaps (...), all inside W x H with 2 px padding and 0 px extrusion.' The JSON has meta.format "j3atlas", version 1, image "atlas.png", padding 2 and extrude 0, and six frames in name order, each with w/h/sourceW/sourceH 32. Tapping a sprite shows '&lt;name&gt;  x=.. y=.. w=32 h=32'. 'Export ZIP (PNG + JSON)' saves atlas.zip.

#### AS-12 · Atlas Packer: duplicate names, rename and stale result

Platforms: **all**

1. After packing the six items, press 'Add workspace folder' and pick game/sprites/items again.
2. Press the rename icon on 'gem' and enter key.
3. Change 'Extrude edges' to '1 px'.
4. Press 'Pack atlas' again.

**Expected:** Six warnings appear, such as 'Skipped gem.png: the name "gem" is already used (rename one of them first).', and the count stays at 6. The rename dialog shows 'Another sprite is already called "key"' and does not accept the name. After changing Extrude the result shows 'Inputs changed since this pack. Press "Pack atlas" again.'. After packing again the JSON has "extrude": 1 and the validator passes.

#### AS-13 · Atlas Packer: a sprite too large for the maximum size

Platforms: **all**

1. Press 'Remove all sprites'.
2. Press 'Add workspace folder' and pick game/textures (it holds only logo.png).
3. Select '256' under 'Maximum atlas size' and press 'Pack atlas'.

**Expected:** The result panel is titled 'Could not pack' with the error 'Atlas not created'. The message reads 'Sprite "logo" (256x128) plus padding/extrusion needs a 260 px side, larger than the 256 px maximum.', and the hint reads 'Raise the maximum size, lower the padding, or split the sprites over several atlases.'. Choosing 512 and packing again succeeds.

#### AS-14 · Color Lab: formats, WCAG contrast and invalid HEX

Platforms: **all**

1. Open Color Lab.
2. Read the Picker title and the contrast panel title and badges.
3. Type #12345 into the 'HEX' field.
4. Replace it with rgb(255 255 255) in the 'RGB(A)' field, then press 'Swap foreground and background'.

**Expected:** The tool starts on #FF163B with background #050507. The title reads 'Contrast 5.27 : 1' and the badges read: AA normal text PASS (4.5:1), AA large text PASS, AAA normal text FAIL (7.0:1), AAA large text PASS (4.5:1), AA UI components PASS. The HEX field shows the error 'HEX colours have 3, 4, 6 or 8 digits; "#12345" has 5'. White on #050507 gives a contrast of about 20 with every badge PASS. Swap exchanges the two colours and the ratio stays the same.

#### AS-15 · Color Lab: eyedropper on a transparent pixel

Platforms: **all**

1. In Color Lab press 'Load image' and pick game/sprites/items/potion.png from the workspace.
2. Tap the very top-left corner pixel of the image.
3. Tap the red body of the potion.

**Expected:** The status reads 'Picked (0, 0) -&gt; #00000000'. The contrast panel adds 'The foreground is translucent: it is blended over the background (#050507) first.' and shows a ratio of 1.00. Tapping the red body updates the picker and the formats to that pixel's opaque colour and shows 'Picked (x, y) -&gt; #RRGGBB'.

#### AS-16 · Color Lab: saved palette and exports survive a restart

Platforms: **all**

1. Set the colour back to #FF163B and press 'Add to palette'.
2. Choose each 'Export format' in turn: JSON, GIMP .gpl, HEX list, CSS variables.
3. Close and reopen the app, then open Color Lab.

**Expected:** 'Palette (1)' lists a swatch named '#FF163B'. JSON shows format "j3palette" and version 1 with hex "#FF163B" and rgba \[255, 22, 59, 255\]. GPL starts with 'GIMP Palette' and has the line '255  22  59	#FF163B'. HEX list shows '#FF163B'. CSS shows ':root {' with '--ff163b: #ff163b;'. The panel titles are palette.json, palette.gpl, palette.txt and palette.css. After the restart the swatch is still listed.

#### AS-17 · App Icon Export: non-square logo, generate and verify

Platforms: **all**

1. Open App Icon Export, press 'Open artwork' and pick game/textures/logo.png from the workspace.
2. Leave 'Non-square source' on 'Pad to square' and all three platform switches on.
3. Press 'Generate & verify'.
4. Press 'Export all (ZIP)'.

**Expected:** A warning reads 'The artwork is 256 x 128, not square. Choose how to make it square:' along with the note 'Smaller than 1024 px...'. The result title reads '30 files, &lt;size&gt;', and the banner 'All outputs verified' reads '30 of 30 files passed after decoding them again.'. Its notes include 'Source 256x128 is not square: padded to 256x256.' and 'Master is 256x256: larger icons are upscaled...'. The previews are Android 192, Adaptive (masked), iPhone 180 and Play 512, and every Verification row shows PASS. The save sheet is titled 'Save "app\_icons.zip"'.

#### AS-18 · App Icon Export: no platform selected, then a stale result

Platforms: **all**

1. With logo.png generated, switch off 'Android + Google Play', 'iOS' and 'Windows'.
2. Switch 'Windows' back on.

**Expected:** With no platform on, 'Generate & verify' is disabled and the warning 'Select at least one platform.' appears. The existing result shows 'Settings changed since generating. Generate again to update.'. Generating with only Windows gives '1 files' (windows/runner/resources/app\_icon.ico), and its verification row passes.

#### AS-19 · Save sheet offers Share on mobile only

Platforms: **mobile**

1. On Android or iOS, open game/sprites/items/sword.png in Image Studio.
2. Press 'Save / export'.
3. Choose 'Share...' and pick any target app.

**Expected:** The sheet 'Save "sword\_edited.png"' lists 'Save to workspace "NEON DUNGEON (sample)"', 'Export...' and 'Share...'. Share hands a PNG to the system share sheet. On Windows or Linux the same sheet has no 'Share...' option.

#### AS-20 · Terminal: wcag, colorfmt and imginfo

Platforms: **all**

1. Open the terminal.
2. Run: wcag #FF163B #050507
3. Run: colorfmt #FF163B
4. Run: imginfo game/textures/logo.png
5. Run: wcag #FF163B

**Expected:** wcag prints '#FF163B on #050507: 5.27:1' followed by PASS/FAIL lines, including 'FAIL AAA normal text (needs 7.0:1)'. colorfmt prints the lines 'HEX   #FF163B', 'RGBA  rgb(255, 22, 59)', HSL, HSV and 'ARGB  0xFFFF163B'. imginfo prints 'logo.png: PNG', 'size      256 x 128 px' and 'channels  4 (alpha)'. The final wcag with one colour prints the error 'Expected two colours' with its usage line.

### FT · File Tools

Before you start:

- Start from a fresh "Neon Dungeon" sample workspace and make it the active workspace. If other tests already changed it, reset it from the Workspaces section first. Several cases below rewrite, move or add files, so run the cases in the order listed.
- Every path below is relative to the sample workspace root. The workspace browser opens from buttons such as "Workspace file" and "Workspace folder", or through the "From workspace "&lt;name&gt;"" entry in the open-file sheet.
- Reference digests come from samples/SHA256SUMS.txt in the repo. The file is not inside the app workspace. Its entries start with "neon-dungeon/"; that prefix is the workspace root. Examples: game/game.json = 7ee35ab9ba1717ab5c129102cbd20bda158cf7f75fc0c01214f9e0c917ebe4bb, downloads/neon-hud-1.2.0.j3mod = d8e1441078cf4626f140efdf70aaf1572041f367107dcb2b5e7d5c4ef2b883e0, duplicates/hud\_backup.json = game/data/ui/hud.json = d455cb4b5ec2bb1e633ba77e40e7dc6900da459a242223e9637d145b45fbcfc0, game/config/balance.toml = da96eee0e5f8c94c457955e4e4cbb9bca63fb2c31f9984fc179f98f81e4903a1.
- Open each tool from the File Tools section: Hash & Checksum, Duplicate Finder, Line Endings, Whitespace Cleanup, ZIP Studio, Log Viewer. The terminal is under System &gt; Terminal (Ctrl+\` on desktop).
- Case 11 needs a writable device folder (for example Downloads) for the system save dialog and file picker.

#### FT-01 · Hash text: known SHA-256, expected-digest MATCH/MISMATCH and algorithm suggestion

Platforms: **all**

1. Open Hash & Checksum. Under "Input" select "Text" and leave "Digest algorithm" on "SHA-256".
2. Type test (4 characters, no newline) into "Text to hash".
3. In "Paste the published checksum" enter SHA256:9F86D081884C7D659A2FEAA0C55AD015A3BF4F1B2B0B822CD15D6C15B0F00A08.
4. Change the last character of the pasted value to 9.
5. Replace the expected value with 098f6bcd4621d373cade4e832627b4f6 and tap "Use MD5".

**Expected:** Step 2: the digest card shows 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 with the caption "4 bytes of UTF-8". Step 3: the banner reads "MATCH" / "The expected digest equals the digest of the text." The prefix and upper case are ignored. Step 4: the banner reads "MISMATCH" / "...Check the algorithm and the input." Step 5: before the tap, the hint says "This digest has the length of MD5, not SHA-256." After the tap, the algorithm chip is "MD5 (legacy)", the warning badge "compatibility only — not collision resistant" appears, and the banner returns to MATCH.

#### FT-02 · Hash a workspace file and compare with the published SHA-256

Platforms: **all**

1. In Hash & Checksum, under "Input" select "Files".
2. Tap "Workspace file" and pick downloads/neon-hud-1.2.0.j3mod.
3. Tap "Hash 1 file".
4. In "Paste the published checksum" paste d8e1441078cf4626f140efdf70aaf1572041f367107dcb2b5e7d5c4ef2b883e0.
5. Tap "Clear" in the Files panel.

**Expected:** Step 3: the result panel title is "SHA-256 · 1 file" and the row shows the badge "OK" and the digest d8e1441078cf...883e0. Step 4: the banner reads "MATCH" / "The expected digest equals the SHA-256 of downloads/neon-hud-1.2.0.j3mod." and the row badge changes to "MATCH". A wrong digest shows "MISMATCH" / "None of the 1 SHA-256 digests equals the expected value." Step 5: the list returns to the empty state "No files yet".

#### FT-03 · Generate SHA256SUMS next to files, then verify it (round trip)

Platforms: **all**

1. In Hash & Checksum, under "Input" select "Files". Tap "Clear" if files are listed, then tap "Workspace folder" and choose duplicates.
2. Tap "Hash 3 files", then tap "Save next to files".
3. Under "Input" select "Verify list". Keep "Source" on "Checksum file" and "Algorithm" on "Auto-detect".
4. Tap "Choose checksum file", choose the workspace entry and pick duplicates/SHA256SUMS.
5. Tap "Verify".

**Expected:** Step 2: the info line says the paths are relative to "duplicates" in GNU coreutils format. A notice "Saved duplicates/SHA256SUMS" appears; an existing file is never replaced (a second save gives "SHA256SUMS (2)"). The digests of hud\_backup.json and potion (copy).png match the samples/SHA256SUMS.txt entries. Step 4: "Paths are relative to" shows duplicates. Step 5: the banner reads "ALL OK" / "Every listed file matches (3).", the stat tiles read OK 3, FAILED 0, MISSING 0, INVALID 0, and the report title is "3 entries".

#### FT-04 · Verify pasted checksum lines: OK, FAILED, MISSING and unsafe path INVALID

Platforms: **all**

1. In Hash & Checksum, stay on "Verify list" and set "Source" to "Pasted lines".
2. If "Paths are relative to" does not show the workspace root (for example "duplicates" after case 3), tap "Change folder" and choose the workspace root.
3. Paste 4 lines into "Checksum lines": \`da96eee0e5f8c94c457955e4e4cbb9bca63fb2c31f9984fc179f98f81e4903a1  game/config/balance.toml\`, then the same digest followed by two spaces and game/config/settings.ini, then the same digest with game/config/missing.json, then the same digest with ../outside.txt.
4. Tap "Verify" and then the "Save / export report" icon.

**Expected:** The banner reads "PROBLEMS FOUND" / "1 failed, 1 missing, 1 invalid, 0 unreadable line(s)." The rows show balance.toml as OK and settings.ini as FAILED, with the lines "expected ..." and "actual 8d233d8e...". missing.json shows MISSING. ../outside.txt shows INVALID with the detail "unsafe path: ...", and it is never read. The export offers the file name verify-report.txt.

#### FT-05 · Terminal hash command: file digest with --check, refused path, bad algorithm

Platforms: **all**

1. Open System &gt; Terminal.
2. Run: hash --file game/game.json --check sha256:7ee35ab9ba1717ab5c129102cbd20bda158cf7f75fc0c01214f9e0c917ebe4bb
3. Run: hash --file ../README.txt
4. Run: hash --algo crc32 hello

**Expected:** Step 2 prints three lines: "7ee35ab9ba1717ab5c129102cbd20bda158cf7f75fc0c01214f9e0c917ebe4bb  game/game.json", "algorithm: SHA-256 | size: 269 B (269 bytes)" and "MATCH  expected digest equals the SHA-256 digest". Step 3 prints an error that starts with 'Refused path "../README.txt":' and ends with 'Paths are relative to "&lt;workspace name&gt;".' Step 4 prints 'Unknown algorithm "crc32" (use sha256, sha512, sha1, md5)'. A wrong --check value prints "MISMATCH  expected ..." with exit code 1.

#### FT-06 · Duplicate Finder: scan the sample workspace, keepers, filters and invalid glob

Platforms: **all**

1. Open Duplicate Finder. The folder shows "&lt;workspace name&gt; (workspace root)" and "Minimum file size" is "Any size". Tap "Scan for duplicates".
2. Look at the Summary panel and both groups.
3. In group #1, tap the "Keep this copy" radio of game/data/ui/hud.json.
4. Enter \*.png in "Include (globs, comma separated)" and scan again.
5. Change Include to \[abc and tap "Scan for duplicates".

**Expected:** Step 2: the Summary title is "2 duplicate groups", Reclaimable is 1.8 KB and Redundant copies is 2. Group #1 reads "2 × 1.4 KB · 1.4 KB reclaimable" (duplicates/hud\_backup.json and game/data/ui/hud.json). Group #2 reads "2 × 404 B · 404 B reclaimable" (duplicates/potion (copy).png and game/sprites/items/potion.png). duplicates/hud\_backup\_old.json is NOT listed: it has the same size but different content. With the default rule "Fewest folders", the duplicates/ copies show KEEP and the game/ copies show MOVE. Step 3: hud.json becomes KEEP and hud\_backup.json becomes MOVE. Step 4: "1 duplicate group" (potion only). Step 5: the include field shows the inline error 'Unclosed "\[" in glob "\[abc"', and scanning shows the error panel 'Invalid pattern: Unclosed "\[" in glob "\[abc"'. Clear Include afterwards.

#### FT-07 · Duplicate Finder: move copies to quarantine and undo (restore)

Platforms: **all**

1. With Include empty, scan again and keep both groups at their default selection.
2. Tap "Move 2 copies to quarantine (1.8 KB)" and confirm with "Move to quarantine".
3. In the "Quarantine & undo" panel, expand the new session (titled with its date and time).
4. Tap "Restore all 2".
5. Tap "Scan for duplicates" again.

**Expected:** Step 2: the confirm dialog is titled "Move 2 copies to quarantine?" and lists both paths. Afterwards a "Note" banner says "Moved 2 copies (1.8 KB) to quarantine &lt;id&gt;. Undo any time below." and the Summary becomes "No duplicates found". Step 3: the session shows "HELD 2" and "1.8 KB held · 0 restored", and each entry shows QUARANTINED with an undo icon. Step 4: the banner says "Restored 2 file(s) from &lt;id&gt;. Scan again to refresh the duplicate groups." and the session badge turns "RESTORED". Step 5: the same 2 groups are found again, so the files are back at their original paths.

#### FT-08 · Line Endings text mode: analyse and preview a conversion

Platforms: **all**

1. Open Line Endings with "Input" set to "Text".
2. Type a, press Enter, type b, press Enter, type c into "Paste text to analyse".
3. Under "Convert to" select "CRLF (Windows)".
4. Tap the "Copy converted text" icon in the Preview panel.

**Expected:** The Analysis title is "Detected: LF". The Before row reads LF 2 / CRLF 0 / CR 0 and the After row reads LF 0 / CRLF 2 / CR 0. The badges read "consistent" and "2 to change", next to "3 lines". The Preview "Converted (first 40 lines, endings shown)" shows a«CRLF», b«CRLF», c. Copying shows "Copied 2 lines". With "LF (Linux, macOS)" selected the badge reads "already LF".

#### FT-09 · Line Endings files mode: dry run, binary skip, convert with backup

Platforms: **all**

1. In Line Endings, set "Input" to "Files", "Convert to" to "LF (Linux, macOS)" and "Source" to "Chosen files".
2. Tap "Workspace file" and add game/data/items.csv, then add game/sprites/items/potion.png the same way.
3. Tap "Analyse".
4. Tap "Convert files" and confirm with "Convert files".

**Expected:** Step 3: the "Dry run" report reads "2 files checked". items.csv shows WILL CHANGE with the detail "UTF-8 · LF 0 · CRLF 21 · CR 0 → LF 21 · CRLF 0 · CR 0". potion.png shows SKIPPED: BINARY with "binary content". The caption reads "1 file(s) would change." Step 4: the dialog is titled "Rewrite files in place?" and lists only game/data/items.csv. Afterwards items.csv shows CHANGED with "backup kept", and the info line says "Originals were backed up to backups/&lt;yyyyMMdd-HHmmss&gt; (workspace metadata)." "Convert files" is then disabled, with the caption "Applied. Analyse again to re-check."

#### FT-10 · Whitespace Cleanup text mode: live preview, invisible characters, replace input

Platforms: **all**

1. Open Whitespace Cleanup with "Clean" set to "Text" and the default rules (Trim trailing whitespace, Collapse blank lines with Max blank lines 1, Exactly one final newline).
2. Type hello followed by 3 spaces, press Enter 3 times, then type world with no final Enter.
3. Look at the Preview and Diff panels.
4. In the "Cleaned text" panel, tap the "Replace the input with the cleaned text" icon.

**Expected:** The Preview title is "Changes" and lists "Trimmed trailing whitespace on 1 line(s)", "Removed 1 extra blank line(s)" and "Added the final line break". The "Lines changed" tile shows 1. The Diff panel shows the removed line as "hello···" (· = trailing space) and the new line as "hello". After step 4 the Preview title becomes "Already clean", with the badge "nothing to clean with these rules", and the replace icon is disabled.

#### FT-11 · Whitespace Cleanup files mode: folder + glob filter, clean with backup

Platforms: **all**

1. In Whitespace Cleanup set "Clean" to "Files" and "Source" to "Folder + filter".
2. Tap "Change folder" and choose game/data.
3. Enter \*.tsv, \*.csv in "Include (globs, comma separated)".
4. Tap "Analyse".
5. Tap "Clean files" and confirm with "Clean files".

**Expected:** Step 4: "2 files checked". game/data/enemies.tsv shows WILL CHANGE with "UTF-8 · Trimmed trailing whitespace on 1 line(s)": the "mimic" row ends with a tab, and trimming that tab is expected by the current rules. game/data/items.csv shows UNCHANGED with "UTF-8 · clean"; its CRLF endings are kept because "Normalise line endings" is off. Step 5: enemies.tsv shows CHANGED with "backup kept", and the backup info line appears. All other tabs in enemies.tsv are kept.

#### FT-12 · Device copy is never rewritten in place: export instead

Platforms: **all**

1. In Line Endings Text mode with "Convert to" = "CRLF (Windows)" and the text a/b/c from case 8, tap "Save / export converted text", choose "Export..." and save converted-crlf.txt to the device.
2. Switch "Input" to "Files" and "Convert to" to "LF (Linux, macOS)". Tap "Clear", then "From device", and pick converted-crlf.txt.
3. Tap "Analyse", then "Convert files" and confirm.
4. Tap the "Export converted copy of converted-crlf.txt" icon on the row.

**Expected:** The file row has a device icon, not a workspace icon. After Analyse it shows WILL CHANGE with "LF 0 · CRLF 2 · CR 0 → LF 2 · CRLF 0 · CR 0". After applying, the row shows DEVICE COPY with "imported copy: export the converted file instead", and the picked file is not changed. The export icon opens the save sheet with the suggested name converted-crlf-lf.txt.

#### FT-13 · ZIP Studio create: folder into archive, no overwrite, export

Platforms: **all**

1. Open ZIP Studio with "Action" set to "Create".
2. Tap "Workspace folder" and choose game/config.
3. Leave "Archive name" empty (the hint shows config.zip) and tap "Create in workspace".
4. Tap "Create in workspace" again.
5. Tap "Create & export...".

**Expected:** Step 2: the Sources title reads "4 entries · 4.6 KB" and lists config/balance.toml, config/controls.yaml, config/graphics.json and config/settings.ini, each marked "workspace". Step 3: the banner "ARCHIVE CREATED" reads "config.zip · &lt;size&gt; · 4 files (4.6 KB before compression)". Step 4: the new archive is "config (2).zip"; the existing one is not replaced. Step 5: the save sheet 'Save "config.zip"' opens (Share... is also offered on mobile).

#### FT-14 · ZIP Studio extract: inspect a .j3mod, extract, then existing-file policies

Platforms: **all**

1. In ZIP Studio set "Action" to "Extract". Tap "Open archive..." and pick downloads/neon-hud-1.2.0.j3mod from the workspace.
2. Check the preview, then tap "Extract 4 files".
3. Turn off "Create a new folder named after the archive", tap "Change folder" and choose neon-hud-1.2.0.
4. Keep "Skip (keep mine)" and tap "Extract 4 files".
5. Select "Stop with an error" and extract.
6. Select "Overwrite (danger)", extract, and confirm with "Overwrite".

**Expected:** Step 1: the banner "SAFE TO EXTRACT" reads "4 files, 2.9 KB unpacked." The Preview "4 entries" lists j3mod.json, README.md, preview.png and files/data/ui/hud.json. The destination is neon-hud-1.2.0/. Step 2: "EXTRACTED" reads "4 written, 0 skipped, 2.9 KB into neon-hud-1.2.0/". Step 3: the banner reads "4 file(s) already exist". Step 4: "0 written, 4 skipped, 0 B ..." with lines "skipped (exists): ...". Step 5: the "Extraction failed" panel says "4 file(s) already exist; nothing was extracted (first: ...)". Step 6: the dialog is titled "Overwrite 4 existing file(s)?". Afterwards the banner reads "4 written..." plus "4 overwritten file(s) were backed up first."

#### FT-15 · Log Viewer (desktop): open, filter, plain/regex search, invalid regex, select and export

Platforms: **desktop**

1. Open Log Viewer, click "Open log..." and pick game/logs/game.log from the workspace.
2. Click "Errors only", then click "All levels".
3. Type Failed to (read|decode) in "Search", turn on ".\* Regex" and click "Search". Press F3 in the list.
4. Click "Select matches", then "Export selected", choose "Save to workspace", pick a folder and save.
5. Change the search to ( with Regex still on and press Enter.

**Expected:** Step 1: the caption reads "298 lines · 21.5 KB · UTF-8 · LF" and the filter title reads "298 of 298 lines shown". Step 2: only lines tagged E/F remain, starting with line 19 (\[ERROR\] ... saves/slot3.json) and its indented continuation line 20. Step 3: "2 matching line(s)" (lines 19 and 69), highlighted. F3 jumps to the next match and wraps around. Step 4: the list title reads "2 selected" and the proposed file name ends in -selection.log. The file starts with "# J3NSONTOP log export", "# source: game/logs/game.log", "# scope: selected lines, 2 line(s)", "# severity filter: all levels", "# search: /Failed to (read|decode)/ (regex, ignore case)" and "# line ranges (original numbering): 19, 69", followed by the 2 raw lines. Step 5: the search field shows "Invalid regular expression: ..." and the app stays responsive.

#### FT-16 · Log Viewer (mobile): checkbox selection and share export

Platforms: **mobile**

1. Open Log Viewer, tap "Open log...", choose the workspace and pick game/logs/crash-2026-09-01.log.
2. Confirm the "Checkboxes" chip is already selected, then tap two different lines.
3. Tap "Export selected".
4. Tap "Clear".

**Expected:** On phones "Checkboxes" is on by default and rows get a checkbox. Each tap toggles one line, and the list title changes to "2 selected". "Export selected" opens the save sheet with "Save to workspace", "Export..." and "Share..." (Share is mobile-only). After "Clear" the title returns to "Click, shift-click or ctrl-click to select" and "Export selected" is disabled.

### DV · Developer Tools

Before you start:

- The app is installed from the CI build and the sample workspace "Neon Dungeon" is present and set as the active workspace. Its files match samples/neon-dungeon/.
- Open each tool from the Developer Tools section in the navigation, or search for the tool name in the palette.
- HTTP cases only: the device needs internet access to https://httpbin.org and https://self-signed.badssl.com. Use a normal network with no TLS-intercepting proxy.
- When a step opens a file, pick the entry that starts with 'From workspace' in the 'Open text file' / 'File to encode (max 10 MiB)' sheet. Then browse to the given relative path.
- When a step saves a file, the sheet is titled 'Save "&lt;name&gt;"' and offers 'Save to workspace ...', 'Export...' and 'Share...'. Any target works; open the saved file to check its content.

#### DV-01 · Text Diff: compare two workspace files and export the unified diff; binary files are refused

Platforms: **all**

1. Open Developer Tools &gt; Text Diff.
2. Tap the folder icon 'Open file for the left side' and open duplicates/hud\_backup\_old.json from the workspace.
3. Tap 'Open file for the right side' and open duplicates/hud\_backup.json.
4. Switch View to 'Side by side', then tap 'Save unified diff' (save icon in the RESULT panel) and save the file.
5. Tap 'Open file for the right side' again and pick game/sprites/hero\_walk.png.

**Expected:** The side headers read 'LEFT (old): duplicates/hud\_backup\_old.json' and 'RIGHT (new): duplicates/hud\_backup.json'. The RESULT panel is titled 'Differences' with badges '2 CHANGED LINES', '+1 added', '-1 removed' and '=N same'. The only changed line is the "x" value: 18 on the left, 16 on the right. Unchanged runs collapse into '... N unchanged lines ...' rows. Side by side shows the pair on one row with the changed word highlighted. The save sheet suggests 'changes.diff'. The saved file is a unified diff with ---/+++ headers, an @@ hunk and one '-' and one '+' line. Picking the PNG shows the error toast 'game/sprites/hero\_walk.png looks like a binary file, not text.' and the right text is not changed.

#### DV-02 · Base64: encode/decode text and report an invalid character with its position

Platforms: **all**

1. Open Developer Tools &gt; Base64. With Mode 'Encode text' selected, type: Hello, modder!
2. Tap 'Swap'.
3. Replace the input with: SGVsbG8\*
4. Tap the 'Go to line 1, col 8' button in the error banner.

**Expected:** Encoding shows the panel 'Base64 (standard)' with SGVsbG8sIG1vZGRlciE= and the footer '... of UTF-8 -&gt; 20 characters'. Swap puts the Base64 into the input and switches Mode to 'Decode'. The result is 'Decoded text (UTF-8)' showing 'Hello, modder!', with a footer that includes 'Standard alphabet'. The bad input shows the banner 'Not valid Base64' with the message "Invalid Base64 character '\*' (U+002A) at line 1, column 8 (offset 7)" and a hint about the allowed characters. The Go to button puts the caret before the '\*'.

#### DV-03 · Base64: File -&gt; Base64 on a workspace PNG, including the data: URI option

Platforms: **all**

1. Open Developer Tools &gt; Base64.
2. Tap 'File -&gt; Base64' and open game/sprites/items/potion.png from the workspace.
3. Wait for the 'FILE -&gt; BASE64' panel, then turn on 'As data: URI'.
4. Tap the close icon 'Close file result'.

**Expected:** A 'FILE -&gt; BASE64' panel titled 'game/sprites/items/potion.png' appears, showing 'Encoding ... in the background...' first. Its footer reads '&lt;size&gt; PNG image -&gt; &lt;size&gt; of Base64' and the output starts with iVBORw0KGgo. With 'As data: URI' on, the output starts with 'data:image/png;base64,' and is not wrapped. The option description reads 'Prefix with data:image/png;base64, (no wrapping)'. Closing removes the file panel. A file over 10 MiB is refused with the toast '&lt;name&gt; is &lt;size&gt;; the limit for this tool is &lt;10 MiB&gt;.'.

#### DV-04 · URL Encode/Decode: component encoding, strict decoding error and Inspect URL with masked password

Platforms: **all**

1. Open Developer Tools &gt; URL Encode/Decode. With Mode 'Encode' and 'What to keep' = 'Component', type: name=J3 & friends/ü
2. Switch Mode to 'Decode' and enter: 100%zz
3. Switch Mode to 'Inspect URL' and enter: https://modder:hunter2@example.com:8443/api/v1/items?id=42&tag=a+b&id=7#details
4. Tap 'Reveal password' next to User info.

**Expected:** Encode shows 'Encoded (Component)': name%3DJ3%20%26%20friends%2F%C3%BC. Decode shows the banner 'Cannot decode' with 'Malformed percent sequence "%zz" at line 1, column 4 (offset 3)' and a 'Go to line 1, col 4' button. Inspect shows the warning 'Check this URL' ('The URL contains a password in the user-info part. Avoid sharing it.'). The PARTS panel is titled https://example.com:8443 and shows Scheme https, User info 'modder:••••' (after Reveal: modder:hunter2), Host example.com, Port 8443, Path /api/v1/items and 'Fragment (decoded)' details. PATH shows '3 segments (decoded)'. QUERY shows '3 parameters' in order: id=42, tag='a b', id=7.

#### DV-05 · UUID: generate v7 batch, reformat without regenerating, count validation and inspect

Platforms: **all**

1. Open Developer Tools &gt; UUID. Select Version 'v7 time-ordered', keep 'Count (1-1000)' = 5 and tap 'Generate'.
2. Turn on 'Uppercase' and 'Braces {...}'.
3. Tap 'Inspect the first UUID' (search icon on the GENERATED panel).
4. Clear the inspect field and enter: 0190163d-8694-739b-aea5-966c26f8ad91
5. Set Count to 1001 and tap 'Generate'.

**Expected:** The GENERATED panel is titled '5 x v7 time-ordered' and lists 5 numbered UUIDs in strictly increasing order, each with '7' as the first digit of the third group. The Uppercase and Braces toggles reformat the same IDs, which are not regenerated. Inspecting the first one shows INSPECTION 'v7 - Unix epoch time-ordered' with the badge VALID and Created (UTC) of about now. The sample UUID shows Variant 'RFC 9562 / RFC 4122 (OSF DCE)' and Created (UTC) 2024-06-14T10:14:09.300Z, plus Created (local) and Age. With Count 1001 the field shows '&lt;= 1000' and Generate shows the error line 'Count must be a whole number from 1 to 1000.'.

#### DV-06 · Timestamp Converter: live clock, auto unit detection and ISO field errors

Platforms: **all**

1. Open Developer Tools &gt; Timestamp Converter. Watch the 'NOW (LIVE)' panel for 3 seconds, then tap 'Pause live clock'.
2. Enter 1758829267 in the Value field ('Read as' = Auto).
3. Replace the value with 2026-13-01 and tap the 'Go to line 1, col 6' button.
4. Tap 'Resume live clock', then tap 'Use now'.

**Expected:** 'Unix seconds' increases once per second. After pausing, the kicker reads 'NOW (PAUSED)' and the numbers stop. 1758829267 gives the result panel 'Read as Unix seconds (auto-detected by magnitude)' with ISO-8601 UTC 2025-09-25T19:41:07.000Z. The panel also shows Unix ms/µs/ns rows, ISO-8601 local, RFC 2822, HTTP date 'Thu, 25 Sep 2025 19:41:07 GMT', Relative, Local calendar and UTC calendar (Thursday, ISO week 2025-W39-4). 2026-13-01 shows the banner 'Cannot read this value' with 'Month 13 is out of range (01-12) at line 1, column 6 (offset 5)' and example hints. 'Use now' fills the field with the current Unix seconds and resets Read as to Auto.

#### DV-07 · Text Stats: open the Unicode sample note

Platforms: **all**

1. Open Developer Tools &gt; Text Stats.
2. Tap 'Open text file' and open notes/unicode-名前-ünïcødé.txt from the workspace.
3. Look at the STATS panel and the 'Lines, characters and time' panel.
4. Tap 'Clear text' (backspace icon on the INPUT panel).

**Expected:** The text loads. The STATS panel title reads '&lt;N&gt; words, 12 lines' and 'UTF-8 bytes' shows 552. 'Characters (UTF-16)' is larger than 'Code points' because of the emoji surrogate pairs. 'Graphemes' is smaller than 'Code points' because of the combining mark and the ZWJ sequence. 'Non-ASCII' is greater than 0, 'Line endings' shows the detected style, and Reading time and Speaking time are shown. Clearing the text shows the empty state 'No text yet'.

#### DV-08 · JSON Escape/Unescape: escape with options, unescape error with position

Platforms: **all**

1. Open Developer Tools &gt; JSON Escape/Unescape. With Mode 'Escape text', type two lines: He said "hi" (Enter) ü
2. Turn on 'Escape non-ASCII', then turn off 'Surrounding quotes'.
3. Switch Mode to 'Unescape literal' and replace the input with: "bad \\x escape"

**Expected:** The 'JSON string literal' output is "He said \\"hi\\"\\nü". With 'Escape non-ASCII' on, ü becomes \\u00fc. With 'Surrounding quotes' off, the outer quotes are dropped. Unescape shows the banner 'Invalid JSON string' with the message 'Invalid escape sequence "\\x" at line 1, column 6 (offset 5)', the hint 'JSON only allows \\" \\\\ \\/ \\b \\f \\n \\r \\t and \\uXXXX.' and a 'Go to line 1, col 6' button.

#### DV-09 · Regex Tester: example library, named groups, replace preview and invalid replacement

Platforms: **all**

1. Open Developer Tools &gt; Regex Tester, make sure 'Test text' is empty and 'Live matching' is on.
2. Tap the book icon 'Example patterns' and pick 'ISO date'.
3. Tap match #2 in the LIST panel.
4. Turn on 'Replace preview' and enter Replacement: ${day}.${month}.${year}
5. Change the Replacement to: $4

**Expected:** The pattern and a sample text are filled in. The status line reads '2 matches in N ms | 3 groups'. In 'Highlighted text' the two valid dates are wrapped in «...» and 2026-13-40 is not matched. The LIST shows '#1 \[8, 18)' style rows. GROUPS shows 'Match #2 at ...' with '$1 &lt;year&gt;' = 2026, '$2 &lt;month&gt;' = 10 and '$3 &lt;day&gt;' = 01, plus a 'Named groups' section. The 'Replace preview' panel shows 'Created 25.09.2026, updated 01.10.2026, invalid 2026-13-40.'. With $4, the banner 'Invalid replacement' shows 'Group 4 does not exist (the pattern has 3)' with its position.

#### DV-10 · Regex Tester: time limit stops catastrophic backtracking

Platforms: **all**

1. Open Developer Tools &gt; Regex Tester.
2. Enter Pattern: ^(a+)+$
3. Paste into Test text 40 letters 'a' followed by '!' (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!).
4. Tap 'Run' and watch the results for 2 seconds.
5. Tap 'Run' again and immediately tap the red 'Cancel' button.

**Expected:** While running, the status line reads 'Running in a background worker (limit 1.5 s)...' and a 'Cancel' button is shown. The app stays responsive. After about 1.5 s a warning banner titled 'Time limit' appears with 'Stopped: time limit reached (pattern may backtrack catastrophically)' and the tips about nested quantifiers. Cancelling before the limit shows a banner titled 'Stopped' with 'Cancelled after N ms'. No crash or freeze.

#### DV-11 · Case Converter and Number Base Converter: happy path plus invalid digit

Platforms: **all**

1. Open Developer Tools &gt; Case Converter and type: HTTPServerError
2. Turn on 'Keep acronyms'.
3. Open Developer Tools &gt; Number Base Converter, keep Input base 'Auto (0x/0b/0o)' and 'Two's complement width' 32-bit, and enter: -1
4. Replace the value with: 0x12G

**Expected:** Case Converter shows 'Words (first line): HTTP | Server | Error'. camelCase is httpServerError, PascalCase HttpServerError, snake\_case http\_server\_error, kebab-case http-server-error and CONSTANT\_CASE HTTP\_SERVER\_ERROR. With 'Keep acronyms' on, PascalCase becomes HTTPServerError and camelCase stays httpServerError. For -1 the Number Base 'FIXED WIDTH' panel '32-bit two's complement' shows the badges 'NOT UNSIGNED' and 'FITS SIGNED', Hex pattern FFFFFFFF, As unsigned 4294967295, As signed -1 and 'Bits as float32'. 0x12G shows the banner 'Not a valid number' with "Invalid base-16 digit 'G' (U+0047) at line 1, column 5 (offset 4)".

#### DV-12 · JWT Decoder: expired token and alg none warning

Platforms: **all**

1. Open Developer Tools &gt; JWT Decoder and check the banner at the top.
2. Paste: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsImV4cCI6MTAwMDAwMDAwMH0.c2lnbmF0dXJl
3. Replace the token with: eyJhbGciOiJub25lIn0.eyJzdWIiOiI0MiJ9.
4. Replace the token with: not-a-token

**Expected:** The banner reads 'Decode only - the signature is NOT verified'. The first token (Bearer prefix ignored) shows SUMMARY 'alg HS256 | typ JWT' with the badge EXPIRED. Expires (exp) shows 2001-09-09T01:46:40Z with local time and relative time. The Header and 'Payload (claims)' panels show pretty JSON. The alg-none token shows 'alg none', the badge 'NO exp/nbf CLAIMS' and a 'Warnings' banner with 'alg is "none": the token is unsigned and must never be trusted.'. 'not-a-token' shows 'Cannot decode token' with 'Expected 3 parts (header.payload.signature) but found 1' and the hint about missing dots.

#### DV-13 · HTTP Request: URL validation, JSON body validation and a successful GET

Platforms: **all**

1. Open Developer Tools &gt; HTTP Request. Enter URL example.com/x, then change it to http://httpbin.org/get.
2. Change Method to POST, keep Type 'JSON', enter the body {"a":1,} and tap 'Send'.
3. Change Method back to GET, enter URL https://httpbin.org/json and tap 'Send'.
4. Switch the body View between 'Pretty JSON', 'Text' and 'Hex'.

**Expected:** example.com/x shows the field error 'Missing scheme at line 1, column 1 (offset 0)'. The http:// URL shows the warning banner 'Cleartext HTTP'. The invalid JSON body shows an 'Invalid JSON: ...' field error, and Send shows the banner 'Fix the request first' with a 'Body: Invalid JSON: ...' line. Nothing is sent. The GET shows the RESPONSE panel 'GET httpbin.org/json' with the badge '200 OK' and '2xx Success', the tiles 'Total time', 'Headers after' and 'Body size', and Content-Type application/json. The BODY opens in 'Pretty JSON'. The HEADERS panel lists lower-case response header names. A 'Last 1 request' entry (GET, 200 OK) appears in HISTORY.

#### DV-14 · HTTP Request: TLS verification, timeout and cancel

Platforms: **all**

1. In HTTP Request (GET), enter https://self-signed.badssl.com/ and tap 'Send'.
2. Set 'Timeout (s, 1-120)' to 2, enter https://httpbin.org/delay/10 and tap 'Send'.
3. Set Timeout back to 20, tap 'Send' again, and within a few seconds tap the red 'Cancel' button.

**Expected:** The self-signed site fails with the error banner 'TLS / certificate problem'. Its message starts with 'GET self-signed.badssl.com/' and 'TLS/certificate error: ...', and the detail reads 'Certificate verification is always enabled. Use a certificate trusted by this device, or plain http:// for a local development server.'. There is no way to bypass it. The 2 s request shows 'Timed out' with 'Timed out after 2 s' and the hint about raising the timeout. While a request runs, the RESPONSE panel reads 'Waiting for GET httpbin.org/delay/10'. Cancel ends it at once with an info banner 'Cancelled'. Each attempt is added to HISTORY with the badge ERROR and its error text.

#### DV-15 · HTTP Request: secrets are redacted in history and export, and replay requires re-entry

Platforms: **all**

1. In HTTP Request (GET), enter https://httpbin.org/get?access\_token=abc123&page=2.
2. Tap 'Add a common header' (list icon) &gt; 'Authorization: Bearer ', type 'Bearer abc123' as the Value, then tap 'Send'.
3. In HISTORY tap 'Export redacted log' (share icon) and save the file, then open it.
4. Tap the history entry to load it back into the editor.
5. Tap 'Send' without changing anything.

**Expected:** The Authorization value is masked with • characters, has a 'Reveal value' toggle and the badge 'SENSITIVE - masked, never saved'. The history entry shows the URL https://httpbin.org/get?access\_token=REDACTED&page=2. The exported http-log-&lt;stamp&gt;.txt starts with '# J3NSONTOP HTTP request log (redacted)', lists the REDACTED URL and contains 'Authorization: ••••'. abc123 does not appear anywhere. Loading the entry shows the warning toast 'Loaded GET request. Re-enter 2 redacted value(s) before sending.'. The Authorization row shows 'Value (re-enter: redacted in history)' and the badge 'VALUE REQUIRED', and a 'Redacted values' banner is shown under the URL. Send is refused with 'Fix the request first' and 'Header "Authorization" was redacted in history. Enter its value again or disable the row.'.

### Summary table

| ID | Case | Platforms | Result |
| --- | --- | --- | --- |
| SH-01 | First launch: laughing-skull intro plays once, then the sample workspace appears on Home | all | |
| SH-02 | Skip the intro (button, Esc) and it never replays on navigation | all | |
| SH-03 | Skip-intro setting persists (intro toggle and Settings switch) | all | |
| SH-04 | Replay intro from About, Settings, Home and the palette | all | |
| SH-05 | Intro sound on, mute from the intro | all | |
| SH-06 | Reduced motion gives a static intro with Continue | all | |
| SH-07 | Effects settings: intensity, low-effects, scanlines, particles, glow, accent (live preview) | all | |
| SH-08 | Settings persist after relaunch; Reset settings to defaults | all | |
| SH-09 | Home favourites and recents | all | |
| SH-10 | Navigation: sidebar/rail on desktop, bottom bar + drawer on phones, Android back | all | |
| SH-11 | Command palette: Ctrl+K and keyboard shortcuts (desktop) | desktop | |
| SH-12 | Command palette on mobile (search button) and shortcuts panel alternative | mobile | |
| SH-13 | Terminal: help, open, theme, invalid commands | all | |
| SH-14 | Terminal history, completion, toolbar and session survival | all | |
| SH-15 | Activity page and live activity panel | all | |
| SH-16 | About screen and hidden skull laugh | all | |
| SH-17 | Small phone (320-360 px) with largest system text | mobile | |
| SH-18 | Report a problem: copy and save diagnostics | all | |
| SH-19 | Home quick action "Create sample workspace" keeps your active workspace | all | |
| WS-01 | Manager: create an empty workspace, switch the active workspace, rename with validation | all | |
| WS-02 | Manager: Export ZIP of the sample, then Import ZIP into a new workspace (with cancel of the preview) | all | |
| WS-03 | Manager: remove a record but keep its files, then recover it from App storage | all | |
| WS-04 | Manager on mobile: no link/import folder, app-storage copy via Import files | mobile | |
| WS-05 | Manager on desktop: link a folder, then remove the linked record without touching the folder | desktop | |
| WS-06 | File Browser: navigate, filter, details and SHA-256 of the near-duplicate files | all | |
| WS-07 | File Browser: rename validation, move to trash, Undo, and restore from the Trash view | all | |
| WS-08 | Text Editor: edit and save game/config/settings.ini with backup, then revert unsaved changes | all | |
| WS-09 | Text Editor: CRLF file game/data/items.csv, find, and Go to line out of range | all | |
| WS-10 | Text Editor: binary warning for a PNG, and a device copy that cannot be saved in place | all | |
| WS-11 | Hex Viewer: open logo.png, byte search, count, and input errors | all | |
| WS-12 | Find Files: glob, contains and an invalid regex | all | |
| WS-13 | Search in Files: regex with a glob filter, open the hit at its line, and an invalid regex | all | |
| WS-14 | Batch Rename: preview, apply and undo on rename-demo/ | all | |
| WS-15 | Batch Rename: duplicate names and an invalid template token block Apply | all | |
| WS-16 | Replace in Files: diff preview, per-file selection and apply with backup | all | |
| WS-17 | Replace in Files: regex on a CRLF file, and a preview that is out of date | all | |
| WS-18 | Reset sample restores the original files after confirmation | all | |
| MD-01 | Profile list shows the correct status for each sample profile | all | |
| MD-02 | vanilla-plus: exact plan dialog, cancel, then apply | all | |
| MD-03 | Journal and backups after an apply | all | |
| MD-04 | Applying a second profile on the same target asks you to roll back first | all | |
| MD-05 | vanilla-plus rollback restores the original | all | |
| MD-06 | Rollback detects a user edit made after applying | all | |
| MD-07 | hardcore-run: dependency order and a 5-file plan | all | |
| MD-08 | hardcore-run: disabling a required dependency blocks apply | all | |
| MD-09 | conflict-demo: overlap report and the warning acknowledgement in the plan | all | |
| MD-10 | broken-deps: missing retro-core and the cycle block apply | all | |
| MD-11 | Import a .j3mod: identical, removed and then re-imported | all | |
| MD-12 | Importing a ZIP that is not a package is rejected | all | |
| MD-13 | Mod Package Inspector: a valid package and a blocked ZIP | all | |
| MD-14 | Mod Package Builder: live validation, then build into the library | all | |
| MD-15 | Mobile: apply to the workspace copy, then export the result | mobile | |
| CF-01 | JSON Studio: open, stats, format with 4 spaces and undo | all | |
| CF-02 | JSON Studio + terminal: trailing comma is reported with line:column and Jump to error | all | |
| CF-03 | JSON Studio: tree edit, undo and field search | all | |
| CF-04 | YAML Editor: controls.yaml to JSON itemises comments and expanded aliases | all | |
| CF-05 | YAML Editor on a phone: pane chips and From JSON (verified YAML) | mobile | |
| CF-06 | TOML Editor: balance.toml tree and TOML to JSON date-time report | all | |
| CF-07 | TOML Editor: JSON to TOML refuses nulls unless "Drop null properties" is on | all | |
| CF-08 | INI Editor: lossless value edit and save with backup | all | |
| CF-09 | INI Editor: INI to JSON report and invalid section header | all | |
| CF-10 | CSV / TSV Table: items.csv preview, filter, stats and CSV to JSON | all | |
| CF-11 | CSV / TSV Table: enemies.tsv to CSV, and an unterminated quote | all | |
| CF-12 | Config Compare: semantic and text diff of the HUD backup, side-by-side view and report export | all | |
| CF-13 | Config Compare: JSON vs YAML with the same data, then a parse error | all | |
| CF-14 | Config Presets: create a preset, preview and apply to graphics.json with backup | all | |
| CF-15 | Config Presets: built-ins are read-only, duplicate works, a non-preset import is refused | all | |
| CF-16 | Save Data Editor: sample save, schema form, bound violation, confirm on save, stepper clamp | all | |
| CF-17 | Built-in preset "Potato mode" on the sample graphics.json keeps the file structure | all | |
| AS-01 | Asset Lab landing lists the five tools and the format matrix | all | |
| AS-02 | Image Studio: open logo and read its metadata | all | |
| AS-03 | Image Studio: pipeline with undo, redo and reset | all | |
| AS-04 | Image Studio: an out-of-bounds crop is rejected | all | |
| AS-05 | Image Studio: JPEG flattening warning and default output name | all | |
| AS-06 | Image Studio: ICO export blocks images over 256 px | all | |
| AS-07 | Image Studio: 'Save next to original' writes a new file | all | |
| AS-08 | Sprite Sheet: auto grid, animation and frames ZIP | all | |
| AS-09 | Sprite Sheet: a grid or frame count that does not fit is refused | all | |
| AS-10 | Sprite Sheet: animated GIF export | all | |
| AS-11 | Atlas Packer: pack the item icons and check the JSON | all | |
| AS-12 | Atlas Packer: duplicate names, rename and stale result | all | |
| AS-13 | Atlas Packer: a sprite too large for the maximum size | all | |
| AS-14 | Color Lab: formats, WCAG contrast and invalid HEX | all | |
| AS-15 | Color Lab: eyedropper on a transparent pixel | all | |
| AS-16 | Color Lab: saved palette and exports survive a restart | all | |
| AS-17 | App Icon Export: non-square logo, generate and verify | all | |
| AS-18 | App Icon Export: no platform selected, then a stale result | all | |
| AS-19 | Save sheet offers Share on mobile only | mobile | |
| AS-20 | Terminal: wcag, colorfmt and imginfo | all | |
| FT-01 | Hash text: known SHA-256, expected-digest MATCH/MISMATCH and algorithm suggestion | all | |
| FT-02 | Hash a workspace file and compare with the published SHA-256 | all | |
| FT-03 | Generate SHA256SUMS next to files, then verify it (round trip) | all | |
| FT-04 | Verify pasted checksum lines: OK, FAILED, MISSING and unsafe path INVALID | all | |
| FT-05 | Terminal hash command: file digest with --check, refused path, bad algorithm | all | |
| FT-06 | Duplicate Finder: scan the sample workspace, keepers, filters and invalid glob | all | |
| FT-07 | Duplicate Finder: move copies to quarantine and undo (restore) | all | |
| FT-08 | Line Endings text mode: analyse and preview a conversion | all | |
| FT-09 | Line Endings files mode: dry run, binary skip, convert with backup | all | |
| FT-10 | Whitespace Cleanup text mode: live preview, invisible characters, replace input | all | |
| FT-11 | Whitespace Cleanup files mode: folder + glob filter, clean with backup | all | |
| FT-12 | Device copy is never rewritten in place: export instead | all | |
| FT-13 | ZIP Studio create: folder into archive, no overwrite, export | all | |
| FT-14 | ZIP Studio extract: inspect a .j3mod, extract, then existing-file policies | all | |
| FT-15 | Log Viewer (desktop): open, filter, plain/regex search, invalid regex, select and export | desktop | |
| FT-16 | Log Viewer (mobile): checkbox selection and share export | mobile | |
| DV-01 | Text Diff: compare two workspace files and export the unified diff; binary files are refused | all | |
| DV-02 | Base64: encode/decode text and report an invalid character with its position | all | |
| DV-03 | Base64: File -&gt; Base64 on a workspace PNG, including the data: URI option | all | |
| DV-04 | URL Encode/Decode: component encoding, strict decoding error and Inspect URL with masked password | all | |
| DV-05 | UUID: generate v7 batch, reformat without regenerating, count validation and inspect | all | |
| DV-06 | Timestamp Converter: live clock, auto unit detection and ISO field errors | all | |
| DV-07 | Text Stats: open the Unicode sample note | all | |
| DV-08 | JSON Escape/Unescape: escape with options, unescape error with position | all | |
| DV-09 | Regex Tester: example library, named groups, replace preview and invalid replacement | all | |
| DV-10 | Regex Tester: time limit stops catastrophic backtracking | all | |
| DV-11 | Case Converter and Number Base Converter: happy path plus invalid digit | all | |
| DV-12 | JWT Decoder: expired token and alg none warning | all | |
| DV-13 | HTTP Request: URL validation, JSON body validation and a successful GET | all | |
| DV-14 | HTTP Request: TLS verification, timeout and cancel | all | |
| DV-15 | HTTP Request: secrets are redacted in history and export, and replay requires re-entry | all | |

## 6. Known limitations of test builds

- The Android test APK is debug-signed and the Windows binaries are not
  code-signed. Release-signed builds come from the manual Release workflow
  once the signing secrets exist ([SIGNING.md](SIGNING.md)).
- The iOS Simulator build is a debug build; it is slower than a release
  build and only runs in the simulator.
- The Windows build log warns that `dartjni.dll` (bundled by a dependency)
  refers to `jvm.dll`. The library is not used on Windows; the clean-machine
  test without Java passes.
- Mobile platforms work on imported copies in app storage and export through
  the system share sheet or save dialog; they cannot change other apps'
  folders in place.
