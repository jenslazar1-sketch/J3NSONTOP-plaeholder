#!/usr/bin/env bash
# iOS Simulator smoke test (macOS + Xcode).
#
#   scripts/ci/ios_simulator_smoke.sh <out-dir>
#
# Boots the newest available iPhone simulator. If integration tests exist it
# runs `flutter test integration_test -d <udid>`. Otherwise it builds a debug
# simulator app, installs and launches it, checks that it is still running
# after 20 s and after a relaunch, looks for crash reports and saves
# screenshots to <out-dir>.
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

# --- Integration tests, if any -----------------------------------------------------------
if [ -n "$(j3_integration_tests)" ]; then
  if bash "$J3_REPO_ROOT/scripts/ci/integration_tests.sh" "$udid" "iOS Simulator $device_name ($ios_version)"; then
    record "Integration tests" "passed"
    xcrun simctl io "$udid" screenshot "$out/ios-simulator-after-tests.png" >/dev/null 2>&1 || true
    write_summary
    exit 0
  fi
  fail "integration tests failed on the iOS Simulator"
fi
echo "No integration tests found (integration_test/**/*_test.dart) - running the install/launch smoke test instead."
record "Integration tests" "skipped (none in integration_test/)"

# --- Build, install, launch ------------------------------------------------------------------
j3_info "flutter build ios --simulator --debug"
flutter build ios --simulator --debug
app="$J3_REPO_ROOT/build/ios/iphonesimulator/Runner.app"
[ -d "$app" ] || fail "Simulator build not found: $app"
xcrun simctl uninstall "$udid" "$J3_APP_ID" >/dev/null 2>&1 || true
xcrun simctl install "$udid" "$app"
record "Install" "OK"

marker="$work/start-marker"
touch "$marker"
reports_dir="$HOME/Library/Logs/DiagnosticReports"

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
  [ -n "$pid" ] || fail "The app is not running ${wait_s}s after the $name launch (crashed or exited)."
  xcrun simctl io "$udid" screenshot "$out/ios-simulator-$name.png" >/dev/null 2>&1 || j3_warn "screenshot failed"
  record "Launch ($name)" "OK, alive after ${wait_s} s (pid $pid)"
}

launch first 20
xcrun simctl terminate "$udid" "$J3_APP_ID" || true
sleep 2
launch relaunch 10

crash_reports="$(find "$reports_dir" -maxdepth 1 -name 'Runner*' -newer "$marker" -print 2>/dev/null || true)"
if [ -n "$crash_reports" ]; then
  printf '%s\n' "$crash_reports" | while IFS= read -r report; do cp "$report" "$out/" || true; done
  fail "Crash report(s) were written for Runner: $(printf '%s' "$crash_reports" | tr '\n' ' ')"
fi
record "Crash reports" "none"

xcrun simctl spawn "$udid" log show --last 3m --style compact --predicate 'process == "Runner"' \
  >"$out/runner-log.txt" 2>/dev/null || true
xcrun simctl terminate "$udid" "$J3_APP_ID" >/dev/null 2>&1 || true
write_summary
j3_info "iOS Simulator smoke test passed."
