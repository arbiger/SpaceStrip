import AppKit
import CoreGraphics

/// Geometry of the tile strip, shared by the menu bar image and the
/// floating panel so both agree on where a tile sits.
struct TileStripLayout {
    let tileSize: NSSize
    let gap: CGFloat
    var padding: CGFloat = 0
    /// Room for the close button at the right hand end of the strip.
    var closeSize: CGFloat = 0

    var stride: CGFloat { tileSize.width + gap }

    func width(forTileCount count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let tilesWidth = CGFloat(count) * tileSize.width + CGFloat(count - 1) * gap
        let closeGap = closeSize > 0 ? gap : 0
        return tilesWidth + closeGap + padding * 2 + closeSize + (closeSize > 0 ? closeSize + gap : 0)
    }

    func height() -> CGFloat {
        tileSize.height + padding * 2
    }

    func rect(forTileAt index: Int) -> NSRect {
        NSRect(
            x: padding + CGFloat(index) * stride,
            y: padding,
            width: tileSize.width,
            height: tileSize.height
        )
    }

    /// The close button, at the right hand end of the strip.
    func closeRect(tileCount: Int) -> NSRect {
        let tilesWidth = CGFloat(tileCount) * tileSize.width + CGFloat(max(tileCount - 1, 0)) * gap
        return NSRect(
            x: padding + tilesWidth + gap + closeSize + gap,
            y: padding + (tileSize.height - closeSize) / 2,
            width: closeSize,
            height: closeSize
        )
    }

    func addRect(tileCount: Int) -> NSRect {
        closeRect(tileCount: tileCount).offsetBy(dx: -(closeSize + gap), dy: 0)
    }

    /// Which tile contains the point, or nil when it is in padding or a gap.
    func tileIndex(at point: NSPoint, tileCount: Int) -> Int? {
        for index in 0..<tileCount where rect(forTileAt: index).contains(point) {
            return index
        }
        return nil
    }
}

/// Draws the tiles and turns clicks into space switches.
final class TileStripView: NSView {
    var tiles: [SpaceTile] = [] {
        didSet {
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }

    var layout = TileStripLayout(tileSize: NSSize(width: 32, height: 18), gap: 5)
    var onSelect: ((VirtualSpace) -> Void)?
    var onClose: (() -> Void)?
    var onAdd: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: layout.width(forTileCount: tiles.count), height: layout.height())
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        // A backing panel so the tiles stay readable over any content.
        let panel = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        NSColor.black.withAlphaComponent(0.55).setFill()
        panel.fill()
        NSColor.white.withAlphaComponent(0.15).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        for (index, tile) in tiles.enumerated() {
            let rect = layout.rect(forTileAt: index)
            TileStripRenderer.draw(tile: tile, in: rect, isDarkAppearance: isDark)
        }

        if layout.closeSize > 0 {
            drawAddButton()
            drawCloseButton()
        }
    }

    private func drawAddButton() {
        let rect = layout.addRect(tileCount: tiles.count)
        let path = NSBezierPath(ovalIn: rect)
        NSColor.white.withAlphaComponent(0.18).setFill()
        path.fill()
        let plus = NSBezierPath()
        let inset = rect.width * 0.3
        plus.move(to: NSPoint(x: rect.minX + inset, y: rect.midY))
        plus.line(to: NSPoint(x: rect.maxX - inset, y: rect.midY))
        plus.move(to: NSPoint(x: rect.midX, y: rect.minY + inset))
        plus.line(to: NSPoint(x: rect.midX, y: rect.maxY - inset))
        NSColor.white.withAlphaComponent(0.85).setStroke()
        plus.lineWidth = 1.4
        plus.stroke()
    }

    private func drawCloseButton() {
        let rect = layout.closeRect(tileCount: tiles.count)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.white.withAlphaComponent(0.18).setFill()
        path.fill()

        let cross = NSBezierPath()
        let inset = rect.width * 0.32
        cross.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        cross.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        cross.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
        cross.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
        NSColor.white.withAlphaComponent(0.85).setStroke()
        cross.lineWidth = 1.4
        cross.lineCapStyle = .round
        cross.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pendingSpace = nil
        pendingClose = false
        pendingAdd = false
        if layout.closeSize > 0, layout.addRect(tileCount: tiles.count).contains(point) {
            pendingAdd = event.clickCount == 1
            return
        }
        if layout.closeSize > 0, layout.closeRect(tileCount: tiles.count).contains(point) {
            pendingClose = true
            return
        }
        guard let index = layout.tileIndex(at: point, tileCount: tiles.count) else {
            // Not on a tile: let the window be dragged instead.
            super.mouseDown(with: event)
            return
        }
        pendingSpace = tiles[index].space
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if pendingAdd {
            pendingAdd = false
            if layout.addRect(tileCount: tiles.count).contains(point) { onAdd?() }
            return
        }
        if pendingClose {
            pendingClose = false
            if layout.closeRect(tileCount: tiles.count).contains(point) {
                onClose?()
            }
            return
        }
        guard let pendingSpace,
              let index = layout.tileIndex(at: point, tileCount: tiles.count),
              tiles[index].space.id == pendingSpace.id
        else {
            self.pendingSpace = nil
            return
        }
        self.pendingSpace = nil

        // Switching happens on mouse up so that a double click cannot fire
        // two switches, the second of which would land on a different desktop.
        guard !tiles[index].isCurrent else { return }
        Debug.log("tile click: index=\(index) space=\(pendingSpace.id)")
        onSelect?(pendingSpace)
    }

    private var pendingSpace: VirtualSpace?
    private var pendingClose = false
    private var pendingAdd = false

    override var acceptsFirstResponder: Bool { false }
}
