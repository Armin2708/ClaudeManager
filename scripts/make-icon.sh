#!/usr/bin/env bash
# Generate ClaudeSessions.icns — dark rounded square with three status dots.
# Output: assets/ClaudeSessions.icns (committed; regenerating is optional).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS="$REPO_DIR/assets"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$ASSETS"

cat > "$TMP/icon.swift" <<'EOF'
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Rounded-square background (Big Sur style: sits inside a margin).
let margin: CGFloat = size * 0.09
let rect = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
let bg = NSBezierPath(roundedRect: rect, xRadius: size * 0.2, yRadius: size * 0.2)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.15, alpha: 1),
    NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.24, alpha: 1),
])!
gradient.draw(in: bg, angle: 90)

// Three status dots: green (pulsing/working), yellow (waiting), orange ring (done).
let dotR: CGFloat = size * 0.075
let cy = size / 2
let spacing = size * 0.21
let colors: [NSColor] = [.systemGreen, .systemYellow]
for (i, c) in colors.enumerated() {
    let cx = size / 2 - spacing + CGFloat(i) * spacing
    c.setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2)).fill()
}
// Orange ring
let cx = size / 2 + spacing
NSColor.systemOrange.setStroke()
let ring = NSBezierPath(ovalIn: NSRect(x: cx - dotR + 8, y: cy - dotR + 8, width: dotR * 2 - 16, height: dotR * 2 - 16))
ring.lineWidth = size * 0.022
ring.stroke()

image.unlockFocus()

let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
EOF

swift "$TMP/icon.swift" "$TMP/icon_1024.png"

ICONSET="$TMP/ClaudeSessions.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" > /dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o "$ASSETS/ClaudeSessions.icns"
echo "==> $ASSETS/ClaudeSessions.icns"
