#!/usr/bin/env bash
# Writes an ExportOptions.plist for `flutter build ipa --export-options-plist`.
#
#   scripts/ci/make_export_options.sh --method ad-hoc --team-id ABCDE12345 \
#     --bundle-id com.j3nsontop.multitool --profile-name "J3 Ad Hoc" \
#     --output build/ExportOptions.plist
#
# --method maps to the Xcode 15.4+ export method names:
#   development -> debugging          (signingCertificate "Apple Development")
#   ad-hoc      -> release-testing    (signingCertificate "Apple Distribution")
#   app-store   -> app-store-connect  (signingCertificate "Apple Distribution")
#   enterprise  -> enterprise         (signingCertificate "Apple Distribution")
# Signing is always manual: exactly the given team and provisioning profile.
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

method=""
team_id=""
bundle_id=""
profile_name=""
output=""
while [ $# -gt 0 ]; do
  case "$1" in
    --method) method="${2:-}"; shift 2 ;;
    --team-id) team_id="${2:-}"; shift 2 ;;
    --bundle-id) bundle_id="${2:-}"; shift 2 ;;
    --profile-name) profile_name="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[ -n "$method" ] || die "--method is required"
[ -n "$team_id" ] || die "--team-id is required"
[ -n "$bundle_id" ] || die "--bundle-id is required"
[ -n "$profile_name" ] || die "--profile-name is required"
[ -n "$output" ] || die "--output is required"
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || die "Team ID must be 10 upper-case letters/digits (got '$team_id')"

case "$method" in
  development) xcode_method="debugging"; certificate="Apple Development" ;;
  ad-hoc) xcode_method="release-testing"; certificate="Apple Distribution" ;;
  app-store) xcode_method="app-store-connect"; certificate="Apple Distribution" ;;
  enterprise) xcode_method="enterprise"; certificate="Apple Distribution" ;;
  *) die "--method must be development, ad-hoc, app-store or enterprise (got '$method')" ;;
esac

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

if [ "$xcode_method" = "app-store-connect" ]; then
  # Export only (upload is a separate, manual step); never let Xcode rewrite
  # the version/build numbers that come from pubspec.yaml.
  method_specific=$'\t<key>destination</key>\n\t<string>export</string>\n\t<key>manageAppVersionAndBuildNumber</key>\n\t<false/>\n\t<key>uploadSymbols</key>\n\t<true/>'
else
  method_specific=$'\t<key>thinning</key>\n\t<string>&lt;none&gt;</string>'
fi

mkdir -p "$(dirname "$output")"
cat >"$output" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>$xcode_method</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>teamID</key>
	<string>$(xml_escape "$team_id")</string>
	<key>signingCertificate</key>
	<string>$certificate</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>$(xml_escape "$bundle_id")</key>
		<string>$(xml_escape "$profile_name")</string>
	</dict>
	<key>stripSwiftSymbols</key>
	<true/>
	<key>compileBitcode</key>
	<false/>
$method_specific
</dict>
</plist>
EOF

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$output" >/dev/null || die "Generated plist is invalid: $output"
elif command -v python3 >/dev/null 2>&1; then
  python3 -c 'import plistlib, sys; plistlib.load(open(sys.argv[1], "rb"))' "$output" ||
    die "Generated plist is invalid: $output"
fi
printf 'Wrote %s (method=%s, profile=%s)\n' "$output" "$xcode_method" "$profile_name"
