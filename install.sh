#!/usr/bin/env bash
#
# ClaudeSessions installer
#
# Downloads the latest ClaudeSessions release, installs it to ~/Applications,
# removes the Gatekeeper quarantine flag, and launches the app.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Armin2708/ClaudeManager/main/install.sh | bash
#
# No sudo required. Writes only to ~/Applications and a temporary directory.

set -euo pipefail

RELEASE_URL="https://github.com/Armin2708/ClaudeManager/releases/latest/download/ClaudeSessions.zip"
APP_NAME="ClaudeSessions.app"
INSTALL_DIR="$HOME/Applications"
APP_PATH="$INSTALL_DIR/$APP_NAME"

# Work in a temporary directory; clean it up on exit no matter what.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading the latest ClaudeSessions release..."
curl -fsSL "$RELEASE_URL" -o "$TMP_DIR/ClaudeSessions.zip"

echo "Unpacking..."
unzip -q "$TMP_DIR/ClaudeSessions.zip" -d "$TMP_DIR"

if [ ! -d "$TMP_DIR/$APP_NAME" ]; then
  echo "Error: $APP_NAME not found in the downloaded archive." >&2
  exit 1
fi

# Install to ~/Applications (user-level, no sudo needed).
mkdir -p "$INSTALL_DIR"

# Stop a running copy and replace any existing install.
pkill -x ClaudeSessions || true
rm -rf "$APP_PATH"
mv "$TMP_DIR/$APP_NAME" "$APP_PATH"

# Remove the Gatekeeper quarantine flag so the app opens without the
# "unidentified developer" warning (the app is ad-hoc signed, not notarized).
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

echo "Installed $APP_NAME to $INSTALL_DIR."

echo "Launching ClaudeSessions..."
open "$APP_PATH"

echo ""
echo "Next steps:"
echo "  1. The app will ask to install its Claude Code hooks — click \"Install Hooks\"."
echo "     (It backs up ~/.claude/settings.json to settings.json.bak first.)"
echo "  2. If macOS asks to let ClaudeSessions control iTerm2, approve it —"
echo "     that's how tab titles and click-to-focus work."
echo ""
echo "Done. Look for the panel under your notch."
