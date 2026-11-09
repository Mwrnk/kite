#!/bin/zsh
# Builds Kite and wraps it in a macOS app bundle at build/Kite.app.
#   scripts/bundle.sh            release build
#   scripts/bundle.sh debug      debug build
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}
swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)

APP=build/Kite.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Kite" "$APP/Contents/MacOS/Kite"
cp -R "$BIN/Kite_Syntax.bundle" "$APP/Contents/Resources/"
cp assets/AppIcon.icns "$APP/Contents/Resources/"   # made from assets/logo.svg by scripts/make-icon.sh

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Kite</string>
    <key>CFBundleDisplayName</key><string>Kite</string>
    <key>CFBundleIdentifier</key><string>com.mwrnk.kite</string>
    <key>CFBundleExecutable</key><string>Kite</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Text</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>NSDocumentClass</key><string>TextDocument</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.text</string>
                <string>public.source-code</string>
                <string>public.data</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
