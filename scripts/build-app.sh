#!/bin/bash
# Build "iCloud Video Resize.app" into the build/ folder.
# The app must run from this bundle: macOS gives access to Photos only to
# an app with an Info.plist that explains why it needs it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/VideoResizeApp"

APP="build/iCloud Video Resize.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/VideoResizeApp"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Sign for this Mac only (no Apple developer account needed).
codesign --force --sign - "$APP"

echo "Built: $APP"
echo "Run it with: open \"$APP\""
