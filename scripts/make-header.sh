#!/bin/zsh
# Makes assets/header.gif, the README's animated header, from assets/header.html: WebKit renders
# the page's 9 s animation one frame at a time, and ffmpeg turns the frames into a looping GIF.
#   scripts/make-header.sh            10 frames a second
#   FPS=15 scripts/make-header.sh     smoother, bigger file
# Needs ffmpeg (brew install ffmpeg) and the network once, for the JetBrains Mono web font.
set -euo pipefail
cd "$(dirname "$0")/.."
FPS=${FPS:-10}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/render.swift" <<'SWIFT'
import AppKit
import WebKit

// render.swift <page.html> <out folder> <fps> <seconds>: one PNG per frame, at 1280×640.
let args = CommandLine.arguments
let page = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
let fps = Double(args[3])!, seconds = Double(args[4])!
let size = NSSize(width: 1280, height: 640)

@MainActor func render() async throws {
    let web = WKWebView(frame: NSRect(origin: .zero, size: size))
    let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = web
    web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    for _ in 0..<200 {   // up to 20 s for the page and its font
        try await Task.sleep(for: .milliseconds(100))
        let ready = try? await web.callAsyncJavaScript(
            "if (document.readyState !== 'complete') return false; await document.fonts.ready; return document.fonts.check('16px \"JetBrains Mono\"')",
            contentWorld: .page) as? Bool
        if ready == true { break }
    }
    let frames = Int((seconds * fps).rounded())
    for i in 0..<frames {
        let ms = Double(i) / fps * 1000
        // Pause every animation at the same moment, so each frame shows exactly that time.
        _ = try await web.callAsyncJavaScript(
            "document.getAnimations().forEach(a => { a.pause(); a.currentTime = ms })", arguments: ["ms": ms], contentWorld: .page)
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let image = try await web.takeSnapshot(configuration: config)
        // Snapshots come at the screen's scale; draw each into a 1280×640 bitmap.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let name = String(format: "frame%04d.png", i)
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
    print("rendered \(frames) frames")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    do { try await render(); exit(0) } catch { print("render failed: \(error)"); exit(1) }
}
app.run()
SWIFT

mkdir "$TMP/frames"
swiftc -O "$TMP/render.swift" -o "$TMP/render" 2>&1 | grep -v "^$" || true
"$TMP/render" "$PWD/assets/header.html" "$TMP/frames" "$FPS" 9
ffmpeg -loglevel error -y -framerate "$FPS" -i "$TMP/frames/frame%04d.png" \
    -filter_complex "split[a][b];[a]palettegen=max_colors=128:stats_mode=full[p];[b][p]paletteuse=dither=none" \
    -loop 0 assets/header.gif
echo "Made assets/header.gif ($(du -h assets/header.gif | cut -f1))"
