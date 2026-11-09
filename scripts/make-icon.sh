#!/bin/zsh
# Makes assets/AppIcon.icns from assets/logo.svg: the logo in the macOS icon shape (a rounded
# square, 824 of 1024 px, with the standard margin), at every size macOS asks for.
#   scripts/make-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/render.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
guard let logo = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else { fatalError("can't read \(args[1])") }
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).addClip()
logo.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
SWIFT
swift "$TMP/render.swift" assets/logo.svg "$TMP/icon_1024.png"

SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o assets/AppIcon.icns
cp "$TMP/icon_1024.png" assets/icon.png
echo "Made assets/AppIcon.icns and assets/icon.png"
