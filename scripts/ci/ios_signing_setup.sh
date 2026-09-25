#!/usr/bin/env bash
# CI only (GitHub macOS runner): puts the iOS signing certificate into a
# temporary keychain and decodes the provisioning profile.
#
# Environment (from repository secrets; never printed):
#   IOS_CERTIFICATE_P12_BASE64       base64 of the .p12 (certificate + key)
#   IOS_CERTIFICATE_PASSWORD         password of the .p12
#   IOS_PROVISIONING_PROFILE_BASE64  base64 of the .mobileprovision
#   IOS_KEYCHAIN_PASSWORD            optional; random when empty
#
# Appends to $GITHUB_ENV: J3_IOS_KEYCHAIN_PATH, J3_IOS_PROFILE_PATH.
# Always pair with scripts/ci/ios_signing_cleanup.sh in an `if: always()` step.
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

[ "$(uname -s)" = "Darwin" ] || j3_die "This script must run on macOS."
tmp="${RUNNER_TEMP:?RUNNER_TEMP is not set (this script is meant for GitHub Actions)}"
: "${IOS_CERTIFICATE_P12_BASE64:?IOS_CERTIFICATE_P12_BASE64 is empty}"
: "${IOS_CERTIFICATE_PASSWORD:?IOS_CERTIFICATE_PASSWORD is empty}"
: "${IOS_PROVISIONING_PROFILE_BASE64:?IOS_PROVISIONING_PROFILE_BASE64 is empty}"

keychain="$tmp/j3-signing.keychain-db"
cert="$tmp/j3-signing-cert.p12"
profile="$tmp/j3-profile.mobileprovision"

keychain_password="${IOS_KEYCHAIN_PASSWORD:-}"
if [ -z "$keychain_password" ]; then
  keychain_password="$(openssl rand -hex 24)"
fi
echo "::add-mask::$keychain_password"

decode_base64() {
  # Tolerates line breaks/CRs from copy-pasted secrets.
  printf '%s' "$1" | tr -d ' \r\n\t' | base64 --decode >"$2" ||
    j3_die "Could not base64-decode the secret for $(basename "$2")."
  [ -s "$2" ] || j3_die "Decoded $(basename "$2") is empty."
}
decode_base64 "$IOS_CERTIFICATE_P12_BASE64" "$cert"
decode_base64 "$IOS_PROVISIONING_PROFILE_BASE64" "$profile"
security cms -D -i "$profile" >/dev/null 2>&1 ||
  j3_die "IOS_PROVISIONING_PROFILE_BASE64 does not contain a valid .mobileprovision file."

j3_info "Creating temporary keychain"
security delete-keychain "$keychain" >/dev/null 2>&1 || true
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"

j3_info "Importing the signing certificate"
if ! security import "$cert" -P "$IOS_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$keychain"; then
  j3_die "Importing the .p12 failed - check IOS_CERTIFICATE_PASSWORD and that the .p12 contains the private key."
fi
rm -f "$cert"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null

# Put the temporary keychain first in the user search list, keeping the others.
search_list=("$keychain")
while IFS= read -r line; do
  line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
  if [ -n "$line" ] && [ "$line" != "$keychain" ]; then
    search_list+=("$line")
  fi
done < <(security list-keychains -d user)
security list-keychains -d user -s "${search_list[@]}"

identities="$(security find-identity -v -p codesigning "$keychain")"
printf '%s\n' "$identities"
if printf '%s' "$identities" | grep -q '0 valid identities found'; then
  j3_die "The .p12 did not provide a valid code signing identity (certificate expired, revoked or missing its key?)."
fi

{
  echo "J3_IOS_KEYCHAIN_PATH=$keychain"
  echo "J3_IOS_PROFILE_PATH=$profile"
} >>"${GITHUB_ENV:?GITHUB_ENV is not set}"
j3_info "Signing keychain ready."
