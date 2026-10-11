#!/usr/bin/env bash
# Build MotionForge.ipa on a Mac with Xcode 15+.
#
#   ./scripts/build_ipa.sh                      -> unsigned .ipa (re-sign it with your own tool/certificate)
#   TEAM_ID=ABCDE12345 ./scripts/build_ipa.sh   -> signed .ipa (method: development by default)
#   TEAM_ID=ABCDE12345 EXPORT_METHOD=ad-hoc ./scripts/build_ipa.sh
#   TEAM_ID=ABCDE12345 EXPORT_METHOD=app-store-connect ./scripts/build_ipa.sh   (upload with Transporter)
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodebuild >/dev/null || { echo "Xcode is required (macOS only)."; exit 1; }
if ! command -v xcodegen >/dev/null; then
  echo "Installing XcodeGen with Homebrew…"; brew install xcodegen
fi
xcodegen generate
rm -rf build && mkdir -p build

if [[ -z "${TEAM_ID:-}" ]]; then
  echo "== Unsigned build =="
  xcodebuild -project MotionForge.xcodeproj -scheme MotionForge -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/dd \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
  APP=$(find build/dd/Build/Products -maxdepth 2 -name "MotionForge.app" | head -n 1)
  mkdir -p build/Payload && cp -R "$APP" build/Payload/
  (cd build && zip -qr MotionForge-unsigned.ipa Payload)
  echo "Done: build/MotionForge-unsigned.ipa"
else
  METHOD="${EXPORT_METHOD:-development}"
  echo "== Signed build (team $TEAM_ID, method $METHOD) =="
  cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>${METHOD}</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>stripSwiftSymbols</key><true/>
</dict></plist>
PLIST
  xcodebuild -project MotionForge.xcodeproj -scheme MotionForge -configuration Release \
    -destination 'generic/platform=iOS' -archivePath build/MotionForge.xcarchive \
    DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates archive
  xcodebuild -exportArchive -archivePath build/MotionForge.xcarchive \
    -exportPath build/export -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates
  echo "Done: $(ls build/export/*.ipa)"
fi
