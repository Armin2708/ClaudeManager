#!/usr/bin/env bash
# Build ClaudeSessions.app — idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$REPO_DIR/src/main.swift"

APP_DIR="${APP_DIR_OVERRIDE:-$HOME/Applications/ClaudeSessions.app}"
MACOS_DIR="$APP_DIR/Contents/MacOS"
BIN="$MACOS_DIR/ClaudeSessions"
PLIST="$APP_DIR/Contents/Info.plist"

echo "==> Assembling bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$APP_DIR/Contents/Resources"

echo "==> Compiling $SRC"
swiftc -O "$SRC" -o "$BIN"

# Icon (generate once; reuse committed asset afterwards)
ICON="$REPO_DIR/assets/ClaudeSessions.icns"
if [ ! -f "$ICON" ]; then
  bash "$SCRIPT_DIR/make-icon.sh"
fi
cp -X "$ICON" "$APP_DIR/Contents/Resources/ClaudeSessions.icns"

# Source-toggle logos (rendered as template images at runtime)
cp -X "$REPO_DIR/assets/claude-logo.svg" "$APP_DIR/Contents/Resources/" 2>/dev/null || true
cp -X "$REPO_DIR/assets/codex-logo.svg" "$APP_DIR/Contents/Resources/" 2>/dev/null || true

echo "==> Writing Info.plist"
cat > "$PLIST" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.arminrad.claude-sessions</string>
	<key>CFBundleName</key>
	<string>ClaudeSessions</string>
	<key>CFBundleDisplayName</key>
	<string>ClaudeSessions</string>
	<key>CFBundleExecutable</key>
	<string>ClaudeSessions</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.2.0</string>
	<key>CFBundleVersion</key>
	<string>2</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>Focuses the terminal tab running a Claude Code session.</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>CFBundleIconFile</key>
	<string>ClaudeSessions</string>
</dict>
</plist>
PLIST_EOF

echo "==> Codesigning (ad-hoc)"
# Finder metadata/resource forks become real ._* files when a ZIP is unpacked
# with `unzip`, invalidating the resource seal. Strip them before signing.
xattr -cr "$APP_DIR"
find "$APP_DIR" -name '._*' -delete
codesign --force --deep -s - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "==> Done: $APP_DIR"
echo "    Binary: $BIN"
