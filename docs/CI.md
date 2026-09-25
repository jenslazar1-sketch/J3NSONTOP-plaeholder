# Continuous integration and release workflows

Two GitHub Actions workflows live in `.github/workflows/`:

| Workflow | Trigger | Secrets | Purpose |
| --- | --- | --- | --- |
| `ci.yml` (**CI**) | every push (all branches), every pull request, manual | **none** | checks, tests, test builds for all platforms, smoke tests on real runtimes |
| `release.yml` (**Release**) | manual only | only for `build_type=release` | test or signed builds per platform |

Common rules: `permissions: contents: read`, one run per workflow and ref at a
time (`concurrency: ${{ github.workflow }}-${{ github.ref }}`; CI cancels an
older run of the same branch, Release never cancels), `timeout-minutes` on
every job, actions pinned to commit SHAs ([TOOLCHAIN.md](TOOLCHAIN.md)), the
Flutter SDK and pub cache cached by `subosito/flutter-action` (pub cache keyed
by `pubspec.lock`), Gradle caches keyed by the Gradle files + `pubspec.lock`,
and a short Markdown summary per job (artifact, version, size, SHA-256,
signing status). Every downloadable file has a `.sha256` next to it.

## CI (`ci.yml`)

```
validate ─┬─ android-test-apk ── android-emulator-smoke
          ├─ windows ─────────── windows-clean-smoke
          ├─ ios-unsigned
          └─ ios-simulator-smoke
```

| Job | Runner | What it does | Artifact |
| --- | --- | --- | --- |
| `validate` | ubuntu-24.04 | `flutter pub get --enforce-lockfile`; `dart format --output=none --set-exit-if-changed` on `lib test integration_test tool`; `flutter analyze`; `flutter test --reporter expanded` (counts in the summary); Linux desktop deps; `xvfb-run -a flutter test integration_test -d linux` (skipped with a message if `integration_test/` has no `*_test.dart`); `flutter build linux --release`; runs the bundle headless with `--smoke-test=$RUNNER_TEMP/smoke.json --data-dir=$RUNNER_TEMP/smoke-data` (120 s timeout) and fails on a non-zero exit, a missing report or `"ok": false` (report printed) | `validate-reports` (test JSON, smoke report) |
| `android-test-apk` | ubuntu-24.04 | JDK 17, `scripts/build_android.sh --mode test`: release-mode APK signed with the debug key, `apksigner verify --print-certs`, `aapt2 dump badging` (package, version, minSdk, targetSdk, native code), SHA-256 | `J3NSONTOP-Multitool-<ver>-android-test-apk` |
| `android-emulator-smoke` | ubuntu-24.04 (KVM) | Android 14 (API 34, `google_apis`, x86_64) emulator: `adb install -r`, `am start -W`, waits 20 s, requires `pidof com.j3nsontop.multitool`, scans `logcat` (FATAL EXCEPTION / AndroidRuntime / Flutter errors / native crashes / ANR) and fails if the app crashed, takes screenshots, force-stop + relaunch check, then `flutter test integration_test -d emulator-5554` if integration tests exist | `android-emulator-smoke` (screenshots, logcat) |
| `windows` | windows-2025 | `scripts/build_windows.ps1`: release build, app-local MSVC runtime, bundle + import verification, portable ZIP, Inno Setup installer, Authenticode status | `J3NSONTOP-Multitool-<ver>-windows-x64-portable`, `J3NSONTOP-Multitool-<ver>-windows-x64-setup` |
| `windows-clean-smoke` | windows-2025, **no Flutter/VS set up** | `scripts/ci/windows_smoke.ps1`: checksums; extracts the ZIP to `%RUNNER_TEMP%\J3NSØNTØP Tëst 测试\`; required files; runs the exe with `--smoke-test` / `--data-dir` in non-ASCII paths (exit code + `"ok": true`); normal start (alive, window title, runtime DLLs loaded from the app folder); silent install into a non-ASCII folder, Start menu shortcut and uninstall entry, installed smoke test, silent uninstall and removal check; Authenticode status | `windows-clean-smoke` (reports, installer logs) |
| `ios-unsigned` | macos-26, Xcode 26.6 | `flutter build ios --release --no-codesign`, zips `Runner.app` + README ("NOT installable") | `J3NSONTOP-Multitool-<ver>-ios-UNSIGNED-compile-check` |
| `ios-simulator-smoke` | macos-26, Xcode 26.6 | boots the newest available iPhone simulator; runs integration tests if present, otherwise builds a debug simulator app, installs, launches, checks it is running after 20 s and after a relaunch, checks for crash reports, takes screenshots | `ios-simulator-smoke` |

Nothing in CI is signed with a real key, so it is safe for pull requests from
forks. The Windows runner image has the VC++ runtime installed system-wide;
the build therefore also checks every DLL import with `dumpbin`, and the smoke
test verifies that the runtime DLLs are loaded from the app folder.

## Release (`release.yml`)

Inputs:

| Input | Values | Meaning |
| --- | --- | --- |
| `platform` | `all` (default), `android`, `ios`, `windows` | what to build |
| `build_type` | `test` (default), `release` | `test`: the same unsigned / debug-signed artifacts as CI, no secrets read. `release`: signed builds |
| `ios_export_method` | `ad-hoc` (default), `development`, `app-store`, `enterprise` | iOS export for `build_type=release` ([SIGNING.md](SIGNING.md#which-export-method-gives-what)) |

Jobs: `plan` (version + planned outputs in the summary), `validate` (format,
analyze, unit tests via `scripts/check.sh`), then per platform:

| Job | Runs when | Output artifact |
| --- | --- | --- |
| `android-test` | android, `test` | `J3NSONTOP-Multitool-<ver>-android-test-apk` |
| `android-release` | android, `release` | `J3NSONTOP-Multitool-<ver>-android-release` (APK + AAB, `android-build-info.txt`). Fails first if any of `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` is missing, naming them. The keystore is removed in an `if: always()` step. |
| `ios-unsigned` | ios, `test` | `J3NSONTOP-Multitool-<ver>-ios-UNSIGNED-compile-check` |
| `ios-release` | ios, `release` | `J3NSONTOP-Multitool-<ver>-ios-<method>` (`.ipa`). Fails first if `IOS_CERTIFICATE_P12_BASE64`, `IOS_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64` or `IOS_TEAM_ID` (secret or variable) is missing. Keychain and profile are deleted in an `if: always()` step. |
| `windows` | windows | `...-windows-x64-portable`, `...-windows-x64-setup`; Authenticode-signed only for `release` **and** when `WINDOWS_CERTIFICATE_PFX_BASE64` + `WINDOWS_CERTIFICATE_PASSWORD` exist, otherwise the summary says "not code-signed" |
| `windows-smoke` | after `windows` | same clean-machine test as CI |

The summary never calls a skipped or unsigned build "signed": the signing
column is derived from the verified artifact (apksigner signer, `codesign`
authority, `Get-AuthenticodeSignature`).

## Running the workflows

### From the GitHub web UI (works from any Windows browser)

1. Open the repository -> **Actions**.
2. Pick **CI** or **Release** in the left list.
3. **Run workflow** (top right) -> choose the branch and, for Release, the
   inputs -> **Run workflow**.
4. Open the run; when it is done, the **Artifacts** section at the bottom of
   the run's summary page has the downloads (ZIP files). The job summaries show
   the SHA-256 of every file.

CI also runs automatically on every push and pull request.

### With the GitHub CLI (`gh`, e.g. in PowerShell)

```powershell
gh workflow run ci.yml --ref main
gh workflow run release.yml --ref main -f platform=all -f build_type=test
gh workflow run release.yml --ref main -f platform=android -f build_type=release
gh workflow run release.yml --ref main -f platform=ios -f build_type=release -f ios_export_method=ad-hoc

gh run list --workflow release.yml          # find the run id
gh run watch <run-id>
gh run download <run-id> -n J3NSONTOP-Multitool-1.0.0-windows-x64-setup
```

Verify a download: `Get-FileHash .\J3NSONTOP-Multitool-1.0.0-windows-x64-setup.exe -Algorithm SHA256`
(Windows) or `sha256sum -c <file>.sha256` (macOS/Linux: `shasum -a 256 -c`).

Artifact retention: test artifacts 14-30 days, release artifacts 90 days
(or the repository maximum). Attach release files to a GitHub Release if they
must be kept longer.

## Billing notes

* **Public repositories**: standard GitHub-hosted runners (Linux, Windows,
  macOS) are free.
* **Private repositories**: usage counts against the account's included
  minutes and is billed beyond that. Windows minutes cost more than Linux, and
  **macOS minutes cost several times (about 10x) as much as Linux** - the two
  iOS jobs are the most expensive part of CI. For a private repository consider
  running CI with `workflow_dispatch` only for iOS, or restricting the iOS jobs
  to the default branch. Check GitHub's current pricing page for exact rates.
* The Android emulator job needs KVM, which the standard `ubuntu-24.04` runner
  provides.
* Cached Flutter SDK / pub / Gradle data counts towards the repository's cache
  storage limit (old entries are evicted automatically).
