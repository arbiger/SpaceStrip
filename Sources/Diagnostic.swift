import AppKit
import CoreGraphics
import Foundation

/// Prints what SpaceStrip sees on this Mac. Run with:
///   ./build/SpaceStrip.app/Contents/MacOS/SpaceStrip --dump
enum Diagnostic {
    @MainActor
    static func dump() {
        setvbuf(stdout, nil, _IONBF, 0)

        print("SkyLight supported: \(SkyLight.isSupported)")
        print("active space id:   \(SpaceAPI.activeSpaceID())")

        let displays = SpaceAPI.managedDisplays()
        print("displays: \(displays.count)")
        for display in displays {
            let spaces = display.spaces.map { space in
                "\(space.id):type\(space.kind.rawValue):pid\(space.ownerPID.map { String($0) } ?? "-"):windows\(space.windowIDs)"
            }
            print("  display \(display.identifier) current=\(display.currentSpaceID) spaces=\(spaces)")
        }

        let grouped = WindowCatalog.windowsBySpace()
        print("window buckets:")
        for (spaceID, windows) in grouped.sorted(by: { $0.key < $1.key }) {
            let candidates = windows.filter { $0.isTileCandidate }
            print("  space \(spaceID): \(windows.count) windows, \(candidates.count) candidates")
            for window in candidates.prefix(6) {
                print("     \(window.id) [\(window.ownerName)] onscreen=\(window.isOnScreen) bounds=\(window.bounds) title=\(window.title ?? "-")")
            }
        }

        let screenBounds = NSScreen.main?.frame ?? .zero
        print("screen: \(screenBounds)")
        for display in displays {
            for space in display.spaces {
                let window = WindowCatalog.representativeWindow(
                    in: grouped[space.id] ?? [],
                    screenBounds: screenBounds
                )
                print("  tile for space \(space.id): \(window.map { "\($0.ownerName) (\($0.bounds))" } ?? "no window")")
            }
        }
    }

    /// Checks state gating and rendering geometry without changing Spaces.
    @MainActor
    static func selfTest() -> Bool {
        setvbuf(stdout, nil, _IONBF, 0)
        let gatePasses = SpaceSwitchGate.selfTest()
        var hover = HoverState()
        let hoverPasses = hover.update(icon: true, panel: false, visible: false, delay: 2, now: 0) == 1
            && hover.update(icon: false, panel: false, visible: true, delay: 2, now: 1) == 0
            && hover.update(icon: false, panel: true, visible: true, delay: 2, now: 2) == 0
            && hover.update(icon: false, panel: false, visible: true, delay: 2, now: 3) == 0
            && hover.update(icon: false, panel: false, visible: true, delay: 2, now: 5) == -1
        hover.dismissed()
        let suppressionPasses = hover.update(icon: true, panel: false, visible: false, delay: 2, now: 6) == 0
            && hover.update(icon: false, panel: false, visible: false, delay: 2, now: 7) == 0
            && hover.update(icon: true, panel: false, visible: false, delay: 2, now: 8) == 1
            && hover.update(icon: false, panel: false, visible: true, delay: 0, now: 20) == 0
        hover.reset()
        let resetPasses = hover.update(icon: false, panel: false, visible: true, delay: 1, now: 30) == 0
            && hover.update(icon: false, panel: false, visible: true, delay: 1, now: 31) == -1
        let ids: [UInt64] = [10, 24, 38]
        let mappingPasses = MissionControlSpaceSwitcher.spaceIndex(spaceID: 10, orderedIDs: ids) == 0
            && MissionControlSpaceSwitcher.spaceIndex(spaceID: 24, orderedIDs: ids) == 1
            && MissionControlSpaceSwitcher.spaceIndex(spaceID: 38, orderedIDs: ids) == 2
            && MissionControlSpaceSwitcher.spaceIndex(spaceID: 99, orderedIDs: ids) == nil
            && MissionControlSpaceSwitcher.buttonIndex(spaceID: 24, orderedIDs: ids, confirmedIDs: ids, buttonCount: 3) == 1
            && MissionControlSpaceSwitcher.buttonIndex(spaceID: 38, orderedIDs: ids, confirmedIDs: ids, buttonCount: 3) == 2
            && MissionControlSpaceSwitcher.buttonIndex(spaceID: 24, orderedIDs: ids, confirmedIDs: [10, 38, 24], buttonCount: 3) == nil
            && MissionControlSpaceSwitcher.buttonIndex(spaceID: 24, orderedIDs: ids, confirmedIDs: [10, 24, 39], buttonCount: 3) == nil
            && MissionControlSpaceSwitcher.buttonIndex(spaceID: 24, orderedIDs: ids, confirmedIDs: ids, buttonCount: 2) == nil
            && MissionControlSpaceSwitcher.buttonIndex(spaceID: 24, orderedIDs: [10, 24, 24], confirmedIDs: [10, 24, 24], buttonCount: 3) == nil
        func space(_ id: UInt64, _ kind: VirtualSpace.Kind) -> VirtualSpace {
            VirtualSpace(id: id, kind: kind, ownerPID: nil, windowIDs: [])
        }
        let sameAppSpaces = [24, 38].map { VirtualSpace(id: UInt64($0), kind: .fullScreenApp, ownerPID: 42, windowIDs: []) }
        let tiled = VirtualSpace(id: 50, kind: .tiledLayout, ownerPID: nil, windowIDs: [101, 102])
        let singleWindow = VirtualSpace(id: 51, kind: .tiledLayout, ownerPID: 42, windowIDs: [101])
        let emptyLayout = VirtualSpace(id: 53, kind: .tiledLayout, ownerPID: nil, windowIDs: [])
        let shortcutSpaces = [space(10, .desktop), space(24, .fullScreenApp), space(38, .desktop)]
        let modePasses = !SpaceSwitchMode.default.usesSlide(source: .desktop, target: .desktop)
            && SpaceSwitchMode.default.usesSlide(source: .desktop, target: .fullScreenApp)
            && SpaceSwitchMode.default.usesSlide(source: .tiledLayout, target: .desktop)
            && !SpaceSwitchMode.allJump.usesSlide(source: .fullScreenApp, target: .desktop)
            && !SpaceSwitchMode.allJump.usesSlide(source: .desktop, target: .desktop)
            && SpaceSwitchMode.allSlide.usesSlide(source: .desktop, target: .desktop)
            && SpaceSwitchMode.allSlide.usesSlide(source: .fullScreenApp, target: .desktop)
            && SpaceSwitchMode(rawValue: 99) == nil
            && SpaceSwitchMode.stored(nil) == .allSlide
            && SpaceSwitchMode.stored(99) == .allSlide
            && SpaceSwitchMode.stored("invalid") == .allSlide
            && SpaceSwitchMode.stored(NSNumber(value: true)) == .allSlide
            && SpaceSwitchMode.stored(NSNumber(value: 0.0)) == .allSlide
            && SpaceSwitchMode.stored(0) == .default
            && SpaceSwitchMode.stored(1) == .allJump
            && SpaceSwitchMode.stored(2) == .allSlide
            && SpaceSwitchMode.default.title == "Mixed"
            && SpaceShortcutSwitcher.storedWait(nil) == 150
            && SpaceShortcutSwitcher.storedWait(200) == 150
            && SpaceShortcutSwitcher.storedWait(900) == 150
            && SpaceShortcutSwitcher.storedWait("invalid") == 150
            && SpaceShortcutSwitcher.storedWait(NSNumber(value: 300.0)) == 150
            && SpaceShortcutSwitcher.waitOptions == [150, 300, 450, 650]
            && SpaceShortcutSwitcher.waitOptions.allSatisfy { SpaceShortcutSwitcher.storedWait($0) == $0 }
        func binding(_ enabled: Bool, _ code: Int, _ flags: Int) -> [String: Any] {
            ["enabled": enabled, "value": ["type": "standard", "parameters": [65535, code, flags]]]
        }
        let shortcutPasses = SpaceShortcutSwitcher.route(spaces: shortcutSpaces, source: 10, target: 24) == [24]
            && SpaceShortcutSwitcher.route(spaces: shortcutSpaces, source: 38, target: 10) == [24, 10]
            && SpaceShortcutSwitcher.route(spaces: shortcutSpaces, source: 10, target: 10) == nil
            && SpaceShortcutSwitcher.route(spaces: [space(10, .desktop), space(11, .unknown), space(24, .fullScreenApp)], source: 10, target: 24) == nil
            && SpaceShortcutSwitcher.route(spaces: [space(10, .desktop), space(10, .fullScreenApp)], source: 10, target: 10) == nil
            && SpaceShortcutSwitcher.Binding(binding(true, 123, 0x840000))?.flags == 0x840000
            && SpaceShortcutSwitcher.Binding(binding(false, 123, 0x840000)) == nil
            && SpaceShortcutSwitcher.Binding(binding(true, 65535, 0x840000)) == nil
            && SpaceShortcutSwitcher.Binding(binding(true, 124, 0x1000000)) == nil
            && SpaceShortcutSwitcher.Binding(nil) == nil
        let visibilityPasses = sameAppSpaces.allSatisfy { !$0.isVisible(showFullscreen: false) && $0.isVisible(showFullscreen: true) }
            && space(10, .desktop).isVisible(showFullscreen: false)
            && tiled.isVisible(showFullscreen: true) && singleWindow.isVisible(showFullscreen: true)
            && !singleWindow.isVisible(showFullscreen: false) && !emptyLayout.isVisible(showFullscreen: true)
            && !space(52, .tile).isVisible(showFullscreen: true)
            && !space(54, .unknown).isVisible(showFullscreen: true)
        let before: Set<UInt64> = [10]
        let compositionPasses = MissionControlSpaceSwitcher.compositionConfirmed(targetIDs: [10], sourceIDs: [20], onScreenIDs: [10])
            && !MissionControlSpaceSwitcher.compositionConfirmed(targetIDs: [10], sourceIDs: [20], onScreenIDs: [10, 20])
            && !MissionControlSpaceSwitcher.compositionConfirmed(targetIDs: [10], sourceIDs: [20], onScreenIDs: [])
            && !MissionControlSpaceSwitcher.compositionConfirmed(targetIDs: [], sourceIDs: [], onScreenIDs: [])
            && MissionControlSpaceSwitcher.compositionConfirmed(targetIDs: [10], sourceIDs: [10], onScreenIDs: [10])
            && !MissionControlSpaceSwitcher.compositionConfirmed(targetIDs: [10], sourceIDs: [10], onScreenIDs: [10], fullscreenSource: true)
            && !MissionControlSpaceSwitcher.compositionConfirmed(targetIDs: [10, 20], sourceIDs: [10], onScreenIDs: [10, 20], fullscreenSource: true)
            && MissionControlSpaceSwitcher.compositionConfirmed(targetIDs: [10, 20], sourceIDs: [10], onScreenIDs: [20], fullscreenSource: true)
            && !MissionControlSpaceSwitcher.requiresComposition(source: .desktop, target: .desktop)
            && MissionControlSpaceSwitcher.requiresComposition(source: .fullScreenApp, target: .desktop)
            && MissionControlSpaceSwitcher.requiresComposition(source: .tiledLayout, target: .desktop)
            && MissionControlSpaceSwitcher.requiresComposition(source: nil, target: .desktop)
        let creationMappingPasses = MissionControlSpaceSwitcher.newDesktopID(
            before: before, after: [space(10, .desktop), space(11, .desktop)]
        ) == 11
            && MissionControlSpaceSwitcher.newDesktopID(before: before, after: [space(10, .desktop)]) == nil
            && MissionControlSpaceSwitcher.newDesktopID(before: before, after: [space(10, .desktop), space(11, .fullScreenApp)]) == nil
            && MissionControlSpaceSwitcher.newDesktopID(before: before, after: [space(10, .desktop), space(11, .desktop), space(12, .desktop)]) == nil
        let layout = TileStripLayout(tileSize: NSSize(width: 64, height: 36), gap: 6, padding: 6, closeSize: 20)
        let geometryPasses = layout.width(forTileCount: 3) == 268
            && layout.height() == 48
            && layout.tileIndex(at: NSPoint(x: 7, y: 7), tileCount: 3) == 0
            && layout.tileIndex(at: NSPoint(x: 72, y: 24), tileCount: 3) == nil
            && layout.tileIndex(at: NSPoint(x: 78, y: 24), tileCount: 3) == 1
            && layout.addRect(tileCount: 3).contains(NSPoint(x: 226, y: 24))
            && layout.closeRect(tileCount: 3).contains(NSPoint(x: 252, y: 24))
            && OverlayController.usableFrame(screenFrame: NSRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 800), menuHeight: 24, safeTop: 32).maxY == 768
            && OverlayController.usableFrame(screenFrame: NSRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 750), menuHeight: 24, safeTop: 0).maxY == 750
        let view = TileStripView(frame: NSRect(x: 0, y: 0, width: 268, height: 48))
        view.layout = layout
        view.tiles = [space(10, .desktop), space(11, .desktop), space(12, .desktop)].map {
            SpaceTile(space: $0, window: nil, image: nil, isCurrent: false)
        }
        var adds = 0
        view.onAdd = { adds += 1 }
        for count in 1...2 {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 226, y: 24),
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: count, clickCount: count, pressure: 1) {
                    if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
                }
            }
        }
        let addClickPasses = adds == 1
        let captureSourcePasses = ThumbnailService.source(
            hasScreenRecordingAccess: true,
            windowID: 123,
            windowOwnerPID: 20,
            spaceOwnerPID: 30,
            fallbackPID: 40
        ) == .capture(123)
            && ThumbnailService.source(
                hasScreenRecordingAccess: false,
                windowID: 123,
                windowOwnerPID: 20,
                spaceOwnerPID: 30,
                fallbackPID: 40
            ) == .icon(20)
            && ThumbnailService.source(
                hasScreenRecordingAccess: true,
                windowID: nil,
                windowOwnerPID: nil,
                spaceOwnerPID: 30,
                fallbackPID: 40
            ) == .icon(30)
            && ThumbnailService.source(
                hasScreenRecordingAccess: false,
                windowID: nil,
                windowOwnerPID: nil,
                spaceOwnerPID: nil,
                fallbackPID: nil
            ) == .empty

        print("switch gate: \(gatePasses ? "PASS" : "FAIL")")
        print("hover timing and suppression: \(hoverPasses && suppressionPasses && resetPasses ? "PASS" : "FAIL")")
        print("AX button mapping: \(mappingPasses ? "PASS" : "FAIL")")
        print("fullscreen visibility and same-app Spaces: \(visibilityPasses ? "PASS" : "FAIL")")
        print("new desktop identification: \(creationMappingPasses ? "PASS" : "FAIL")")
        print("composition evidence: \(compositionPasses ? "PASS" : "FAIL")")
        print("shortcut routing and binding validation: \(shortcutPasses ? "PASS" : "FAIL")")
        print("switching mode selection: \(modePasses ? "PASS" : "FAIL")")
        print("tile geometry: \(geometryPasses ? "PASS" : "FAIL")")
        print("add double-click: \(addClickPasses ? "PASS" : "FAIL")")
        print("snapshot permission and fallback: \(captureSourcePasses ? "PASS" : "FAIL")")
        print("live Mission Control switching is not run by --selftest")
        return gatePasses && hoverPasses && suppressionPasses && resetPasses && mappingPasses && visibilityPasses && creationMappingPasses && compositionPasses && shortcutPasses && modePasses && geometryPasses && addClickPasses && captureSourcePasses
    }

    /// Writes the menu bar icon to a PNG so it can be looked at.
    @MainActor
    static func dumpIcon() {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let image = MenuBarIcon.image(pointSize: 34) else {
            print("no icon")
            return
        }
        print("icon size: \(image.size) template=\(image.isTemplate)")
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            if let context = CGContext(
                data: &pixels,
                width: cg.width,
                height: cg.height,
                bitsPerComponent: 8,
                bytesPerRow: cg.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                func alpha(_ x: Int, _ y: Int) -> UInt8 {
                    let row = cg.height - 1 - y
                    return pixels[(row * cg.width + x) * 4 + 3]
                }
                print("alpha samples: top-left=\(alpha(10, 10)) centre=\(alpha(cg.width / 2, cg.height / 2)) bottom-right=\(alpha(cg.width - 10, cg.height - 10))")
            }
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: "/tmp/spacestrip_icon.png"))
        print("wrote /tmp/spacestrip_icon.png")
    }
}
