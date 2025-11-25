#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/ProxyTray.app"
BIN="$ROOT/.build/release/ProxyTray"
ICON_SRC="$ROOT/Scripts/icon512.icns"
ICON_NAME="icon512"
TARGET="/Applications/ProxyTray.app"

echo "Building release binary..."
swift build -c release

echo "Assembling app bundle at $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>CFBundleExecutable</key><string>ProxyTray</string>
    <key>CFBundleIdentifier</key><string>net.hsch.proxytray</string>
    <key>CFBundleName</key><string>Proxy Tray Icoon</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleIconFile</key><string>ICON_NAME_PLACEHOLDER</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
  </dict>
</plist>
EOF

cp "$BIN" "$APP/Contents/MacOS/"

if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/$ICON_NAME.icns"
  sed -i '' "s/ICON_NAME_PLACEHOLDER/$ICON_NAME/" "$APP/Contents/Info.plist"
  echo "Bundled icon from $ICON_SRC"
else
  # Remove icon key if not present
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP/Contents/Info.plist" 2>/dev/null || true
  echo "No icon at $ICON_SRC; bundle will use default icon."
fi

echo "Done. Launch $APP to run."

echo "Copying to $TARGET..."
rm -rf "$TARGET"
cp -R "$APP" "$TARGET"
echo "Copied to $TARGET. You can launch from Applications."
