# Building J3NSONTOP BIGGEST MULTITOOL MADE

One Flutter codebase, three delivered platforms:

| Platform | Built on | Output in `dist/` |
| --- | --- | --- |
| Windows x64 | Windows 10/11 | `J3NSONTOP-Multitool-<ver>-windows-x64-portable.zip`, `J3NSONTOP-Multitool-<ver>-windows-x64-setup.exe` |
| Android | Windows, macOS or Linux | `J3NSONTOP-Multitool-<ver>-android-test-debugsigned.apk` (test) or `...-android-release.apk` + `.aab` (signed) |
| iOS | macOS with Xcode only | `J3NSONTOP-Multitool-<ver>-ios-UNSIGNED-compile-check.zip` (not installable) or `...-ios-<method>.ipa` (signed) |
| Linux | Linux (development/test target only) | not packaged; `build/linux/x64/release/bundle/` |

`<ver>` is the `version:` name from `pubspec.yaml` (for `1.0.0+1` it is `1.0.0`;
the `+1` build number becomes the Android `versionCode`, the iOS
`CFBundleVersion` and the fourth part of the Windows file version).

Every build script also writes `<file>.sha256` (compatible with
`sha256sum -c`) and a combined `dist/SHA256SUMS`. The exact tool versions are
listed in [TOOLCHAIN.md](TOOLCHAIN.md); signing is explained in
[SIGNING.md](SIGNING.md); the GitHub workflows in [CI.md](CI.md).

If you do not want to install anything locally, run the **CI** or **Release**
workflow on GitHub instead and download the artifacts (see [CI.md](CI.md)).
iOS builds only ever run on macOS; on a Windows PC use the Release workflow.

---

## 1. Prerequisites on Windows (Windows + Android builds)

1. **Git for Windows** - <https://git-scm.com/download/win>.
2. **Flutter 3.47.5 (stable)** - unzip the SDK to a path without spaces, e.g.
   `C:\src\flutter`, and add `C:\src\flutter\bin` to `PATH`. Check with
   `flutter --version` (must print `Flutter 3.47.5`, `Dart 3.13.4`).
3. **Visual Studio 2022** (Community is fine; CI uses Enterprise 17.14) with
   the **Desktop development with C++** workload (MSVC v143, Windows 10/11 SDK,
   CMake). Not *Visual Studio Code* - that is a different product.
4. **Inno Setup 6** (6.7.x) for the installer:
   `winget install JRSoftware.InnoSetup`. The script looks for `ISCC.exe` in
   `C:\Program Files (x86)\Inno Setup 6\`, `C:\Program Files\Inno Setup 6\`,
   `%LOCALAPPDATA%\Programs\Inno Setup 6\`, on `PATH`, or in the `J3_ISCC`
   environment variable. Use `-SkipInstaller` to build only the ZIP.
5. For Android additionally: **Android Studio** (it installs the Android SDK,
   platform-tools and a JDK). In *SDK Manager* install *Android SDK
   Build-Tools* (36 or newer), *Android SDK Command-line Tools*, *NDK
   28.2.13676358* and *CMake*. Then run `flutter doctor --android-licenses`.
   Gradle needs **JDK 17 or newer**; Flutter uses Android Studio's bundled JDK
   (or set one with `flutter config --jdk-dir "C:\Program Files\Eclipse Adoptium\jdk-17..."`).
6. Run `flutter doctor -v` - the Windows and Android sections must be green.

PowerShell scripts are plain ASCII and work in Windows PowerShell 5.1 and
PowerShell 7. If script execution is disabled on your PC, start them with
`powershell -ExecutionPolicy Bypass -File <script>` as shown below (this does
not change any system setting).

### Get the sources

```powershell
git clone https://github.com/<owner>/<repo>.git
cd <repo>
flutter pub get --enforce-lockfile
```

### Checks and tests (same gate as CI)

```powershell
powershell -ExecutionPolicy Bypass -File scripts\check.ps1
```

Runs `flutter pub get --enforce-lockfile`, `dart format --output=none
--set-exit-if-changed lib test integration_test tool`, `flutter analyze` and
`flutter test`.

---

## 2. Windows build (portable ZIP + installer)

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1
```

What it does (`scripts/build_windows.ps1`):

1. `flutter build windows --release` (skip with `-SkipBuild`).
2. Copies `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll` from the
   Visual Studio VC redist folder (found with `vswhere`; falls back to
   `System32`) next to the exe, then runs `dumpbin /dependents` on every EXE/DLL
   and also bundles any other VC runtime DLL they import - so the app starts on
   a Windows PC without the Visual C++ Redistributable.
3. Verifies the bundle: `j3nsontop_multitool.exe`, `flutter_windows.dll`,
   `data\icudtl.dat`, `data\app.so`, `data\flutter_assets\`, one
   `<plugin>_plugin.dll` per plugin listed in
   `windows\flutter\generated_plugins.cmake` (currently audioplayers_windows,
   share_plus, url_launcher_windows), the runtime DLLs, and the version
   resource (company `J3NSONTOP`, product `J3NSONTOP Multitool`).
4. Optional Authenticode signing (only if `WINDOWS_CERTIFICATE_PFX_BASE64` and
   `WINDOWS_CERTIFICATE_PASSWORD` are set - see [SIGNING.md](SIGNING.md)).
5. `dist\J3NSONTOP-Multitool-<ver>-windows-x64-portable.zip` with a single
   top-level folder `J3NSONTOP-Multitool-<ver>-windows-x64\` (bundle +
   `PORTABLE-README.txt`).
6. `dist\J3NSONTOP-Multitool-<ver>-windows-x64-setup.exe` built by Inno Setup
   from `windows\installer\j3nsontop_multitool.iss` (skip with `-SkipInstaller`).
7. `.sha256` files, `SHA256SUMS`, `windows-build-info.txt` (runtime DLL
   sources, import warnings, file list) and the Authenticode status of the exe
   and the installer (`NotSigned` unless a certificate was configured).

Options: `-OutDir <dir>`, `-SkipBuild`, `-SkipInstaller`, `-TimestampUrl <url>`.

### Try it

```powershell
# Packaged self test (the same check CI runs on a clean machine):
.\build\windows\x64\runner\Release\j3nsontop_multitool.exe --smoke-test="$env:TEMP\j3-smoke.json" --data-dir="$env:TEMP\j3-smoke-data"
echo $LASTEXITCODE; Get-Content "$env:TEMP\j3-smoke.json"
```

Launch arguments (all platforms with a command line): `--data-dir=<dir>` (use an
isolated data folder), `--smoke-test=<report.json>` (self test, write report,
exit 0/non-zero), `--skip-intro`.

### Windows installer behaviour

* Per-machine install into `C:\Program Files\J3NSONTOP Multitool` by default;
  the first wizard page lets a user without admin rights install just for
  themselves (`PrivilegesRequiredOverridesAllowed=dialog`).
* Start menu shortcut, optional desktop icon, "Launch" checkbox at the end,
  uninstaller (`unins000.exe`, *Apps & features* entry
  `{FFBDD466-85D3-4DD4-8AFD-4D7140A91A95}_is1`). The AppId GUID is fixed; never
  change it, or upgrades install side by side.
* Silent install/uninstall: `setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="C:\Apps\J3"`
  and `"C:\Apps\J3\unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART`.
* Uninstalling does **not** delete user data.

### Where the Windows app keeps its data

`path_provider_windows` builds the application-support directory from the
exe's version resource (`windows/runner/Runner.rc`, language block
`040904e4`): `%APPDATA%\<CompanyName>\<ProductName>`, i.e.
`%APPDATA%\J3NSONTOP\J3NSONTOP Multitool`. Changing `CompanyName` or
`ProductName` moves the data directory for existing users. The portable build
uses the same folder unless it is started with `--data-dir=<dir>`.

### Window

Title `J3NSONTOP Multitool`, initial size 1360 x 860 logical pixels (clamped
to the monitor's work area and centred), minimum client size 800 x 560
logical pixels, enforced per monitor DPI through `WM_GETMINMAXINFO`
(`windows/runner/win32_window.cpp`, Per-Monitor-V2 DPI awareness from
`runner.exe.manifest`).

---

## 3. Android build

### Test APK (no keystore needed)

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_android.ps1
```

macOS / Linux:

```bash
scripts/build_android.sh
```

Produces `dist/J3NSONTOP-Multitool-<ver>-android-test-debugsigned.apk`: a
release-mode (fast, AOT-compiled) APK signed with the **Android debug key**
(`-Pj3ForceDebugSigning=true`). It installs on any device/emulator, but it is
a TEST build: it can never be updated by a release-signed APK (uninstall it
first, which deletes the app's data), and debug keys differ between machines,
so a test APK from another PC or CI run also needs an uninstall first.

Install it: `adb install -r dist\J3NSONTOP-Multitool-1.0.0-android-test-debugsigned.apk`
(or copy the file to the phone and open it; allow "install unknown apps").

### Release APK + AAB (signed)

Set up the keystore first ([SIGNING.md](SIGNING.md)), then:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_android.ps1 -Mode Release
```

```bash
scripts/build_android.sh --mode release
```

Produces `...-android-release.apk` (sideloading) and `...-android-release.aab`
(Google Play). The build runs with `-Pj3RequireReleaseSigning=true`, so it
**fails** with a list of the missing items instead of falling back to the debug
key. Add `-NoAab` / `--no-aab` to skip the bundle.

Both scripts print `apksigner verify --print-certs` (signer DN and certificate
digests), refuse to label a debug-signed APK as a release (and vice versa),
check package id `com.j3nsontop.multitool`, `versionName`/`versionCode` against
`pubspec.yaml` and the native code for `arm64-v8a`, `armeabi-v7a` and `x86_64`
(`aapt2 dump badging`), report 16 KB page alignment (`zipalign -c -P 16`) and
write `android-build-info.txt`.

Running `flutter build apk --release` directly also works: it uses the release
key if one is fully configured and otherwise the debug key (a TEST build; Gradle
prints a warning).

### Android configuration notes

* `applicationId`/`namespace` `com.j3nsontop.multitool`, label
  `J3NSONTOP Multitool`, `MainActivity` in `com.j3nsontop.multitool`.
* `minSdk 24`, `targetSdk 36`, `compileSdk 36` (Flutter defaults), NDK
  `28.2.13676358`, Java/Kotlin target 17.
* ABIs: Flutter's defaults `arm64-v8a`, `armeabi-v7a`, `x86_64` (one "fat" APK;
  the AAB lets Play deliver per-device splits). 32-bit x86 is not supported by
  Flutter release builds.
* Permissions: only `INTERNET` (for the HTTP developer tool). **No storage
  permissions**: files are opened and saved exclusively through the system
  pickers and the share sheet.
* Cleartext HTTP: `res/xml/network_security_config.xml` permits `http://`.
  *Why:* the HTTP tool is used against development endpoints the user types in
  explicitly - typically LAN IPs, `10.0.2.2` (emulator host) or `*.local` dev
  servers without TLS - and the app warns whenever an `http://` URL is used.
  *Trade-off:* platform networking in the app may use unencrypted HTTP, so
  traffic to such endpoints can be read or modified on the network. HTTPS
  still trusts only the system CA store (user-installed CAs are not trusted).
  Note that Flutter's own `dart:io` HTTP client does not consult this file (the
  engine passes an empty domain network policy, see flutter/flutter#72723), so
  the file mainly governs Android platform networking such as media playback;
  it is declared so the behaviour is explicit and consistent.

---

## 4. iOS build (macOS only)

Prerequisites: a Mac with **Xcode 26.x** (CI: 26.6; Flutter requires >= 15),
`sudo xcode-select -s /Applications/Xcode.app` (or the versioned app), the
iOS platform installed in Xcode, and Flutter 3.47.5. Plugins are integrated
with **Swift Package Manager** (`FlutterGeneratedPluginSwiftPackage`); there is
no Podfile and CocoaPods is not needed.

```bash
flutter pub get --enforce-lockfile
scripts/build_ios.sh
```

Produces `dist/J3NSONTOP-Multitool-<ver>-ios-UNSIGNED-compile-check.zip`
(`Runner.app` + `README.txt`). It proves the project compiles; **it is not
installable** on any iPhone/iPad and is never named `.ipa`.

Signed IPA (Apple Developer Program membership, certificate + profile - see
[SIGNING.md](SIGNING.md)); the certificate with its private key must be in your
login keychain:

```bash
scripts/build_ios.sh --signed --export-method ad-hoc \
  --team-id ABCDE12345 --profile ~/Downloads/J3NSONTOP_AdHoc.mobileprovision
```

It checks the profile (team, bundle id `com.j3nsontop.multitool`, expiry,
profile type vs. export method, a matching identity in the keychain), installs
it, switches only the `Runner` target's Release/Profile configurations to
manual signing (`scripts/ci/ios_configure_signing.rb`, restored afterwards),
writes `ExportOptions.plist` (`scripts/ci/make_export_options.sh`), runs
`flutter build ipa --release --export-options-plist=...`, verifies the result
(`codesign --verify`, `codesign -dv`, embedded profile and bundle id) and writes
`dist/J3NSONTOP-Multitool-<ver>-ios-<method>.ipa`. Needs the `xcodeproj` Ruby gem
(`gem install xcodeproj`; it comes with CocoaPods).

### iOS configuration notes

* Bundle ids: `com.j3nsontop.multitool` (Runner) and
  `com.j3nsontop.multitool.RunnerTests`; home-screen name `J3NSONTOP`
  (`CFBundleDisplayName`), `CFBundleName` `J3NSONTOP` (Apple recommends at most
  15 characters). Deployment target iOS 15.0 (the highest plugin requirement is
  iOS 14.0, `file_picker_darwin`).
* `NSAppTransportSecurity` -> `NSAllowsLocalNetworking = true`: allows plain
  HTTP only to local-network destinations (IP addresses, unqualified host
  names, `.local`) for Apple networking APIs, matching the HTTP tool's LAN use
  case while keeping ATS for the internet. As on Android, Flutter's `dart:io`
  client is not governed by ATS.
* `NSLocalNetworkUsageDescription`: iOS 14+ asks the user before the app may
  talk to devices on the local network (this applies to `dart:io` sockets too);
  the text explains that this only happens when the user sends a request to a
  local address in the HTTP tool.
* `NSPhotoLibraryAddUsageDescription`: the share sheet offers "Save Image" for
  exported images; iOS terminates apps that trigger this without a usage
  description.
* `ITSAppUsesNonExemptEncryption = false`: the app only uses encryption provided
  by the OS / standard HTTPS (TLS) and hashing; it implements no proprietary or
  non-standard encryption, so it is exempt from export documentation and App
  Store Connect does not ask the export-compliance question for every build.
  Re-evaluate this if encryption features are ever added.
* No `UISupportsDocumentBrowser`; files come in and go out through the system
  document picker and share sheet.

---

## 5. Linux (development target)

```bash
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  libstdc++-12-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-good
flutter run -d linux
flutter build linux --release     # -> build/linux/x64/release/bundle/
scripts/ci/linux_smoke.sh         # headless self test (uses xvfb-run if no display)
```

Window title `J3NSONTOP Multitool`, default size 1360 x 860, GTK application id
`com.j3nsontop.multitool`.

---

## 6. Troubleshooting

| Problem | Fix |
| --- | --- |
| `ISCC.exe` not found | Install Inno Setup 6 or pass `-SkipInstaller`. |
| App does not start on another PC ("VCRUNTIME140_1.dll was not found") | Use the ZIP/installer from `dist\`, not `build\...\Release` before packaging; the script adds the runtime DLLs. |
| Windows SmartScreen "Windows protected your PC" | The build is not code-signed. Compare the SHA-256 with `SHA256SUMS`, then *More info* -> *Run anyway*, or configure signing ([SIGNING.md](SIGNING.md)). |
| `Release signing is required ... Missing: ...` | The keystore/passwords are not configured; see [SIGNING.md](SIGNING.md). |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | The installed app has a different signature (test vs. release or another PC's debug key). Uninstall it first. |
| iOS: "No valid ... identity in the keychain matches ..." | Import the `.p12` for the certificate that the profile was created with. |
| `dart format` fails in CI | Run `dart format lib test integration_test tool` and commit. |
