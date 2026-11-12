#!/bin/bash
# Build "iCloud Video Resize.app" into the build/ folder.
# The app must run from this bundle: macOS gives access to Photos only to
# an app with an Info.plist that explains why it needs it.
#
#   DEVELOPMENT_TEAM=ABCDE12345 ./scripts/build-app.sh
#       Signed with your Apple developer team: shares its records with the
#       iPad/iPhone app through iCloud.
#   ./scripts/build-app.sh
#       Signed for this Mac only, no developer account needed, no iCloud.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/iCloud Video Resize.app"

if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    xcodebuild -project Mac/iCloudVideoResize.xcodeproj -scheme iCloudVideoResize \
        -configuration Release -derivedDataPath build/DerivedData \
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" -allowProvisioningUpdates -quiet build
    rm -rf "$APP"
    cp -R build/DerivedData/Build/Products/Release/VideoResizeApp.app "$APP"
else
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/VideoResizeApp"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$BIN" "$APP/Contents/MacOS/VideoResizeApp"
    cp Resources/Info.plist "$APP/Contents/Info.plist"
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    codesign --force --sign - "$APP"
fi

echo "Built: $APP"
echo "Run it with: open \"$APP\""
