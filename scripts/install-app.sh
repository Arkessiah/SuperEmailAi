#!/bin/sh
# Builds the .app and puts it in /Applications, so it shows up in Launchpad and Spotlight like any
# other app. Run it again after any change: otherwise the copy in /Applications stays old while the
# repo moves on, which is the easiest way to test yesterday's bug.
#
# Everything stays on this Mac: no signing service, no store, no upload.
set -e
cd "$(dirname "$0")/.."

BUNDLE_ID="com.obsidiaan.superemailai"
DEST="/Applications/SuperEmailAi.app"

if [ ! -w /Applications ]; then
    echo "No puedo escribir en /Applications. Ejecuta: sudo bash scripts/install-app.sh"
    exit 1
fi

bash scripts/build-app.sh

# Never delete something that only happens to share the name.
if [ -d "$DEST" ]; then
    EXISTING=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$DEST/Contents/Info.plist" 2>/dev/null || echo "?")
    if [ "$EXISTING" != "$BUNDLE_ID" ]; then
        echo "En $DEST hay otra app distinta ($EXISTING). No la toco: quítala tú si quieres seguir."
        exit 1
    fi
fi

# Copying over a running app leaves it half replaced, and the open window keeps using the old code.
if pgrep -x SuperEmailAi >/dev/null 2>&1; then
    echo "Cerrando la copia que está abierta…"
    osascript -e 'quit app "SuperEmailAi"' >/dev/null 2>&1 || killall SuperEmailAi >/dev/null 2>&1 || true
    sleep 1
fi

rm -rf "$DEST"
cp -R build/SuperEmailAi.app "$DEST"
echo "Instalada en $DEST"
echo "Ábrela desde Launchpad o con: open -a SuperEmailAi"
