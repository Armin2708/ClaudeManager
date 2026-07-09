#!/usr/bin/env bash
# Package ClaudeSessions.app into dist/ClaudeSessions.zip (builds first).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$HOME/Applications/ClaudeSessions.app"
DIST="$REPO_DIR/dist"

bash "$SCRIPT_DIR/build.sh"

mkdir -p "$DIST"
rm -f "$DIST/ClaudeSessions.zip"
ditto -c -k --keepParent "$APP_DIR" "$DIST/ClaudeSessions.zip"
echo "==> $DIST/ClaudeSessions.zip"
echo "    Install: unzip into /Applications or ~/Applications and double-click."
echo "    Note: ad-hoc signed — on another Mac, right-click > Open the first time."
