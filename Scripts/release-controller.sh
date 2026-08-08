#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
export DEVELOPER_DIR="${OASIS_DEVELOPER_DIR:-/Applications/Xcode-26.6.app/Contents/Developer}"
updates_dir="${OASIS_UPDATES_DIR:-$project_root/Dist/updates}"
notary_dir="${OASIS_NOTARY_DIR:-$project_root/Dist/notarization}"
sparkle_account="${OASIS_SPARKLE_ACCOUNT:-oasis-lights}"
notary_key="${OASIS_NOTARY_KEY:-$HOME/.appstoreconnect/private_keys/AuthKey_XQ4565NYZ7.p8}"
notary_key_id="${OASIS_NOTARY_KEY_ID:-XQ4565NYZ7}"
notary_issuer="${OASIS_NOTARY_ISSUER:-60b8eb46-ca64-4580-a43b-850d92fcc7ab}"

"$project_root/Scripts/build-apps.sh"

app="$project_root/Build/Applications/Oasis Lights.app"
info="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")
download_base_url="${OASIS_UPDATE_DOWNLOAD_BASE_URL:-https://github.com/malpern/oasis-lights-mac/releases/download/v$version}"
archive_name="Oasis-Lights-$version.zip"
archive="$updates_dir/$archive_name"
work_dir=$(mktemp -d /tmp/oasis-controller-release.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$updates_dir"
mkdir -p "$notary_dir"

authority=$(codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)
team=$(codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [[ "$authority" != 'Developer ID Application: Micah Alpern (X2RKZ5TG99)' || "$team" != 'X2RKZ5TG99' ]]; then
  echo "Oasis Lights is not signed with the expected Developer ID identity" >&2
  exit 1
fi

notary_archive="$work_dir/Oasis-Lights-notarization.zip"
ditto -c -k --keepParent "$app" "$notary_archive"

if [[ "${OASIS_SKIP_NOTARIZE:-0}" != "1" ]]; then
  if [[ ! -f "$notary_key" ]]; then
    echo "Notary API key is unavailable at $notary_key" >&2
    exit 1
  fi
  notary_result="$notary_dir/notarization-$version-$build.json"
  xcrun notarytool submit "$notary_archive" \
    --key "$notary_key" \
    --key-id "$notary_key_id" \
    --issuer "$notary_issuer" \
    --wait \
    --output-format json > "$notary_result"
  notary_status=$(plutil -extract status raw "$notary_result")
  if [[ "$notary_status" != "Accepted" ]]; then
    echo "Apple notarization did not accept Oasis Lights: $notary_status" >&2
    exit 1
  fi
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
else
  echo "Warning: producing a local update archive without notarization" >&2
fi

ditto -c -k --keepParent "$app" "$archive"

generate_appcast="$project_root/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
sign_update="$project_root/.build/artifacts/sparkle/Sparkle/bin/sign_update"
"$generate_appcast" \
  --account "$sparkle_account" \
  --download-url-prefix "$download_base_url/" \
  --maximum-versions 5 \
  "$updates_dir"
"$sign_update" --account "$sparkle_account" --verify "$updates_dir/appcast.xml"

codesign --verify --deep --strict "$app"
if [[ "${OASIS_SKIP_NOTARIZE:-0}" != "1" ]]; then
  spctl --assess --type execute --verbose=4 "$app"
fi

echo "Prepared Oasis Lights $version ($build) update artifacts:"
echo "  $archive"
echo "  $updates_dir/appcast.xml"
echo "Nothing was published. Publish the contents of $updates_dir only after explicit approval."
