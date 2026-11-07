#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="NoSleep"
APP_BUNDLE="dist/$APP_NAME.app"
ICON_SRC="nosleepiconn.png"
ICONSET=".build/AppIcon.iconset"

echo "==> Budowanie (release)..."
mkdir -p .build/release
swiftc -parse-as-library -O -o .build/release/$APP_NAME Sources/NoSleep/NoSleepApp.swift -framework AppKit

echo "==> Generowanie ikony aplikacji..."
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Przytnij do kwadratu (źródło: 753x757) w największym rozmiarze
SIZES=(
  "icon_16x16.png 16"
  "icon_16x16@2x.png 32"
  "icon_32x32.png 32"
  "icon_32x32@2x.png 64"
  "icon_128x128.png 128"
  "icon_128x128@2x.png 256"
  "icon_256x256.png 256"
  "icon_256x256@2x.png 512"
  "icon_512x512.png 512"
  "icon_512x512@2x.png 1024"
)

SQ="$ICONSET/_square.png"
sips --cropToHeightWidth 881 881 "$ICON_SRC" --out "$SQ" >/dev/null

for entry in "${SIZES[@]}"; do
  name="${entry%% *}"
  px="${entry##* }"
  sips -z "$px" "$px" "$SQ" --out "$ICONSET/$name" >/dev/null
done

iconutil -c icns "$ICONSET" -o ".build/AppIcon.icns"
rm -rf "$ICONSET" .build/release/_square.png

echo "==> Składanie $APP_BUNDLE ..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp ".build/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>NoSleep</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleGetInfoString</key>
    <string>NoSleep 1.5, Created by Kamil Gorecki</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.nosleep.app</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.5</string>
    <key>CFBundleVersion</key>
    <string>6</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Created by Kamil Gorecki</string>
</dict>
</plist>
PLIST

echo "==> Gotowe: $APP_BUNDLE"
echo "    Uruchom: open $APP_BUNDLE"