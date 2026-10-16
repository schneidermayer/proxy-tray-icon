#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/ProxyTray.app"
BIN="$ROOT/.build/release/ProxyTray"
HELPER_BIN="$ROOT/.build/release/ProxyTrayHelper"
HELPER_PLIST="$ROOT/Resources/net.hsch.proxytray.network-helper.plist"
ICON_SRC="$ROOT/Scripts/icon512.icns"
ICON_NAME="icon512"
TARGET="/Applications/ProxyTray.app"
VERSION_FILE="$ROOT/VERSION"

APP_VERSION="${APP_VERSION:-}"
if [[ -z "$APP_VERSION" && -f "$VERSION_FILE" ]]; then
  APP_VERSION="$(awk 'NF { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); print; exit }' "$VERSION_FILE")"
fi

if [[ -z "$APP_VERSION" ]]; then
  echo "No app version found. Set APP_VERSION or populate $VERSION_FILE." >&2
  exit 1
fi

# A persistent privileged service must have a stable signing identity. Do not
# install an ad-hoc-signed app that cannot establish the helper's trust boundary.
SIGNING_IDENTITIES="$(security find-identity -v -p codesigning)"
SIGNING_IDENTITY="$(printf '%s\n' "$SIGNING_IDENTITIES" | awk -v requested="${CODE_SIGN_IDENTITY:-}" '
  /"Developer ID Application:/ {
    name = $0
    sub(/^[^"]*"/, "", name)
    sub(/".*$/, "", name)
    if (requested == "" || toupper($2) == toupper(requested) || name == requested) {
      print $2
      exit
    }
  }
')"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "No valid Developer ID Application signing identity found. Install one in Keychain, or set CODE_SIGN_IDENTITY to its full name or SHA-1 hash." >&2
  exit 1
fi

echo "Building release binary for version $APP_VERSION..."
swift build -c release

echo "Assembling app bundle at $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
  "$APP/Contents/Library/HelperTools" "$APP/Contents/Library/LaunchDaemons"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>CFBundleExecutable</key><string>ProxyTray</string>
    <key>CFBundleIdentifier</key><string>net.hsch.proxytray</string>
    <key>CFBundleName</key><string>ProxyTray</string>
    <key>CFBundleVersion</key><string>APP_VERSION_PLACEHOLDER</string>
    <key>CFBundleShortVersionString</key><string>APP_VERSION_PLACEHOLDER</string>
    <key>CFBundleIconFile</key><string>ICON_NAME_PLACEHOLDER</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
  </dict>
</plist>
EOF

sed -i '' "s/APP_VERSION_PLACEHOLDER/$APP_VERSION/g" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/"
cp "$HELPER_BIN" "$APP/Contents/Library/HelperTools/ProxyTrayHelper"
cp "$HELPER_PLIST" "$APP/Contents/Library/LaunchDaemons/"
chmod 755 "$APP/Contents/Library/HelperTools/ProxyTrayHelper"
chmod 644 "$APP/Contents/Library/LaunchDaemons/net.hsch.proxytray.network-helper.plist"

if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/$ICON_NAME.icns"
  sed -i '' "s/ICON_NAME_PLACEHOLDER/$ICON_NAME/" "$APP/Contents/Info.plist"
  echo "Bundled icon from $ICON_SRC"
else
  # Remove icon key if not present
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP/Contents/Info.plist" 2>/dev/null || true
  echo "No icon at $ICON_SRC; bundle will use default icon."
fi

echo "Signing the app and network helper..."
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
  --identifier net.hsch.proxytray.network-helper "$APP/Contents/Library/HelperTools/ProxyTrayHelper"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
  --identifier net.hsch.proxytray "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "App bundle assembled."

echo "Copying to $TARGET..."
rm -rf "$TARGET"
cp -R "$APP" "$TARGET"
echo "Copied to $TARGET. You can launch from Applications."
