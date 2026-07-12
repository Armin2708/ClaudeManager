#!/usr/bin/env bash
# Package ClaudeSessions.app into dist/ClaudeSessions.zip (builds first).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="${APP_DIR_OVERRIDE:-$HOME/Applications/ClaudeSessions.app}"
DIST="${DIST_DIR_OVERRIDE:-$REPO_DIR/dist}"

bash "$SCRIPT_DIR/build.sh"

mkdir -p "$DIST"
rm -f "$DIST/ClaudeSessions.zip"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --noqtn --noacl \
  --keepParent "$APP_DIR" "$DIST/ClaudeSessions.zip"

if unzip -Z1 "$DIST/ClaudeSessions.zip" | grep -E '(^|/)\._|(^|/)__MACOSX/' >/dev/null; then
  echo "error: package contains AppleDouble metadata" >&2
  exit 1
fi

VERIFY_DIR=$(mktemp -d)
trap 'rm -rf "$VERIFY_DIR"' EXIT
unzip -q "$DIST/ClaudeSessions.zip" -d "$VERIFY_DIR"
codesign --verify --deep --strict "$VERIFY_DIR/ClaudeSessions.app"
echo "==> $DIST/ClaudeSessions.zip"
echo "    Install: unzip into /Applications or ~/Applications and double-click."
echo "    Verified: clean archive + valid ad-hoc resource seal"
echo "    Note: on another Mac, right-click > Open the first time."
