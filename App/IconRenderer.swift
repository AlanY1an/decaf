// IconRenderer — four-state menu bar icon (plan 04 §2).
//
// `.menu`-style MenuBarExtra labels are snapshotted into static template images,
// so the icon is a set of four cached, monochrome template images (18 pt target
// height); state changes swap the image — no animation, ever.
//
// This file is drawing only. `MenuBarIconState`, the snapshot → state mapping
// (priority pausedBySafety > agentHold > manualHold > idle) and the
// accessibility strings live in CaffeinateCore's MenuPresentation, where they
// are unit-tested; nothing here decides anything.

import AppKit
import CaffeinateCore

// MARK: - Renderer

/// Composites SF Symbols into per-state template images and caches them.
/// Plan 04 test contract: every state returns `isTemplate == true`, 18 pt size,
/// and a second call for the same state returns the identical instance.
@MainActor
final class IconRenderer {
    static let shared = IconRenderer()

    private var cache: [MenuBarIconState: NSImage] = [:]
    private let canvasSize = NSSize(width: 18, height: 18)

    /// Numeric badge legibility cap (plan 04 risk 5): counts above this render
    /// as the cap value; the menu shows the exact count.
    private static let badgeCountCap = 9

    func image(for state: MenuBarIconState) -> NSImage {
        let key = normalized(state)
        if let cached = cache[key] { return cached }
        let rendered = render(key)
        cache[key] = rendered
        return rendered
    }

    /// Convenience: snapshot → image in one step.
    func image(for snapshot: AppStateSnapshot) -> NSImage {
        image(for: iconState(for: snapshot))
    }

    private func normalized(_ state: MenuBarIconState) -> MenuBarIconState {
        if case .agentHold(let n) = state {
            return .agentHold(sessionCount: min(max(n, 1), Self.badgeCountCap))
        }
        return state
    }

    private func render(_ state: MenuBarIconState) -> NSImage {
        let size = canvasSize
        let image = NSImage(size: size, flipped: false) { rect in
            switch state {
            case .idle:
                Self.drawSymbol("cup.and.saucer", pointSize: 14, in: rect)
            case .manualHold:
                Self.drawSymbol("cup.and.saucer.fill", pointSize: 14, in: rect)
            case .agentHold(let count):
                // Slightly smaller cup, nudged toward bottom-left, to make room
                // for the top-right badge.
                Self.drawSymbol(
                    "cup.and.saucer.fill", pointSize: 13, in: rect,
                    offset: NSPoint(x: -0.5, y: -0.5)
                )
                if count <= 1 {
                    Self.drawDotBadge(in: rect)
                } else {
                    Self.drawCountBadge(count, in: rect)
                }
            case .pausedBySafety:
                Self.drawSymbol(
                    "cup.and.saucer", pointSize: 13, in: rect,
                    offset: NSPoint(x: -0.5, y: 0.5)
                )
                Self.drawSlashBadge(in: rect)
            }
            return true
        }
        // Template image: single color, system does the tinting. This is the
        // entire dark-mode / increased-contrast / Tahoe compatibility strategy
        // (plan 04 risk 3) — never set custom colors.
        image.isTemplate = true
        image.accessibilityDescription = MenuCopy.accessibilityLabel(for: state)
        return image
    }

    // MARK: Drawing helpers (all draw plain black; only alpha matters in a template)

    private static func drawSymbol(
        _ name: String,
        pointSize: CGFloat,
        in rect: NSRect,
        offset: NSPoint = .zero
    ) {
        guard
            let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
            let symbol = base.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            )
        else { return }
        let size = symbol.size
        let origin = NSPoint(
            x: rect.midX - size.width / 2 + offset.x,
            y: rect.midY - size.height / 2 + offset.y
        )
        symbol.draw(
            at: origin,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }

    /// n == 1: plain dot at the top-right.
    private static func drawDotBadge(in rect: NSRect) {
        let diameter: CGFloat = 5
        let badgeRect = NSRect(
            x: rect.maxX - diameter - 0.5,
            y: rect.maxY - diameter - 0.5,
            width: diameter,
            height: diameter
        )
        knockOut(around: badgeRect)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()
    }

    /// n >= 2: 9 pt monospaced digit drawn directly into the template.
    private static func drawCountBadge(_ count: Int, in rect: NSRect) {
        let text = "\(count)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let textSize = text.size(withAttributes: attributes)
        let origin = NSPoint(
            x: rect.maxX - textSize.width,
            y: rect.maxY - textSize.height + 1
        )
        knockOut(around: NSRect(origin: origin, size: textSize))
        text.draw(at: origin, withAttributes: attributes)
    }

    /// pausedBySafety: small bolt.slash at the bottom-right.
    private static func drawSlashBadge(in rect: NSRect) {
        guard
            let base = NSImage(systemSymbolName: "bolt.slash", accessibilityDescription: nil),
            let symbol = base.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)
            )
        else { return }
        let size = symbol.size
        let origin = NSPoint(x: rect.maxX - size.width, y: rect.minY)
        knockOut(around: NSRect(origin: origin, size: size))
        symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// Punches a hole behind a badge so it reads against the cup silhouette.
    private static func knockOut(around badgeRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .destinationOut
        NSColor.black.setFill()
        NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.5, dy: -1.5)).fill()
        context.restoreGraphicsState()
    }
}
