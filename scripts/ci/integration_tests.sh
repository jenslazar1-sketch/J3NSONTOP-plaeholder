#!/usr/bin/env bash
# Runs `flutter test integration_test -d <device>` if integration tests exist.
#
#   scripts/ci/integration_tests.sh <device-id> "<label>" [--xvfb]
#
# Skips (exit 0) with a clear message when integration_test/ contains no
# *_test.dart files. Otherwise the exit code is that of `flutter test`.
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

device="${1:?usage: integration_tests.sh <device-id> <label> [--xvfb]}"
label="${2:-$device}"
use_xvfb="${3:-}"
cd "$J3_REPO_ROOT"

tests="$(j3_integration_tests)"
if [ -z "$tests" ]; then
  echo "No integration tests found (integration_test/**/*_test.dart) - skipping integration tests on $label."
  j3_summary_text "### Integration tests ($label)" "" "Skipped: integration_test/ contains no *_test.dart files." ""
  exit 0
fi
echo "Integration tests:"
printf '%s\n' "$tests" | sed 's/^/  /'

safe_label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '_')"
report="${RUNNER_TEMP:-$(mktemp -d)}/integration-$safe_label.json"
rm -f "$report"
cmd=(flutter test integration_test -d "$device" --reporter expanded --file-reporter "json:$report")
if [ "$use_xvfb" = "--xvfb" ]; then
  j3_require_cmd xvfb-run
  cmd=(xvfb-run -a -s "-screen 0 1920x1080x24" "${cmd[@]}")
fi

set +e
"${cmd[@]}"
code=$?
set -e
python3 "$J3_REPO_ROOT/scripts/ci/test_report.py" "$report" "Integration tests ($label)"
exit "$code"
