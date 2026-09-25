#!/usr/bin/env bash
# CI only: removes everything scripts/ci/ios_signing_setup.sh and
# scripts/build_ios.sh --signed put on the runner (temporary keychain, decoded
# certificate/profile, installed provisioning profile). Best effort: never
# fails, so it is safe in an `if: always()` step.
set -uo pipefail

tmp="${RUNNER_TEMP:-/tmp}"
keychain="${J3_IOS_KEYCHAIN_PATH:-$tmp/j3-signing.keychain-db}"
profile="${J3_IOS_PROFILE_PATH:-$tmp/j3-profile.mobileprovision}"
uuid="${J3_IOS_PROFILE_UUID:-}"

if [ -z "$uuid" ] && [ -f "$profile" ]; then
  plist="$(mktemp)"
  if security cms -D -i "$profile" -o "$plist" >/dev/null 2>&1; then
    uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$plist" 2>/dev/null || true)"
  fi
  rm -f "$plist"
fi

if [ -n "$uuid" ]; then
  for dir in "$HOME/Library/MobileDevice/Provisioning Profiles" \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
    if [ -f "$dir/$uuid.mobileprovision" ]; then
      rm -f "$dir/$uuid.mobileprovision" && echo "Removed provisioning profile $dir/$uuid.mobileprovision"
    fi
  done
fi

if [ -f "$keychain" ]; then
  security delete-keychain "$keychain" && echo "Deleted keychain $keychain"
fi

rm -f "$profile" "$tmp/j3-signing-cert.p12"
echo "iOS signing cleanup done."
exit 0
