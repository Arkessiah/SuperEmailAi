#!/bin/sh
# Builds the .app and puts it in /Applications, so it shows up in Launchpad and Spotlight like any
# other app. Run it again after any change: otherwise the copy in /Applications stays old while the
# repo moves on, which is the easiest way to test yesterday's bug.
#
# Everything stays on this Mac: no signing service, no store, no upload.
set -e
cd "$(dirname "$0")/.."

BUNDLE_ID="com.obsidiaan.superemailai"
APP_NAME="SuperEmail"
DEST="/Applications/$APP_NAME.app"
# Where earlier names installed it.
OLD_DESTS="/Applications/SuperEmailAi.app:/Applications/Super Email Organizer.app"

if [ ! -w /Applications ]; then
    echo "No puedo escribir en /Applications. Ejecuta: sudo bash scripts/install-app.sh"
    exit 1
fi

bash scripts/build-app.sh

# Never delete something that only happens to share the name.
is_ours() {
    [ "$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || echo "?")" = "$BUNDLE_ID" ]
}
if [ -d "$DEST" ] && ! is_ours "$DEST"; then
    echo "En $DEST hay otra app distinta. No la toco: quítala tú si quieres seguir."
    exit 1
fi

# Copying over a running app leaves it half replaced, and the open window keeps using the old code.
# The executable keeps its internal name, so the process is still SuperEmailAi.
if pgrep -x SuperEmailAi >/dev/null 2>&1; then
    echo "Cerrando la copia que está abierta…"
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || killall SuperEmailAi >/dev/null 2>&1 || true
    sleep 1
fi

# Two copies with the same bundle id confuse Launchpad and the Automation permission.
OLD_IFS=$IFS; IFS=:
for OLD in $OLD_DESTS; do
    if [ -d "$OLD" ] && is_ours "$OLD"; then
        rm -rf "$OLD"
        echo "Quitada la copia con un nombre anterior ($OLD)"
    fi
done
IFS=$OLD_IFS

rm -rf "$DEST"
cp -R "build/$APP_NAME.app" "$DEST"
echo "Instalada en $DEST"
echo "Ábrela desde Launchpad o con: open -a \"$APP_NAME\""
