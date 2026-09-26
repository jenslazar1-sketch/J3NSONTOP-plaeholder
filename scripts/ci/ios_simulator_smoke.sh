#!/usr/bin/env bash
# iOS Simulator smoke test (macOS + Xcode).
#
#   scripts/ci/ios_simulator_smoke.sh <out-dir>
#
# Boots the newest available iPhone simulator, builds a debug simulator app,
# installs and launches it, checks that it is still running after 20 s and
# after a relaunch, and looks for crash reports. Then, if integration tests
# exist, runs `flutter test integration_test -d <udid>` with a time limit.
# Screenshots, the app log and crash reports go to <out-dir>; on failure the
# log tail and crash reports are also printed to the job log.
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

out="${1:-ios-simulator-smoke}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
j3_require_cmd xcrun flutter python3
cd "$J3_REPO_ROOT"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

results=()
record() {
  results+=("| $1 | $2 |")
  j3_info "$1 -> $2"
}
write_summary() {
  local line
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    printf '### iOS Simulator smoke test\n\n| Check | Result |\n| --- | --- |\n'
    for line in ${results[@]+"${results[@]}"}; do printf '%s\n' "$line"; done
    printf '\n'
  } >>"$GITHUB_STEP_SUMMARY"
}
fail() {
  record "FAILED" "$*"
  write_summary
  j3_die "$*"
}

# --- Pick and boot a simulator ------------------------------------------------------
xcrun simctl list devices available -j >"$work/devices.json"
cat >"$work/pick.py" <<'PY'
import json, re, sys

data = json.load(open(sys.argv[1]))
best = None
for runtime, devices in data.get("devices", {}).items():
    match = re.search(r"SimRuntime\.iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    for device in devices:
        name = device.get("name", "")
        if not device.get("isAvailable", True) or not name.startswith("iPhone"):
            continue
        key = (version, "Pro" in name and "Max" not in name, name)
        if best is None or key > best[0]:
            best = (key, device["udid"], name, "%d.%d" % version)
if best is None:
    sys.exit("No available iPhone simulator found.")
print(best[1])
print(best[2])
print(best[3])
PY
udid=""
device_name=""
ios_version=""
{
  read -r udid
  read -r device_name
  read -r ios_version
} < <(python3 "$work/pick.py" "$work/devices.json") || true
[ -n "$udid" ] || fail "No available iPhone simulator found."
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b
record "Simulator" "$device_name, iOS $ios_version ($udid)"

# --- Diagnostics shown in the job log on failure ------------------------------------------
reports_dir="$HOME/Library/Logs/DiagnosticReports"
marker="$work/start-marker"
touch "$marker"

dump_diagnostics() {
  local report
  xcrun simctl io "$udid" screenshot "$out/ios-simulator-failure.png" >/dev/null 2>&1 || true
  xcrun simctl spawn "$udid" log show --last 10m --style compact --predicate 'process == "Runner"' \
    >"$out/runner-log.txt" 2>/dev/null || true
  echo "::group::Runner log (last 120 lines)"
  tail -n 120 "$out/runner-log.txt" || true
  echo "::endgroup::"
  find "$reports_dir" -maxdepth 1 -name 'Runner*' -newer "$marker" -print 2>/dev/null | while IFS= read -r report; do
    cp "$report" "$out/" || true
    echo "::group::Crash report $(basename "$report") (first 200 lines)"
    head -n 200 "$report" || true
    echo "::endgroup::"
  done
}

# Runs "$@" in its own process group; kills the whole group after $1 seconds.
run_with_timeout() {
  local secs="$1" pid waited=0
  shift
  set -m
  "$@" &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      sleep 5
      kill -KILL -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 5
    waited=$((waited + 5))
  done
  wait "$pid"
}

# --- Build, install, launch (always; independent of the test runner) ---------------------------
j3_info "flutter build ios --simulator --debug $(j3_build_label_define)"
flutter build ios --simulator --debug "$(j3_build_label_define)"
app="$J3_REPO_ROOT/build/ios/iphonesimulator/Runner.app"
[ -d "$app" ] || fail "Simulator build not found: $app"
xcrun simctl uninstall "$udid" "$J3_APP_ID" >/dev/null 2>&1 || true
xcrun simctl install "$udid" "$app"
record "Install" "OK"

app_pid() {
  # launchctl prints "<pid|-> <status> UIKitApplication:<bundle id>[...]".
  xcrun simctl spawn "$udid" launchctl list 2>/dev/null |
    awk -v id="UIKitApplication:$J3_APP_ID" 'index($3, id) == 1 && $1 ~ /^[0-9]+$/ { print $1; exit }'
}

launch() {
  local name="$1" wait_s="$2" pid
  xcrun simctl launch "$udid" "$J3_APP_ID" | tee "$out/launch-$name.txt" || fail "simctl launch ($name) failed"
  sleep "$wait_s"
  pid="$(app_pid || true)"
  if [ -z "$pid" ] && pgrep -f "iphonesimulator/Runner.app/Runner|/Runner.app/Runner" >/dev/null 2>&1; then
    pid="$(pgrep -f "/Runner.app/Runner" | head -n 1)"
  fi
  if [ -z "$pid" ]; then
    dump_diagnostics
    fail "The app is not running ${wait_s}s after the $name launch (crashed or exited)."
  fi
  xcrun simctl io "$udid" screenshot "$out/ios-simulator-$name.png" >/dev/null 2>&1 || j3_warn "screenshot failed"
  record "Launch ($name)" "OK, alive after ${wait_s} s (pid $pid)"
}

launch first 20
xcrun simctl terminate "$udid" "$J3_APP_ID" || true
sleep 2
launch relaunch 10

crash_reports="$(find "$reports_dir" -maxdepth 1 -name 'Runner*' -newer "$marker" -print 2>/dev/null || true)"
if [ -n "$crash_reports" ]; then
  dump_diagnostics
  fail "Crash report(s) were written for Runner: $(printf '%s' "$crash_reports" | tr '\n' ' ')"
fi
record "Crash reports" "none"

# --- Package the simulator app that just passed the launch checks ------------------------
# A tester with a Mac and Xcode can run this build in the iOS Simulator without
# any Apple signing. It is NOT installable on an iPhone or iPad.
j3_read_version
label="$(j3_build_label)"
sim_dist="${J3_IOS_SIM_DIST:-$J3_REPO_ROOT/dist-ios-sim}"
rm -rf "$sim_dist"
mkdir -p "$sim_dist"
sim_zip="$sim_dist/$J3_ARTIFACT_PREFIX-$J3_VERSION-ios-simulator-debug.zip"
archs="$(lipo -archs "$app/Runner" 2>/dev/null || echo unknown)"
stage="$work/sim-package/$J3_ARTIFACT_PREFIX-$J3_VERSION-ios-simulator"
mkdir -p "$stage"
cp -R "$app" "$stage/Runner.app"
cat >"$stage/INSTALL-SIMULATOR.txt" <<TXT
J3NSONTOP Multitool $J3_VERSION - iOS SIMULATOR build
Build label: $label   (shown in the app under About -> Build label)
Mode: debug   Architectures: $archs   Simulator it was tested on: $device_name, iOS $ios_version

This build runs ONLY in the iOS Simulator on a Mac with Xcode. It is not
signed and cannot be installed on an iPhone or iPad (that needs the signed
IPA from the Release workflow, see docs/SIGNING.md).

1. Unzip this file (you get a folder with Runner.app and this note).
2. Open the Simulator: open -a Simulator
3. Drag Runner.app onto the simulator window, or run:
     xcrun simctl install booted Runner.app
     xcrun simctl launch booted $J3_APP_ID

Debug builds are slower than release builds: judge features, not speed.
Report problems as described in docs/TESTING.md.
TXT
# One top-level folder holding Runner.app and the instructions.
ditto -c -k --sequesterRsrc --keepParent "$stage" "$sim_zip" ||
  (cd "$(dirname "$stage")" && zip -qry "$sim_zip" "$(basename "$stage")")
sim_hash="$(j3_write_sha256 "$sim_zip")"
record "Simulator app" "$(basename "$sim_zip") ($(j3_human_size "$(j3_size_of "$sim_zip")"), $archs, SHA-256 $sim_hash)"
xcrun simctl spawn "$udid" log show --last 3m --style compact --predicate 'process == "Runner"' \
  >"$out/runner-log.txt" 2>/dev/null || true
xcrun simctl terminate "$udid" "$J3_APP_ID" >/dev/null 2>&1 || true

# --- Integration tests, if any (time-limited: a runner that never connects fails clearly) ----
if [ -n "$(j3_integration_tests)" ]; then
  limit_s="${J3_IOS_TEST_TIMEOUT_S:-1200}"
  set +e
  run_with_timeout "$limit_s" bash "$J3_REPO_ROOT/scripts/ci/integration_tests.sh" "$udid" \
    "iOS Simulator $device_name ($ios_version)"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    record "Integration tests" "passed"
    xcrun simctl io "$udid" screenshot "$out/ios-simulator-after-tests.png" >/dev/null 2>&1 || true
  elif [ "$status" -eq 124 ]; then
    dump_diagnostics
    fail "Integration tests did not finish within ${limit_s} s (the test runner never reported)."
  else
    dump_diagnostics
    fail "Integration tests failed on the iOS Simulator (exit $status)."
  fi
else
  record "Integration tests" "skipped (none in integration_test/)"
fi

write_summary
j3_info "iOS Simulator smoke test passed."
