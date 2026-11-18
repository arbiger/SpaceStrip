import AppKit
import CoreGraphics

/// One desktop, as shown in the menu bar.
struct SpaceTile {
    let space: VirtualSpace
    let window: WindowInfo?
    let image: NSImage?
    let isCurrent: Bool

    var title: String {
        if let window, let title = window.title, !title.isEmpty { return title }
        return window?.ownerName ?? "Desktop"
    }
}

enum TileStripRenderer {
    /// Draws the whole strip into one image so it can live in the status bar.
    static func render(
        tiles: [SpaceTile],
        tileSize: CGSize,
        gap: CGFloat,
        isDarkAppearance: Bool
    ) -> NSImage? {
        guard !tiles.isEmpty else { return nil }

        let scale: CGFloat = 2
        let width = CGFloat(tiles.count) * tileSize.width + CGFloat(tiles.count - 1) * gap
        let size = NSSize(width: width, height: tileSize.height)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (index, tile) in tiles.enumerated() {
            let x = CGFloat(index) * (tileSize.width + gap)
            let tileRect = NSRect(x: x, y: 0, width: tileSize.width, height: tileSize.height)
            draw(tile: tile, in: tileRect, isDarkAppearance: isDarkAppearance)
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    static func draw(tile: SpaceTile, in rect: NSRect, isDarkAppearance: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()

        if tile.isCurrent {
            NSColor.controlAccentColor.setFill()
            path.fill()
        } else {
            (isDarkAppearance ? NSColor.white : NSColor.black).withAlphaComponent(0.10).setFill()
            path.fill()
        }

        NSGraphicsContext.current?.saveGraphicsState()
        if let image = tile.image {
            path.addClip()
            drawAspectFill(image: image, in: rect)
        } else {
            // No preview yet: keep the tile readable against the wallpaper.
            (isDarkAppearance ? NSColor.white : NSColor.black).withAlphaComponent(0.18).setFill()
            path.fill()
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        if tile.isCurrent {
            NSColor.white.withAlphaComponent(0.85).setStroke()
            path.lineWidth = 1.2
            path.stroke()
        } else {
            (isDarkAppearance ? NSColor.white : NSColor.black).withAlphaComponent(0.35).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    /// Fills the tile with the image, cropping the overflow like a photo.
    private static func drawAspectFill(image: NSImage, in rect: NSRect) {
        guard let source = image.representations.first else { return }
        let sourceSize = NSSize(width: source.size.width, height: source.size.height)
        guard sourceSize.width > 0, sourceSize.height > 0 else { return }

        let scale = max(rect.width / sourceSize.width, rect.height / sourceSize.height)
        let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawRect = NSRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1)
    }
}
