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

RELEASE_URL="${CLAUDE_SESSIONS_RELEASE_URL:-https://github.com/Armin2708/ClaudeManager/releases/latest/download/ClaudeSessions.zip}"
APP_NAME="ClaudeSessions.app"
INSTALL_DIR="${CLAUDE_SESSIONS_INSTALL_DIR:-$HOME/Applications}"
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

if find "$TMP_DIR/$APP_NAME" -name '._*' -print -quit | grep -q .; then
  echo "Error: downloaded app contains invalid AppleDouble metadata." >&2
  exit 1
fi

if ! codesign --verify --deep --strict "$TMP_DIR/$APP_NAME"; then
  echo "Error: downloaded app failed code-signature verification." >&2
  exit 1
fi

# Install to ~/Applications (user-level, no sudo needed).
mkdir -p "$INSTALL_DIR"

# Only replace the installed copy after the download has passed verification.
if [ "${CLAUDE_SESSIONS_SKIP_LAUNCH:-0}" != "1" ]; then
  pkill -x ClaudeSessions || true
fi
rm -rf "$APP_PATH"
mv "$TMP_DIR/$APP_NAME" "$APP_PATH"

# Remove the Gatekeeper quarantine flag so the app opens without the
# "unidentified developer" warning (the app is ad-hoc signed, not notarized).
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

echo "Installed $APP_NAME to $INSTALL_DIR."

echo "Launching ClaudeSessions..."
if [ "${CLAUDE_SESSIONS_SKIP_LAUNCH:-0}" = "1" ]; then
  echo "Launch skipped by CLAUDE_SESSIONS_SKIP_LAUNCH."
else
  open "$APP_PATH"
fi

echo ""
echo "Next steps:"
echo "  1. The app will ask to install Claude and Codex lifecycle tracking."
echo "     Existing settings files are backed up first."
echo "  2. In Codex, run /hooks once and trust the ClaudeSessions entries."
echo "  3. If macOS asks to let ClaudeSessions control your terminal, approve it —"
echo "     that's how tab titles and click-to-focus work."
echo ""
echo "Done. Look for the panel under your notch."
