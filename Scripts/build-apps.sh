#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
export DEVELOPER_DIR="${OASIS_DEVELOPER_DIR:-/Applications/Xcode-26.6.app/Contents/Developer}"
signing_identity="${OASIS_SIGNING_IDENTITY:-Developer ID Application: Micah Alpern (X2RKZ5TG99)}"
build_root="$project_root/Build"
applications_root="$build_root/Applications"
bridge_app="$applications_root/Oasis Bridge.app"
controller_app="$applications_root/Oasis Lights.app"
sparkle_framework="$project_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Stable Xcode is unavailable at $DEVELOPER_DIR" >&2
  exit 1
fi

if [[ ! -d "$sparkle_framework" ]]; then
  (cd "$project_root" && swift package resolve)
fi
if [[ ! -f "$sparkle_framework/Versions/B/Sparkle" ]]; then
  echo "Sparkle.framework 2.9.4 was not resolved correctly" >&2
  exit 1
fi

rm -rf "$build_root"
mkdir -p \
  "$bridge_app/Contents/MacOS" "$bridge_app/Contents/Resources" \
  "$controller_app/Contents/MacOS" "$controller_app/Contents/Resources" \
  "$controller_app/Contents/Frameworks"

make_icns() {
  local source_image="$1"
  local destination="$2"
  local iconset="$build_root/$(basename "$destination" .icns).iconset"
  mkdir -p "$iconset"
  sips -z 16 16 "$source_image" --out "$iconset/icon_16x16.png" >/dev/null
  sips -z 32 32 "$source_image" --out "$iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$source_image" --out "$iconset/icon_32x32.png" >/dev/null
  sips -z 64 64 "$source_image" --out "$iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$source_image" --out "$iconset/icon_128x128.png" >/dev/null
  sips -z 256 256 "$source_image" --out "$iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$source_image" --out "$iconset/icon_256x256.png" >/dev/null
  sips -z 512 512 "$source_image" --out "$iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$source_image" --out "$iconset/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$source_image" --out "$iconset/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$iconset" -o "$destination"
}

make_icns \
  "$project_root/Assets/Generated/oasis-bridge-icon-master.png" \
  "$bridge_app/Contents/Resources/AppIcon.icns"
make_icns \
  "$project_root/Assets/Generated/oasis-lights-icon-master.png" \
  "$controller_app/Contents/Resources/AppIcon.icns"
cp "$project_root/Assets/Generated/oasis-bridge-about-wide.png" \
  "$bridge_app/Contents/Resources/OasisBridgeAbout.png"
cp "$project_root/Assets/Generated/oasis-lights-about.png" \
  "$controller_app/Contents/Resources/OasisLightsAbout.png"

xcrun swiftc \
  -O \
  -target arm64-apple-macos15.0 \
  "$project_root/Sources/OasisBridge/OasisBridge.swift" \
  -o "$bridge_app/Contents/MacOS/OasisBridge" \
  -framework AppKit \
  -framework CoreBluetooth \
  -framework Network \
  -framework Foundation

xcrun swiftc \
  -parse-as-library \
  -O \
  -target arm64-apple-macos15.0 \
  "$project_root"/Sources/OasisController/*.swift \
  -o "$controller_app/Contents/MacOS/OasisController" \
  -F "${sparkle_framework:h}" \
  -framework Sparkle \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  -framework SwiftUI \
  -framework AppKit \
  -framework Foundation

ditto "$sparkle_framework" "$controller_app/Contents/Frameworks/Sparkle.framework"

cp "$project_root/Scripts/Bridge-Info.plist" "$bridge_app/Contents/Info.plist"
cp "$project_root/Scripts/Controller-Info.plist" "$controller_app/Contents/Info.plist"

sign_arguments=(--force --options runtime --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
  sign_arguments+=(--timestamp)
fi

codesign "${sign_arguments[@]}" --deep "$controller_app/Contents/Frameworks/Sparkle.framework"
codesign "${sign_arguments[@]}" "$bridge_app"
codesign "${sign_arguments[@]}" "$controller_app"

"$bridge_app/Contents/MacOS/OasisBridge" --crypto-self-test
codesign --verify --deep --strict "$bridge_app"
codesign --verify --deep --strict "$controller_app"
plutil -lint "$bridge_app/Contents/Info.plist" "$controller_app/Contents/Info.plist"
otool -L "$controller_app/Contents/MacOS/OasisController" | grep -q '@rpath/Sparkle.framework'
otool -l "$controller_app/Contents/MacOS/OasisController" | grep -q '@executable_path/../Frameworks'

echo "$applications_root"
