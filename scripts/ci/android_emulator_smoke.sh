#!/usr/bin/env bash
# Installs and launches the APK on a running emulator/device and checks that
# the app starts, stays alive, survives a relaunch and does not crash. Then
# runs the integration tests on the same device if any exist.
#
#   scripts/ci/android_emulator_smoke.sh <apk-or-dir> <out-dir>
#
# Writes logcat dumps, am-start output and screenshots to <out-dir>.
# Meant to be the single `script:` line of reactivecircus/android-emulator-runner
# (that action runs every script line in its own `sh -c`).
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

apk_arg="${1:?usage: android_emulator_smoke.sh <apk-or-dir> <out-dir>}"
out="${2:?usage: android_emulator_smoke.sh <apk-or-dir> <out-dir>}"
serial="emulator-${EMULATOR_PORT:-5554}"
pkg="$J3_APP_ID"
activity="$pkg/.MainActivity"
mkdir -p "$out"

if [ -d "$apk_arg" ]; then
  apk="$(find "$apk_arg" -maxdepth 2 -name '*.apk' -print | head -n 1)"
else
  apk="$apk_arg"
fi
if [ -z "$apk" ] || [ ! -f "$apk" ]; then
  j3_die "APK not found: $apk_arg"
fi
j3_require_cmd adb

adb_s() { adb -s "$serial" "$@"; }
pid_of_app() { adb_s shell pidof "$pkg" 2>/dev/null | tr -d '\r' || true; }

results=()
record() {
  results+=("| $1 | $2 |")
  j3_info "$1 -> $2"
}
write_summary() {
  local line
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    printf '### Android emulator smoke test (%s)\n\n| Check | Result |\n| --- | --- |\n' "$serial"
    for line in ${results[@]+"${results[@]}"}; do printf '%s\n' "$line"; done
    printf '\n'
  } >>"$GITHUB_STEP_SUMMARY"
}
fail() {
  record "FAILED" "$*"
  write_summary
  adb_s logcat -d -v threadtime >"$out/logcat-full.txt" 2>/dev/null || true
  j3_die "$*"
}

adb_s wait-for-device
sdk_level="$(adb_s shell getprop ro.build.version.sdk | tr -d '\r')"
abi="$(adb_s shell getprop ro.product.cpu.abi | tr -d '\r')"
record "Device" "$serial, API $sdk_level, $abi"

# --- Install --------------------------------------------------------------------
adb_s logcat -c || true
adb_s uninstall "$pkg" >/dev/null 2>&1 || true
j3_info "Installing $(basename "$apk")"
install_ok="yes"
adb_s install -r "$apk" >"$out/install.txt" 2>&1 || install_ok="no"
cat "$out/install.txt"
if [ "$install_ok" != "yes" ] || ! grep -q "Success" "$out/install.txt"; then
  fail "adb install failed"
fi
adb_s shell dumpsys package "$pkg" | grep -E "versionName|versionCode|targetSdk" | tr -d '\r' | sed 's/^ */  /' | tee "$out/package.txt" || true
record "Install" "OK ($(basename "$apk"))"

# --- Launch ---------------------------------------------------------------------
# Sets launched_pid (not run in a subshell, so fail/record keep working).
launched_pid=""
launch() {
  local name="$1" wait_s="$2"
  adb_s shell am start -W -n "$activity" >"$out/am-start-$name.raw" 2>&1 || true
  tr -d '\r' <"$out/am-start-$name.raw" >"$out/am-start-$name.txt"
  rm -f "$out/am-start-$name.raw"
  cat "$out/am-start-$name.txt"
  if grep -q "^Error" "$out/am-start-$name.txt" || ! grep -q "Status: ok" "$out/am-start-$name.txt"; then
    fail "am start ($name) did not report Status: ok"
  fi
  sleep "$wait_s"
  launched_pid="$(pid_of_app)"
  if [ -z "$launched_pid" ]; then
    fail "$pkg is not running ${wait_s}s after the $name launch (crashed or exited)"
  fi
  adb_s exec-out screencap -p >"$out/screen-$name.png" || j3_warn "screencap failed"
}

launch first 20
pid1="$launched_pid"
record "Cold start" "OK, alive after 20 s (pid $pid1)"

adb_s shell am force-stop "$pkg"
sleep 2
if [ -n "$(pid_of_app)" ]; then
  fail "$pkg is still running after am force-stop"
fi
launch relaunch 10
pid2="$launched_pid"
record "Force-stop + relaunch" "OK, alive after 10 s (pid $pid2)"

# --- Crash / error scan ---------------------------------------------------------
adb_s logcat -d -v threadtime >"$out/logcat-full.txt" || true
adb_s logcat -d -b crash -v threadtime >"$out/logcat-crash.txt" 2>/dev/null || true
grep -E "FATAL EXCEPTION|AndroidRuntime|[[:space:]][EF] flutter|Fatal signal|ANR in" "$out/logcat-full.txt" \
  >"$out/logcat-filtered.txt" || true
echo "----- logcat (filtered) -----"
cat "$out/logcat-filtered.txt"
echo "-----------------------------"

crashed="no"
if grep -qE "Process: $pkg|ANR in $pkg" "$out/logcat-full.txt" "$out/logcat-crash.txt"; then crashed="yes"; fi
for pid in "$pid1" "$pid2"; do
  if grep -qE "Fatal signal .*pid ${pid}[ ,(]" "$out/logcat-full.txt" "$out/logcat-crash.txt"; then crashed="yes"; fi
done
if grep -qE "[[:space:]]F flutter" "$out/logcat-full.txt"; then crashed="yes"; fi
if [ "$crashed" != "no" ]; then
  fail "$pkg crashed (see logcat-filtered.txt / logcat-crash.txt)"
fi

flutter_errors="$(grep -cE "[[:space:]]E flutter" "$out/logcat-full.txt" || true)"
if [ "${flutter_errors:-0}" -gt 0 ]; then
  j3_warn "logcat contains $flutter_errors 'E flutter' line(s); see logcat-filtered.txt."
  record "Crash scan" "no crash; $flutter_errors Flutter error log line(s) (warning)"
else
  record "Crash scan" "no crash, no Flutter errors"
fi

# --- Integration tests ------------------------------------------------------------
if [ -n "$(j3_integration_tests)" ]; then
  if command -v flutter >/dev/null 2>&1; then
    # The debug test APK is signed with a different debug key; start clean.
    adb_s uninstall "$pkg" >/dev/null 2>&1 || true
    if bash "$J3_REPO_ROOT/scripts/ci/integration_tests.sh" "$serial" "Android emulator API $sdk_level"; then
      record "Integration tests" "passed"
    else
      fail "integration tests failed on $serial"
    fi
  else
    fail "integration tests exist but flutter is not on PATH"
  fi
else
  echo "No integration tests found (integration_test/**/*_test.dart) - skipping."
  record "Integration tests" "skipped (none in integration_test/)"
fi

write_summary
j3_info "Android emulator smoke test passed."
