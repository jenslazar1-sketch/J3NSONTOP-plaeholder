#!/usr/bin/env bash
# Runs the Linux release bundle with --smoke-test (headless via xvfb-run when
# no display is available) and validates the JSON report.
#
#   scripts/ci/linux_smoke.sh [bundle-dir] [timeout-seconds]
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

bundle="${1:-$J3_REPO_ROOT/build/linux/x64/release/bundle}"
timeout_s="${2:-120}"
exe="$bundle/j3nsontop_multitool"
[ -x "$exe" ] || j3_die "Linux bundle executable not found: $exe"
j3_require_cmd timeout python3

tmp="${RUNNER_TEMP:-$(mktemp -d)}"
report="$tmp/smoke.json"
data_dir="$tmp/smoke-data"
rm -rf "$report" "$data_dir"

runner=()
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  j3_require_cmd xvfb-run
  runner=(xvfb-run -a -s "-screen 0 1920x1080x24")
fi

j3_info "Running $exe --smoke-test=$report --data-dir=$data_dir (timeout ${timeout_s}s)"
set +e
${runner[@]+"${runner[@]}"} timeout --kill-after=15 "$timeout_s" \
  "$exe" --smoke-test="$report" --data-dir="$data_dir"
code=$?
set -e
j3_info "Exit code: $code"
python3 "$J3_REPO_ROOT/scripts/ci/check_smoke_report.py" "$report" "$code" "Linux release bundle (xvfb)"
