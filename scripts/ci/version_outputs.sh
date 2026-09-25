#!/usr/bin/env bash
# Prints the app version from pubspec.yaml and, on GitHub Actions, writes it
# to $GITHUB_OUTPUT as version (1.0.0), build_number (1), full_version (1.0.0+1).
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
j3_read_version
{
  echo "version=$J3_VERSION"
  echo "build_number=$J3_BUILD_NUMBER"
  echo "full_version=$J3_VERSION_FULL"
} | tee -a "${GITHUB_OUTPUT:-/dev/null}"
