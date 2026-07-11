#!/usr/bin/env bash
#
# Archive the app and upload it to TestFlight / App Store Connect.
#
# Prereqs (one-time):
#   - Apple Developer membership with the current Program License Agreement
#     accepted at https://developer.apple.com/account. An unaccepted update
#     blocks uploads with "PLA Update available" and shows a misleading
#     "No signing certificate iOS Distribution found" as a side effect.
#   - A signed-in Xcode account for the team (Xcode > Settings > Accounts).
#   - An App Store Connect app record for com.w2asm.AmateurRadioLog, with
#     the platform being uploaded enabled on that record.
#
# Usage: tools/upload-testflight.sh [ios|macos]   (default: ios)
#
set -euo pipefail

PLATFORM="${1:-ios}"
case "$PLATFORM" in
  ios)   DESTINATION='generic/platform=iOS' ;;
  macos) DESTINATION='generic/platform=macOS' ;;
  *) echo "usage: $0 [ios|macos]" >&2; exit 2 ;;
esac

TEAM_ID="7Q2SS8772K"
SCHEME="AmateurRadioLog"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/AmateurRadioLog"
PROJECT="$PROJECT_DIR/AmateurRadioLog.xcodeproj"

BUILD="$(date +%Y%m%d%H%M)"
WORK="$(mktemp -d /tmp/AmateurRadioLog-testflight.XXXXXX)"
ARCHIVE="$WORK/AmateurRadioLog-$BUILD.xcarchive"
EXPORT_DIR="$WORK/upload-$BUILD"
EXPORT_OPTS="$WORK/ExportOptions.plist"

echo "==> Platform:     $PLATFORM"
echo "==> Build number: $BUILD"
echo "==> Work dir:     $WORK"

# The Xcode project is generated from project.yml — regenerate it first.
echo "==> Regenerating Xcode project (xcodegen)"
( cd "$PROJECT_DIR" && xcodegen generate )

cat > "$EXPORT_OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
PLIST

echo "==> Archiving (Release, build $BUILD)"
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  -allowProvisioningUpdates -quiet

echo "==> Exporting + uploading to App Store Connect"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -allowProvisioningUpdates

echo ""
echo "==> Done. $PLATFORM build $BUILD uploaded."
echo "    Apple processes it in ~5-15 min, then it appears in"
echo "    App Store Connect > TestFlight."
