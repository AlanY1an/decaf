// The four menu bar icon states, drawn from the shipping IconRenderer.
//
// This is the ICON art, not the menu. It is a real render of the real template
// images the app installs into the status item — nothing here imitates the
// NSMenu that drops down from them.

import AppKit
import SwiftUI
import DecafCore

@MainActor
func renderIconStrip() {
    let states: [(MenuBarIconState, String)] = [
        (.idle, "Idle"),
        (.manualHold, "Manual hold"),
        (.agentHold(sessionCount: 2), "Agents working"),
        (.pausedBySafety, "Paused by safety"),
    ]

    for (dark, suffix) in [(false, "light"), (true, "dark")] {
        let ink: NSColor = dark ? .white : .black
        let cell = CGSize(width: 132, height: 64)
        let size = CGSize(width: cell.width * CGFloat(states.count), height: cell.height)

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = size

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx

        // An opaque plate, because these are TEMPLATE images: the dark variant
        // is white ink, and on transparency it is invisible in a light-themed
        // reader. The plate is documentation background, not a claim about what
        // the menu bar looks like — a real menu bar takes its colour from the
        // wallpaper behind it.
        (dark ? NSColor(calibratedWhite: 0.11, alpha: 1) : NSColor.white).setFill()
        NSRect(origin: .zero, size: size).fill()

        for (index, entry) in states.enumerated() {
            let originX = cell.width * CGFloat(index)
            let image = IconRenderer.shared.image(for: entry.0)

            // Template image → tint by drawing it as a mask.
            let iconRect = NSRect(
                x: originX + (cell.width - image.size.width) / 2,
                y: cell.height - 12 - image.size.height,
                width: image.size.width, height: image.size.height
            )
            // Tint in the image's OWN context, which starts transparent, so
            // `.destinationIn` has an empty canvas to carve. Doing it directly
            // on the plate paints solid squares: the plate's opaque pixels
            // survive the carve.
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                ink.setFill()
                rect.fill()
                image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
                return true
            }
            tinted.draw(in: iconRect)

            let label = NSAttributedString(
                string: entry.1,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: ink.withAlphaComponent(0.75),
                ]
            )
            let labelSize = label.size()
            label.draw(at: NSPoint(x: originX + (cell.width - labelSize.width) / 2, y: 14))
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: outputDirectory)
            .appendingPathComponent("menubar-icons-\(suffix).png")
        try? data.write(to: url)
        print("  menubar-icons-\(suffix).png  \(Int(size.width * scale))x\(Int(size.height * scale)) px")
    }
}
