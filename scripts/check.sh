#!/usr/bin/env bash
# Static checks and unit/widget tests - the same gate CI runs first.
#
#   scripts/check.sh
#
# Steps: pub get (locked), dart format check, flutter analyze, flutter test.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
j3_require_cmd flutter dart
cd "$J3_REPO_ROOT"

j3_info "flutter pub get --enforce-lockfile"
flutter pub get --enforce-lockfile

format_dirs=()
for d in lib test integration_test tool; do
  [ -d "$d" ] && format_dirs+=("$d")
done
j3_info "dart format check: ${format_dirs[*]}"
dart format --output=none --set-exit-if-changed "${format_dirs[@]}"

j3_info "flutter analyze"
flutter analyze

j3_info "flutter test"
flutter test "$@"

j3_info "All checks passed."
