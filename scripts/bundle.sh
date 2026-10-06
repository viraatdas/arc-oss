#!/bin/bash
# Builds Radian and wraps it in build/Radian.app.
#
#   scripts/bundle.sh            release build
#   scripts/bundle.sh debug      debug build
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Radian.app"

swift build -c "$CONFIG" --product Radian
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Radian"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Radian"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough to run locally. Distributing builds needs a Developer ID and notarization.
codesign --force --sign - "$APP"
echo "Built $APP"
