import AppKit

/// A panel that never takes focus.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The floating copy of the strip.
///
/// macOS hides the menu bar while a full screen app is in front, so the menu
/// bar copy is not always reachable. This panel joins every space, including
/// the ones a full screen app lives in, and floats above them.
final class OverlayController {
    let panel: OverlayPanel
    private let stripView = TileStripView()
    private var movedByUser = false
    private var visible = true
    private var suspended = false
    private var expectedProgrammaticOrigin: NSPoint?

    /// Called when the strip's close button is clicked.
    var onClose: (() -> Void)?
    var onAdd: (() -> Void)?

    init(menu: NSMenu, onSelect: @escaping (VirtualSpace) -> Void) {
        panel = OverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        stripView.onSelect = onSelect
        stripView.menu = menu
        stripView.onClose = { [weak self] in self?.onClose?() }
        stripView.onAdd = { [weak self] in self?.onAdd?() }
        panel.contentView = stripView

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if let expected = self.expectedProgrammaticOrigin,
               abs(self.panel.frame.minX - expected.x) < 1,
               abs(self.panel.frame.minY - expected.y) < 1 {
                self.expectedProgrammaticOrigin = nil
                return
            }
            self.movedByUser = true
        }
    }

    static func usableFrame(screenFrame: NSRect, visibleFrame: NSRect, menuHeight: CGFloat, safeTop: CGFloat) -> NSRect {
        let top = min(visibleFrame.maxY, screenFrame.maxY - max(menuHeight, safeTop, 0))
        return NSRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width,
                      height: max(0, top - visibleFrame.minY))
    }

    func update(tiles: [SpaceTile], layout: TileStripLayout, screen: NSScreen?) {
        stripView.layout = layout
        stripView.tiles = tiles
        guard !suspended else { return }

        let size = NSSize(
            width: layout.width(forTileCount: tiles.count),
            height: layout.height()
        )
        let fallback = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let visibleFrame = Self.usableFrame(screenFrame: screen?.frame ?? fallback,
                                            visibleFrame: screen?.visibleFrame ?? fallback,
                                            menuHeight: NSStatusBar.system.thickness,
                                            safeTop: screen?.safeAreaInsets.top ?? 0)
        let preferred = movedByUser ? panel.frame.origin : NSPoint(x: visibleFrame.maxX - size.width - 12, y: visibleFrame.maxY - size.height - 10)
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - size.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - size.height)
        let origin = NSPoint(
            x: min(max(preferred.x, visibleFrame.minX), maxX),
            y: min(max(preferred.y, visibleFrame.minY), maxY)
        )
        expectedProgrammaticOrigin = origin
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        DispatchQueue.main.async { [weak self] in
            guard self?.expectedProgrammaticOrigin == origin else { return }
            self?.expectedProgrammaticOrigin = nil
        }
        if visible {
            panel.orderFrontRegardless()
        }

    }

    func hide() {
        visible = false
        if !suspended { panel.orderOut(nil) }
    }

    func show() {
        visible = true
        if !suspended { panel.orderFrontRegardless() }
    }

    func suspend() {
        suspended = true
        panel.orderOut(nil)
    }

    func resume() {
        suspended = false
    }

    var isVisible: Bool { panel.isVisible }

}
