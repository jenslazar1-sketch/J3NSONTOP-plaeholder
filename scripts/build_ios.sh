#!/usr/bin/env bash
# Builds the iOS app on macOS (Xcode required).
#
# Unsigned compile check (default; no Apple account needed):
#   scripts/build_ios.sh
#   -> dist/J3NSONTOP-Multitool-<ver>-ios-UNSIGNED-compile-check.zip
#      Runner.app + README.txt. NOT installable on any device.
#
# Signed IPA (same logic as .github/workflows/release.yml):
#   scripts/build_ios.sh --signed --export-method ad-hoc \
#     --team-id ABCDE12345 --profile ~/Downloads/J3_AdHoc.mobileprovision
#   -> dist/J3NSONTOP-Multitool-<ver>-ios-<method>.ipa
#   The matching certificate + private key ("Apple Distribution", or "Apple
#   Development" for --export-method development) must be in a keychain on
#   the search list (locally: your login keychain).
#
# Options:
#   --unsigned | --signed
#   --export-method development|ad-hoc|app-store|enterprise   (signed)
#   --team-id ID          Apple Developer Team ID (default: $IOS_TEAM_ID)
#   --profile PATH        .mobileprovision for com.j3nsontop.multitool
#   --out-dir DIR         output directory (default: dist)
#   --skip-build          package/verify existing build output only
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

mode="unsigned"
export_method=""
team_id="${IOS_TEAM_ID:-}"
profile=""
out_dir="$J3_REPO_ROOT/dist"
skip_build="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --unsigned) mode="unsigned"; shift ;;
    --signed) mode="signed"; shift ;;
    --export-method) export_method="${2:-}"; shift 2 ;;
    --team-id) team_id="${2:-}"; shift 2 ;;
    --profile) profile="${2:-}"; shift 2 ;;
    --out-dir) out_dir="${2:-}"; shift 2 ;;
    --skip-build) skip_build="yes"; shift ;;
    -h | --help) sed -n '2,25p' "$0"; exit 0 ;;
    *) j3_die "Unknown option: $1 (see --help)" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || j3_die "iOS builds require macOS with Xcode."
j3_require_cmd flutter xcodebuild /usr/libexec/PlistBuddy
j3_read_version
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
cd "$J3_REPO_ROOT"
xcodebuild -version

work="$(mktemp -d)"
pbxproj="$J3_REPO_ROOT/ios/Runner.xcodeproj/project.pbxproj"
cleanup() {
  # Signed builds temporarily switch the project to manual signing; restore it.
  if [ -f "$work/project.pbxproj.orig" ]; then
    cp "$work/project.pbxproj.orig" "$pbxproj"
  fi
  rm -rf "$work"
}
trap cleanup EXIT

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

check_app_info_plist() {
  local info="$1/Info.plist" value
  value="$(plist_get "$info" CFBundleIdentifier || true)"
  [ "$value" = "$J3_APP_ID" ] || j3_die "CFBundleIdentifier is '$value' (expected $J3_APP_ID)"
  value="$(plist_get "$info" CFBundleShortVersionString || true)"
  [ "$value" = "$J3_VERSION" ] || j3_die "CFBundleShortVersionString is '$value' (expected $J3_VERSION)"
  value="$(plist_get "$info" CFBundleVersion || true)"
  [ "$value" = "$J3_BUILD_NUMBER" ] || j3_die "CFBundleVersion is '$value' (expected $J3_BUILD_NUMBER)"
  j3_info "Info.plist OK: $J3_APP_ID $J3_VERSION ($J3_BUILD_NUMBER)"
}

# ------------------------------------------------------------------------------
# Unsigned compile check
# ------------------------------------------------------------------------------
if [ "$mode" = "unsigned" ]; then
  if [ "$skip_build" = "no" ]; then
    j3_info "flutter build ios --release --no-codesign $(j3_build_label_define)"
    flutter build ios --release --no-codesign "$(j3_build_label_define)"
  fi
  app="$J3_REPO_ROOT/build/ios/iphoneos/Runner.app"
  [ -d "$app" ] || j3_die "Runner.app not found: $app"
  check_app_info_plist "$app"

  name="$J3_ARTIFACT_PREFIX-$J3_VERSION-ios-UNSIGNED-compile-check"
  stage="$work/$name"
  mkdir -p "$stage"
  ditto "$app" "$stage/Runner.app"
  cat >"$stage/README.txt" <<EOF
J3NSONTOP BIGGEST MULTITOOL MADE - iOS $J3_VERSION_FULL

THIS IS NOT AN INSTALLABLE APP.

Runner.app in this archive was built with "flutter build ios --release
--no-codesign". It is UNSIGNED and exists only to prove that the iOS project
compiles. iPhones and iPads refuse to install unsigned apps, and it cannot be
sideloaded or uploaded to TestFlight/App Store.

To get an installable build, run the "Release" workflow with
build_type=release and an iOS export method (see docs/SIGNING.md):
  - development or ad-hoc: installable on devices whose UDIDs are registered
    in the provisioning profile
  - app-store: for TestFlight / App Store distribution only
EOF
  zip_path="$out_dir/$name.zip"
  rm -f "$zip_path" "$zip_path.sha256"
  (cd "$work" && ditto -c -k --sequesterRsrc --keepParent "$name" "$zip_path")
  j3_write_sha256 "$zip_path" >/dev/null
  j3_update_sha256sums "$out_dir"
  j3_info "Created $zip_path"
  j3_summary_table "iOS (unsigned compile check)" \
    "$zip_path|UNSIGNED - compile check only, NOT installable (no IPA produced)"
  exit 0
fi

# ------------------------------------------------------------------------------
# Signed IPA
# ------------------------------------------------------------------------------
case "$export_method" in
  development) identity_type="Apple Development"; identity_prefixes="Apple Development,iPhone Developer" ;;
  ad-hoc | app-store | enterprise) identity_type="Apple Distribution"; identity_prefixes="Apple Distribution,iPhone Distribution" ;;
  "") j3_die "--export-method is required for --signed" ;;
  *) j3_die "--export-method must be development, ad-hoc, app-store or enterprise (got '$export_method')" ;;
esac
[ -n "$team_id" ] || j3_die "--team-id (or IOS_TEAM_ID) is required for --signed"
if [ -z "$profile" ] || [ ! -f "$profile" ]; then
  j3_die "--profile must point to a .mobileprovision file (got '$profile')"
fi
j3_require_cmd security codesign ruby python3 unzip

# --- Inspect the provisioning profile ----------------------------------------------
profile_plist="$work/profile.plist"
security cms -D -i "$profile" -o "$profile_plist" || j3_die "Cannot decode provisioning profile $profile"
profile_uuid="$(plist_get "$profile_plist" UUID || true)"
profile_name="$(plist_get "$profile_plist" Name || true)"
profile_team="$(plist_get "$profile_plist" TeamIdentifier:0 || true)"
profile_app_id="$(plist_get "$profile_plist" Entitlements:application-identifier || true)"
get_task_allow="$(plist_get "$profile_plist" Entitlements:get-task-allow || echo false)"
provisions_all="$(plist_get "$profile_plist" ProvisionsAllDevices || echo false)"
if plist_get "$profile_plist" ProvisionedDevices:0 >/dev/null; then has_devices="yes"; else has_devices="no"; fi
j3_info "Profile: '$profile_name' ($profile_uuid) team=$profile_team app-id=$profile_app_id devices=$has_devices get-task-allow=$get_task_allow"

if [ -z "$profile_uuid" ] || [ -z "$profile_name" ]; then
  j3_die "The provisioning profile has no UUID/Name."
fi
if [ "$profile_team" != "$team_id" ]; then
  j3_die "Provisioning profile team '$profile_team' does not match the team ID '$team_id'."
fi
profile_bundle="${profile_app_id#*.}"
if [ "$profile_bundle" != "$J3_APP_ID" ]; then
  # Wildcard App IDs (e.g. "*" or "com.j3nsontop.*") are accepted with a warning.
  # shellcheck disable=SC2254 # glob match is intended
  case "$J3_APP_ID" in
    $profile_bundle) j3_warn "Wildcard provisioning profile '$profile_app_id' is used for $J3_APP_ID." ;;
    *) j3_die "Provisioning profile is for '$profile_bundle', not '$J3_APP_ID'." ;;
  esac
fi

profile_kind_ok="no"
case "$export_method" in
  development)
    if [ "$get_task_allow" = "true" ] && [ "$has_devices" = "yes" ]; then profile_kind_ok="yes"; fi
    kind_hint="an iOS App Development profile" ;;
  ad-hoc)
    if [ "$get_task_allow" != "true" ] && [ "$has_devices" = "yes" ]; then profile_kind_ok="yes"; fi
    kind_hint="an Ad Hoc distribution profile with registered devices" ;;
  app-store)
    if [ "$has_devices" = "no" ] && [ "$provisions_all" != "true" ]; then profile_kind_ok="yes"; fi
    kind_hint="an App Store Connect distribution profile" ;;
  enterprise)
    if [ "$provisions_all" = "true" ]; then profile_kind_ok="yes"; fi
    kind_hint="an In-House (enterprise) distribution profile" ;;
esac
if [ "$profile_kind_ok" != "yes" ]; then
  j3_die "Export method '$export_method' needs $kind_hint; '$profile_name' is a different kind of profile."
fi

# The profile must not be expired and must contain a certificate whose private
# key is available in the keychain search list.
security find-identity -v -p codesigning >"$work/identities.txt" || true
# (Written to a file first: bash 3.2 mis-parses heredocs inside $(...).)
cat >"$work/check_identity.py" <<'PY'
import datetime, hashlib, plistlib, re, sys

profile = plistlib.load(open(sys.argv[1], "rb"))
identities = open(sys.argv[2], encoding="utf-8", errors="replace").read()
prefixes = tuple(sys.argv[3].split(","))

expires = profile.get("ExpirationDate")
if isinstance(expires, datetime.datetime):
    if expires.tzinfo is not None:
        expires = expires.astimezone(datetime.timezone.utc).replace(tzinfo=None)
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    if expires < now:
        sys.exit("ERROR: the provisioning profile expired on %s." % expires.date())
    print("Profile expires %s (%d days left)" % (expires.date(), (expires - now).days), file=sys.stderr)

in_profile = {hashlib.sha1(c).hexdigest().upper() for c in profile.get("DeveloperCertificates", [])}
matches = []
for sha1, name in re.findall(r'\)\s+([0-9A-F]{40})\s+"([^"]+)"', identities):
    if sha1 in in_profile and name.startswith(prefixes):
        matches.append(name)
if not matches:
    sys.exit("ERROR: no valid %s identity in the keychain matches a certificate in the "
             "provisioning profile. Import the matching .p12 (certificate + private key)." % " / ".join(prefixes))
print(matches[0])
PY
identity="$(python3 "$work/check_identity.py" "$profile_plist" "$work/identities.txt" "$identity_prefixes")" ||
  j3_die "Signing identity check failed (see above)."
j3_info "Signing identity: $identity"

# --- Install the profile where Xcode looks for it -------------------------------------
for dir in "$HOME/Library/MobileDevice/Provisioning Profiles" \
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
  mkdir -p "$dir"
  cp "$profile" "$dir/$profile_uuid.mobileprovision"
done
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "J3_IOS_PROFILE_UUID=$profile_uuid" >>"$GITHUB_ENV"
fi

# --- Configure manual signing and export options --------------------------------------
cp "$pbxproj" "$work/project.pbxproj.orig"
ruby "$J3_REPO_ROOT/scripts/ci/ios_configure_signing.rb" \
  --project "$J3_REPO_ROOT/ios/Runner.xcodeproj" \
  --team-id "$team_id" \
  --profile-specifier "$profile_name" \
  --identity "$identity_type" \
  --bundle-id "$J3_APP_ID"
export_plist="$work/ExportOptions.plist"
bash "$J3_REPO_ROOT/scripts/ci/make_export_options.sh" \
  --method "$export_method" --team-id "$team_id" --bundle-id "$J3_APP_ID" \
  --profile-name "$profile_name" --output "$export_plist"
cat "$export_plist"

# --- Build -------------------------------------------------------------------------------
if [ "$skip_build" = "no" ]; then
  rm -rf "$J3_REPO_ROOT/build/ios/ipa"
  j3_info "flutter build ipa --release --export-options-plist=$export_plist $(j3_build_label_define)"
  flutter build ipa --release --export-options-plist="$export_plist" "$(j3_build_label_define)"
fi
built_ipa="$(find "$J3_REPO_ROOT/build/ios/ipa" -maxdepth 1 -name '*.ipa' -print 2>/dev/null | head -n 1)"
if [ -z "$built_ipa" ] || [ ! -f "$built_ipa" ]; then
  j3_die "No .ipa was produced in build/ios/ipa."
fi

# --- Verify the IPA ----------------------------------------------------------------------
unzip -q "$built_ipa" -d "$work/ipa"
app="$(find "$work/ipa/Payload" -maxdepth 1 -name '*.app' -print | head -n 1)"
[ -n "$app" ] || j3_die "The IPA has no Payload/*.app."
j3_info "codesign -dv --verbose=4 $(basename "$app")"
codesign -dv --verbose=4 "$app" 2>&1 | tee "$work/codesign.txt"
codesign --verify --deep --strict --verbose=2 "$app" || j3_die "codesign --verify failed for the exported app."
authority="$(grep -m 1 '^Authority=' "$work/codesign.txt" | sed 's/^Authority=//' || true)"
[ -n "$authority" ] || j3_die "The exported app has no signing authority (unsigned?)."
check_app_info_plist "$app"

[ -f "$app/embedded.mobileprovision" ] || j3_die "The IPA has no embedded.mobileprovision."
security cms -D -i "$app/embedded.mobileprovision" -o "$work/embedded.plist"
embedded_uuid="$(plist_get "$work/embedded.plist" UUID || true)"
embedded_app_id="$(plist_get "$work/embedded.plist" Entitlements:application-identifier || true)"
if [ "$embedded_uuid" != "$profile_uuid" ]; then
  j3_die "Embedded profile $embedded_uuid is not the requested profile $profile_uuid."
fi
if [ "$embedded_app_id" != "$profile_app_id" ]; then
  j3_die "Embedded application-identifier '$embedded_app_id' does not match '$profile_app_id'."
fi
j3_info "Embedded profile OK: $profile_name ($embedded_uuid), $embedded_app_id"

ipa="$out_dir/$J3_ARTIFACT_PREFIX-$J3_VERSION-ios-$export_method.ipa"
rm -f "$ipa" "$ipa.sha256"
cp "$built_ipa" "$ipa"
j3_write_sha256 "$ipa" >/dev/null
j3_update_sha256sums "$out_dir"
case "$export_method" in
  development | ad-hoc) install_note="installable on the devices registered in the profile" ;;
  app-store) install_note="for TestFlight/App Store upload; not directly installable" ;;
  enterprise) install_note="In-House distribution" ;;
esac
j3_info "Created $ipa"
j3_summary_table "iOS (signed, $export_method)" \
  "$ipa|signed by $authority; profile '$profile_name'; $install_note"
