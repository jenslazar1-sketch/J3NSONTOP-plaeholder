#!/usr/bin/env bash
# Builds the Android APK (and AAB for releases) and copies it to dist/.
#
#   scripts/build_android.sh                 # TEST build (debug-signed APK)
#   scripts/build_android.sh --mode release  # release-signed APK + AAB
#
# Options:
#   --mode test|release   test (default): release-mode APK signed with the
#                         Android debug key - installable, but a TEST build that
#                         can never be updated by a properly signed release.
#                         release: signed with the release key from
#                         android/key.properties or J3_KEYSTORE_* env vars;
#                         the build FAILS if the key is not fully configured.
#   --no-aab              release mode: skip the App Bundle.
#   --out-dir DIR         output directory (default: dist).
#   --skip-build          only package/verify existing build outputs.
#
# Output: dist/J3NSONTOP-Multitool-<ver>-android-<test-debugsigned|release>.apk
#         (+ .aab for release), <file>.sha256, SHA256SUMS and
#         android-build-info.txt (signer certificate, badging).
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

mode="test"
build_aab="yes"
out_dir="$J3_REPO_ROOT/dist"
skip_build="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode="${2:-}"; shift 2 ;;
    --mode=*) mode="${1#*=}"; shift ;;
    --no-aab) build_aab="no"; shift ;;
    --out-dir) out_dir="${2:-}"; shift 2 ;;
    --out-dir=*) out_dir="${1#*=}"; shift ;;
    --skip-build) skip_build="yes"; shift ;;
    -h | --help) sed -n '2,23p' "$0"; exit 0 ;;
    *) j3_die "Unknown option: $1 (see --help)" ;;
  esac
done
case "$mode" in
  test) build_aab="no" ;;
  release) ;;
  *) j3_die "--mode must be 'test' or 'release' (got '$mode')" ;;
esac

j3_require_cmd flutter
j3_read_version
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
cd "$J3_REPO_ROOT"

# --- Android SDK tools --------------------------------------------------------
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$sdk" ]; then
  for candidate in "$HOME/Android/Sdk" "$HOME/Library/Android/sdk"; do
    [ -d "$candidate" ] && sdk="$candidate" && break
  done
fi
if [ -z "$sdk" ] || [ ! -d "$sdk/build-tools" ]; then
  j3_die "Android SDK not found. Set ANDROID_HOME."
fi
build_tools_version="$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort -V | tail -n 1)"
build_tools="$sdk/build-tools/$build_tools_version"
apksigner="$build_tools/apksigner"
aapt2="$build_tools/aapt2"
zipalign="$build_tools/zipalign"
[ -x "$apksigner" ] || j3_die "apksigner not found in $build_tools"
j3_info "Android SDK: $sdk (build-tools $build_tools_version)"

# --- Build ----------------------------------------------------------------------
if [ "$skip_build" = "no" ]; then
  if [ "$mode" = "release" ]; then
    signing_arg="-Pj3RequireReleaseSigning=true"
  else
    signing_arg="-Pj3ForceDebugSigning=true"
  fi
  j3_info "flutter build apk --release $signing_arg"
  flutter build apk --release "$signing_arg"
  if [ "$build_aab" = "yes" ]; then
    j3_info "flutter build appbundle --release $signing_arg"
    flutter build appbundle --release "$signing_arg"
  fi
fi

built_apk="$J3_REPO_ROOT/build/app/outputs/flutter-apk/app-release.apk"
built_aab="$J3_REPO_ROOT/build/app/outputs/bundle/release/app-release.aab"
[ -f "$built_apk" ] || j3_die "APK not found: $built_apk"

if [ "$mode" = "release" ]; then label="release"; else label="test-debugsigned"; fi
apk="$out_dir/$J3_ARTIFACT_PREFIX-$J3_VERSION-android-$label.apk"
aab="$out_dir/$J3_ARTIFACT_PREFIX-$J3_VERSION-android-$label.aab"
info="$out_dir/android-build-info.txt"
rm -f "$apk" "$apk.sha256" "$aab" "$aab.sha256"
cp "$built_apk" "$apk"

# --- Verify the APK signature -----------------------------------------------------
{
  echo "J3NSONTOP Multitool $J3_VERSION_FULL - Android $mode build"
  echo "Built: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo
  echo "## apksigner verify --print-certs $(basename "$apk")"
} >"$info"
if ! "$apksigner" verify --verbose --print-certs "$apk" >"$info.apksigner" 2>&1; then
  cat "$info.apksigner"
  j3_die "apksigner could not verify $(basename "$apk")"
fi
tee -a "$info" <"$info.apksigner"
signer_dn="$(grep -m 1 'Signer #1 certificate DN:' "$info.apksigner" | sed 's/^Signer #1 certificate DN: //' || true)"
signer_sha256="$(grep -m 1 'Signer #1 certificate SHA-256 digest:' "$info.apksigner" | awk '{print $NF}' || true)"
rm -f "$info.apksigner"
[ -n "$signer_dn" ] || j3_die "No signer certificate found in $(basename "$apk")"

if printf '%s' "$signer_dn" | grep -q "$J3_ANDROID_DEBUG_CERT_DN"; then
  debug_signed="yes"
else
  debug_signed="no"
fi
if [ "$mode" = "release" ] && [ "$debug_signed" = "yes" ]; then
  j3_die "Release APK is signed with the Android DEBUG certificate ($signer_dn). Refusing to label it as a release."
fi
if [ "$mode" = "test" ] && [ "$debug_signed" = "no" ]; then
  j3_die "Test APK is not signed with the Android debug certificate ($signer_dn); refusing to mislabel it."
fi
if [ "$debug_signed" = "yes" ]; then
  apk_signing="debug-signed TEST build (Android debug key) - not for distribution"
else
  apk_signing="release-signed ($signer_dn; cert SHA-256 ${signer_sha256:0:16}...)"
fi
j3_info "Signing: $apk_signing"

# --- Inspect the APK -------------------------------------------------------------------
if [ -x "$aapt2" ]; then
  badging="$("$aapt2" dump badging "$apk")"
  {
    echo
    echo "## aapt2 dump badging (selected lines)"
    printf '%s\n' "$badging" | grep -E "^(package:|sdkVersion:|targetSdkVersion:|application-label:|native-code:|uses-permission:)" || true
  } | tee -a "$info"
  pkg="$(printf '%s\n' "$badging" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
  version_code="$(printf '%s\n' "$badging" | sed -n "s/^package: .*versionCode='\([^']*\)'.*/\1/p")"
  version_name="$(printf '%s\n' "$badging" | sed -n "s/^package: .*versionName='\([^']*\)'.*/\1/p")"
  native_code="$(printf '%s\n' "$badging" | sed -n 's/^native-code: //p')"
  [ "$pkg" = "$J3_APP_ID" ] || j3_die "Unexpected package name '$pkg' (expected $J3_APP_ID)"
  [ "$version_name" = "$J3_VERSION" ] || j3_die "versionName '$version_name' does not match pubspec ($J3_VERSION)"
  [ "$version_code" = "$J3_BUILD_NUMBER" ] || j3_die "versionCode '$version_code' does not match pubspec ($J3_BUILD_NUMBER)"
  for abi in arm64-v8a armeabi-v7a x86_64; do
    printf '%s' "$native_code" | grep -q "'$abi'" || j3_die "APK is missing native code for $abi (native-code: $native_code)"
  done
else
  j3_warn "aapt2 not found in $build_tools; skipping badging checks."
fi

if [ -x "$zipalign" ]; then
  if "$zipalign" -c -P 16 4 "$apk" >/dev/null 2>&1; then
    echo "16 KB page alignment (zipalign -c -P 16 4): OK" | tee -a "$info"
  else
    j3_warn "zipalign -c -P 16 reports the APK is not 16 KB page aligned (required by Google Play for new apps)."
    echo "16 KB page alignment (zipalign -c -P 16 4): NOT OK" >>"$info"
  fi
fi

apk_hash="$(j3_write_sha256 "$apk")"
summary_rows=("$apk|$apk_signing")

# --- App Bundle ----------------------------------------------------------------------
if [ "$build_aab" = "yes" ]; then
  [ -f "$built_aab" ] || j3_die "AAB not found: $built_aab"
  cp "$built_aab" "$aab"
  j3_require_cmd keytool
  aab_certs="$(keytool -printcert -jarfile "$aab" 2>&1 || true)"
  {
    echo
    echo "## keytool -printcert -jarfile $(basename "$aab")"
    printf '%s\n' "$aab_certs"
  } >>"$info"
  aab_owner="$(printf '%s\n' "$aab_certs" | grep -m 1 '^Owner:' | sed 's/^Owner: //' || true)"
  [ -n "$aab_owner" ] || j3_die "The App Bundle is not signed."
  if printf '%s' "$aab_owner" | grep -q "$J3_ANDROID_DEBUG_CERT_DN"; then
    j3_die "The App Bundle is signed with the Android DEBUG certificate."
  fi
  j3_write_sha256 "$aab" >/dev/null
  summary_rows+=("$aab|release-signed ($aab_owner)")
fi

j3_update_sha256sums "$out_dir"
{
  echo
  echo "## SHA-256"
  cat "$out_dir/SHA256SUMS"
} >>"$info"

j3_info "Artifacts in $out_dir:"
ls -l "$out_dir"
echo "$(basename "$apk") SHA-256: $apk_hash"
j3_summary_table "Android ($mode)" "${summary_rows[@]}"
