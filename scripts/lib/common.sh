# shellcheck shell=bash
# Shared helpers for the J3NSONTOP build scripts. Source it, do not execute it.
# Compatible with bash 3.2 (macOS /bin/bash) and later.

# Used by the scripts that source this file.
# shellcheck disable=SC2034
J3_APP_ID="com.j3nsontop.multitool"
# shellcheck disable=SC2034
J3_ARTIFACT_PREFIX="J3NSONTOP-Multitool"
# shellcheck disable=SC2034
J3_ANDROID_DEBUG_CERT_DN="CN=Android Debug"

J3_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export J3_REPO_ROOT

j3_info() { printf '==> %s\n' "$*"; }

j3_warn() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::warning::%s\n' "$*"
  else
    printf 'WARNING: %s\n' "$*" >&2
  fi
}

j3_die() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::error::%s\n' "$*"
  else
    printf 'ERROR: %s\n' "$*" >&2
  fi
  exit 1
}

j3_require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || j3_die "Required command not found: $cmd"
  done
}

# Reads `version:` from pubspec.yaml and sets:
#   J3_VERSION_FULL  e.g. 1.0.0+1
#   J3_VERSION       e.g. 1.0.0   (used in artifact file names)
#   J3_BUILD_NUMBER  e.g. 1
j3_read_version() {
  local line re
  line="$(grep -E '^version:' "$J3_REPO_ROOT/pubspec.yaml" | head -n 1 |
    sed -E 's/^version:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' | tr -d "\"'\r")"
  re='^([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)(\+([0-9]+))?$'
  if [[ ! "$line" =~ $re ]]; then
    j3_die "Cannot parse 'version: $line' in pubspec.yaml (expected x.y.z+n)."
  fi
  J3_VERSION="${BASH_REMATCH[1]}"
  J3_BUILD_NUMBER="${BASH_REMATCH[4]:-0}"
  J3_VERSION_FULL="$line"
  export J3_VERSION J3_BUILD_NUMBER J3_VERSION_FULL
}

j3_sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

j3_size_of() { wc -c <"$1" | tr -d ' '; }

j3_human_size() {
  awk -v b="$1" 'BEGIN {
    split("B KiB MiB GiB", u, " "); i = 1
    while (b >= 1024 && i < 4) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]
  }'
}

# Writes "<sha256>  <file name>" to <file>.sha256 (sha256sum -c compatible).
j3_write_sha256() {
  local file="$1" hash
  hash="$(j3_sha256_of "$file")"
  printf '%s  %s\n' "$hash" "$(basename "$file")" >"$file.sha256"
  printf '%s' "$hash"
}

# Regenerates <dir>/SHA256SUMS for every distributable file in <dir>.
j3_update_sha256sums() {
  local dir="$1" f
  : >"$dir/SHA256SUMS.tmp"
  for f in "$dir"/*.apk "$dir"/*.aab "$dir"/*.ipa "$dir"/*.zip "$dir"/*.exe; do
    [ -f "$f" ] || continue
    printf '%s  %s\n' "$(j3_sha256_of "$f")" "$(basename "$f")" >>"$dir/SHA256SUMS.tmp"
  done
  mv "$dir/SHA256SUMS.tmp" "$dir/SHA256SUMS"
}

# Appends a Markdown table to the GitHub step summary (no-op locally).
# Usage: j3_summary_table "<title>" "<file>|<signing status>" ...
j3_summary_table() {
  local title="$1" entry file status size hash
  shift
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    printf '### %s\n\n' "$title"
    printf '| Artifact | Version | Size | SHA-256 | Signing |\n'
    printf '| --- | --- | --- | --- | --- |\n'
    for entry in "$@"; do
      file="${entry%%|*}"
      status="${entry#*|}"
      size="$(j3_human_size "$(j3_size_of "$file")")"
      hash="$(j3_sha256_of "$file")"
      # shellcheck disable=SC2016 # literal Markdown backticks
      printf '| `%s` | %s | %s | `%s` | %s |\n' "$(basename "$file")" "${J3_VERSION_FULL:-?}" "$size" "$hash" "$status"
    done
    printf '\n'
  } >>"$GITHUB_STEP_SUMMARY"
}

j3_summary_text() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"
}

# Lists the integration test files (integration_test/**/*_test.dart).
# Build label shown in the app (About -> Build label, diagnostics) so testers
# can name the exact build: J3_BUILD_LABEL if set, "ci<run>-<sha7>" in the CI
# workflow, "rel<run>-<sha7>" in the Release workflow, else "local-<sha7>".
j3_build_label() {
  local sha
  if [ -n "${J3_BUILD_LABEL:-}" ]; then
    printf '%s\n' "$J3_BUILD_LABEL"
  elif [ -n "${GITHUB_RUN_NUMBER:-}" ] && [ -n "${GITHUB_SHA:-}" ]; then
    if [ "${GITHUB_WORKFLOW:-}" = "Release" ]; then printf 'rel'; else printf 'ci'; fi
    printf '%s-%s\n' "$GITHUB_RUN_NUMBER" "${GITHUB_SHA:0:7}"
  elif sha="$(git -C "$J3_REPO_ROOT" rev-parse --short=7 HEAD 2>/dev/null)"; then
    printf 'local-%s\n' "$sha"
  else
    printf 'local\n'
  fi
}

# The --dart-define argument that bakes the build label into a build.
j3_build_label_define() { printf -- '--dart-define=J3_BUILD_LABEL=%s\n' "$(j3_build_label)"; }

j3_integration_tests() {
  [ -d "$J3_REPO_ROOT/integration_test" ] || return 0
  find "$J3_REPO_ROOT/integration_test" -type f -name '*_test.dart' | sort
}
