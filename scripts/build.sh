#!/usr/bin/env bash
# Build ClaudeSessions.app — idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$REPO_DIR/src/main.swift"

APP_DIR="$HOME/Applications/ClaudeSessions.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
BIN="$MACOS_DIR/ClaudeSessions"
PLIST="$APP_DIR/Contents/Info.plist"

echo "==> Assembling bundle at $APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$APP_DIR/Contents/Resources"

echo "==> Compiling $SRC"
swiftc -O "$SRC" -o "$BIN"

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
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>Focuses the terminal tab running a Claude Code session.</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST_EOF

echo "==> Codesigning (ad-hoc)"
codesign --force --deep -s - "$APP_DIR"

echo "==> Done: $APP_DIR"
echo "    Binary: $BIN"
