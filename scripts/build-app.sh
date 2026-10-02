#!/bin/sh
# Builds build/SuperEmail.app: release binary, Info.plist, icon and an ad hoc signature.
# The bundle carries the short name that fits under the icon; the full commercial name, Super Email
# Organizer, is the window title. The executable, module and bundle id stay SuperEmailAi.
# Ad hoc signing changes with every build, so macOS may ask again for permission to control Mail.
# The app stays local: never copy it into Dropbox or any synced folder.
set -e
cd "$(dirname "$0")/.."

APP=build/SuperEmail.app
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP" build/SuperEmailAi.app "build/Super Email Organizer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SuperEmailAi" "$APP/Contents/MacOS/"
cp SuperEmailAi/Info.plist "$APP/Contents/Info.plist"
for bundle in "$BIN"/*.bundle; do
    if [ -e "$bundle" ]; then cp -R "$bundle" "$APP/Contents/Resources/"; fi
done

# The icon goes in the layered format when Xcode's actool is around: it compiles AppIcon.icon into
# Assets.car, which macOS 26+ draws with Liquid Glass depth, plus an AppIcon.icns for older systems.
# Without Xcode (the command line tools don't ship actool) it falls back to the flat icns.
ACTOOL="$(xcrun --find actool 2>/dev/null || true)"
if [ -z "$ACTOOL" ] && [ -x /Applications/Xcode.app/Contents/Developer/usr/bin/actool ]; then
    ACTOOL=/Applications/Xcode.app/Contents/Developer/usr/bin/actool
fi
rm -rf build/AppIcon.iconset build/AppIcon.icon
if [ -n "$ACTOOL" ]; then
    swift scripts/make-icon.swift build/AppIcon.icon
    "$ACTOOL" build/AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon \
        --platform macosx --target-device mac --minimum-deployment-target 14.0 \
        --output-partial-info-plist build/AppIcon-partial.plist --output-format human-readable-text >/dev/null
    # actool exits 0 and writes nothing when the .icon's name doesn't match --app-icon.
    if [ ! -f "$APP/Contents/Resources/Assets.car" ] || [ ! -f "$APP/Contents/Resources/AppIcon.icns" ]; then
        echo "actool no generó el icono (Assets.car / AppIcon.icns)." >&2
        exit 1
    fi
else
    echo "Sin actool (hace falta Xcode): icono plano, sin el relieve de macOS 26+."
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - --options runtime --entitlements SuperEmailAi/SuperEmailAi.entitlements "$APP"
codesign --verify --strict "$APP"
echo "Listo: $APP"
