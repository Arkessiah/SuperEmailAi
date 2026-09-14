#!/bin/sh
# Builds build/SuperEmailAi.app: release binary, Info.plist, icon and an ad hoc signature.
# Ad hoc signing changes with every build, so macOS may ask again for permission to control Mail.
# The app stays local: never copy it into Dropbox or any synced folder.
set -e
cd "$(dirname "$0")/.."

APP=build/SuperEmailAi.app
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SuperEmailAi" "$APP/Contents/MacOS/"
cp SuperEmailAi/Info.plist "$APP/Contents/Info.plist"
for bundle in "$BIN"/*.bundle; do
    if [ -e "$bundle" ]; then cp -R "$bundle" "$APP/Contents/Resources/"; fi
done

rm -rf build/AppIcon.iconset
swift scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --options runtime --entitlements SuperEmailAi/SuperEmailAi.entitlements "$APP"
codesign --verify --strict "$APP"
echo "Listo: $APP"
