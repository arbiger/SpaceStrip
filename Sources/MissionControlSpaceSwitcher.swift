import AppKit
import ApplicationServices
import ColorSync
import CoreGraphics
import Foundation

enum SpaceSwitchResult: Equatable {
    case switched
    case alreadyCurrent
    case accessibilityRequired
    case failed(String)
}

/// Selects the Mission Control button for a Space. Setting a private Space ID
/// directly skips the window server's tile-layout transition, which leaves
/// fullscreen windows composited over the desktop.
@MainActor
final class MissionControlSpaceSwitcher {
    private typealias CoreDockSendNotification = @convention(c) (CFString, Int32) -> Int32

    private let windowManagerBundleID = "com.apple.WindowManager"
    private let missionControlIdentifier = "mc.display"
    private let spacesListIdentifier = "mc.spaces.list"
    private let addSpaceIdentifier = "mc.spaces.add"

    private var hiservices: UnsafeMutableRawPointer? {
        dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
            RTLD_LAZY
        )
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func spaceIndex(spaceID: UInt64, orderedIDs: [UInt64]) -> Int? {
        orderedIDs.firstIndex(of: spaceID)
    }

    static func buttonIndex(spaceID: UInt64, orderedIDs: [UInt64], buttonCount: Int) -> Int? {
        guard orderedIDs.count == buttonCount else { return nil }
        return spaceIndex(spaceID: spaceID, orderedIDs: orderedIDs)
    }

    static func newDesktopID(before: Set<UInt64>, after: [VirtualSpace]) -> UInt64? {
        let added = after.filter { !before.contains($0.id) }
        guard added.count == 1, added[0].kind == .desktop else { return nil }
        return added[0].id
    }

    func addDesktop(displayID: String) async -> SpaceSwitchResult {
        guard AXIsProcessTrusted() else { return .accessibilityRequired }
        guard let screen = screen(for: displayID),
              SpaceAPI.managedDisplays().contains(where: { $0.identifier == displayID }) else {
            return .failed("SpaceStrip could not match this display to Mission Control.")
        }
        var openedMissionControl = false
        do {
            if missionControlDisplay(screen: screen) == nil {
                try toggleMissionControl()
                openedMissionControl = true
            }
            let deadline = Date().addingTimeInterval(3)
            var addButton: AXUIElement?
            while Date() < deadline {
                if let display = missionControlDisplay(screen: screen),
                   let button = findElement(withIdentifier: addSpaceIdentifier, under: display) {
                    addButton = button
                    break
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            guard let addButton else { throw SwitchError.addUnavailable }
            guard let beforeDisplay = SpaceAPI.managedDisplays().first(where: { $0.identifier == displayID }),
                  !beforeDisplay.spaces.isEmpty else { throw SwitchError.mappingChanged }
            let before = Set(beforeDisplay.spaces.map(\.id))
            let actionError = AXUIElementPerformAction(addButton, kAXPressAction as CFString)
            guard actionError == .success || actionError == .cannotComplete else {
                throw SwitchError.addPressFailed(Int32(actionError.rawValue))
            }

            let creationDeadline = Date().addingTimeInterval(3)
            while Date() < creationDeadline {
                guard let display = SpaceAPI.managedDisplays().first(where: { $0.identifier == displayID }) else {
                    throw SwitchError.addUnconfirmed
                }
                let added = display.spaces.filter { !before.contains($0.id) }
                if !added.isEmpty {
                    guard let id = Self.newDesktopID(before: before, after: display.spaces) else {
                        throw SwitchError.addUnconfirmed
                    }
                    let result = await switchTo(spaceID: id, displayID: displayID)
                    if result == .alreadyCurrent, missionControlDisplay(screen: screen) != nil {
                        try toggleMissionControl()
                        await waitForMissionControlToClose(displayID: displayID, screen: screen)
                        if missionControlDisplay(screen: screen) != nil {
                            throw SwitchError.addedButNotSelected("The new desktop is current, but Mission Control stayed open.")
                        }
                    }
                    if case .failed(let message) = result {
                        throw SwitchError.addedButNotSelected(message)
                    }
                    if case .accessibilityRequired = result {
                        throw SwitchError.addedButNotSelected("Accessibility permission is unavailable.")
                    }
                    return result
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            throw SwitchError.addUnconfirmed
        } catch {
            if openedMissionControl, missionControlDisplay(screen: screen) != nil {
                try? toggleMissionControl()
            }
            return .failed(error.localizedDescription)
        }
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func switchTo(spaceID: UInt64, displayID: String) async -> SpaceSwitchResult {
        guard AXIsProcessTrusted() else { return .accessibilityRequired }
        guard let initialDisplay = SpaceAPI.managedDisplays().first(where: { $0.identifier == displayID }),
              initialDisplay.spaces.contains(where: { $0.id == spaceID && $0.kind == .desktop }) else {
            return .failed("That desktop is no longer available. Refresh the strip and try again.")
        }
        guard SpaceAPI.activeSpaceID() != spaceID else { return .alreadyCurrent }
        guard let screen = screen(for: initialDisplay.identifier) else {
            return .failed("SpaceStrip could not match this display to Mission Control.")
        }

        var openedMissionControl = false
        do {
            if missionControlDisplay(screen: screen) == nil {
                try toggleMissionControl()
                openedMissionControl = true
            }

            guard let list = await waitForSpaceList(displayID: displayID, screen: screen) else {
                throw SwitchError.missionControlUnavailable
            }

            // Re-read the order after Mission Control opens. The AX button order
            // must match this fresh display snapshot or the click is ambiguous.
            guard let freshDisplay = SpaceAPI.managedDisplays().first(where: { $0.identifier == displayID }) else {
                throw SwitchError.spaceDisappeared
            }
            guard freshDisplay.spaces.contains(where: { $0.id == spaceID && $0.kind == .desktop }) else {
                throw SwitchError.spaceDisappeared
            }
            let freshIDs = freshDisplay.spaces.map(\.id)
            guard let freshIndex = Self.buttonIndex(
                spaceID: spaceID,
                orderedIDs: freshIDs,
                buttonCount: list.buttons.count
            ) else { throw SwitchError.mappingChanged }
            let actionError = AXUIElementPerformAction(list.buttons[freshIndex], kAXPressAction as CFString)
            // Mission Control may return cannotComplete while it is animating.
            // The active Space readback below determines whether the press took.
            if actionError != .success && actionError != .cannotComplete {
                throw SwitchError.pressFailed(Int32(actionError.rawValue))
            }

            guard await waitForActiveSpace(spaceID, timeout: 3.0) else {
                throw SwitchError.switchTimedOut
            }

            await waitForMissionControlToClose(displayID: displayID, screen: screen)
            if missionControlDisplay(screen: screen) != nil {
                try? toggleMissionControl()
                await waitForMissionControlToClose(displayID: displayID, screen: screen)
            }
            if missionControlDisplay(screen: screen) != nil {
                throw SwitchError.missionControlDidNotClose
            }

            return .switched
        } catch {
            if openedMissionControl, SpaceAPI.activeSpaceID() != spaceID {
                try? toggleMissionControl()
            }
            return .failed(error.localizedDescription)
        }
    }

    private func waitForSpaceList(displayID: String, screen: NSScreen) async -> SpaceList? {
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if let list = spaceList(displayID: displayID, screen: screen),
               let display = SpaceAPI.managedDisplays().first(where: { $0.identifier == displayID }),
               list.buttons.count == display.spaces.count {
                return list
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return nil
    }

    private func waitForMissionControlToClose(displayID: String, screen: NSScreen) async {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, missionControlDisplay(screen: screen) != nil {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    private func waitForActiveSpace(_ targetID: UInt64, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if SpaceAPI.activeSpaceID() == targetID { return true }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        return false
    }

    private struct SpaceList {
        let buttons: [AXUIElement]
    }

    private func missionControlDisplay(screen: NSScreen) -> AXUIElement? {
        guard let process = NSRunningApplication.runningApplications(
            withBundleIdentifier: windowManagerBundleID
        ).first else { return nil }

        let application = AXUIElementCreateApplication(process.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(application, 1.0)
        guard let display = findElement(withIdentifier: missionControlIdentifier, under: application),
              matches(display, screen: screen) else { return nil }
        return display
    }

    private func spaceList(displayID: String, screen: NSScreen) -> SpaceList? {
        guard let display = missionControlDisplay(screen: screen),
              let list = findElement(withIdentifier: spacesListIdentifier, under: display),
              let children = children(of: list) else { return nil }

        let buttons = children.filter { role(of: $0) == (kAXButtonRole as String) }
        guard !buttons.isEmpty else { return nil }
        return SpaceList(buttons: buttons)
    }

    private func screen(for displayIdentifier: String) -> NSScreen? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  let uuidString = CFUUIDCreateString(kCFAllocatorDefault, uuid) else { continue }
            if (uuidString as String).caseInsensitiveCompare(displayIdentifier) == .orderedSame {
                return screen
            }
        }

        // Some macOS builds identify the primary display as "Main" instead
        // of its UUID. Only use this fallback when the target is unambiguous.
        if displayIdentifier == "Main", NSScreen.screens.count == 1 {
            return NSScreen.screens.first
        }
        return nil
    }

    private func matches(_ element: AXUIElement, screen: NSScreen) -> Bool {
        if let displayValue = attribute(element, "AXDisplayID") as? NSNumber,
           let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            if displayValue.uint32Value == screenNumber.uint32Value { return true }
        }

        guard let positionRaw = attribute(element, kAXPositionAttribute as String),
              let sizeRaw = attribute(element, kAXSizeAttribute as String) else { return false }
        let positionValue = unsafeBitCast(positionRaw, to: AXValue.self)
        let sizeValue = unsafeBitCast(sizeRaw, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return false }
        let frame = CGRect(origin: position, size: size)
        return abs(frame.minX - screen.frame.minX) < 2
            && abs(frame.minY - screen.frame.minY) < 2
            && abs(frame.width - screen.frame.width) < 2
            && abs(frame.height - screen.frame.height) < 2
    }

    private func findElement(withIdentifier identifier: String, under root: AXUIElement) -> AXUIElement? {
        var visited = 0
        return findElement(withIdentifier: identifier, under: root, depth: 0, visited: &visited)
    }

    private func findElement(
        withIdentifier identifier: String,
        under element: AXUIElement,
        depth: Int,
        visited: inout Int
    ) -> AXUIElement? {
        guard depth <= 8, visited < 2_000 else { return nil }
        visited += 1

        if (attribute(element, kAXIdentifierAttribute as String) as? String) == identifier {
            return element
        }
        for child in children(of: element) ?? [] {
            if let found = findElement(
                withIdentifier: identifier,
                under: child,
                depth: depth + 1,
                visited: &visited
            ) {
                return found
            }
        }
        return nil
    }

    private func children(of element: AXUIElement) -> [AXUIElement]? {
        attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]
    }

    private func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute as String) as? String
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func toggleMissionControl() throws {
        // Ask Dock to open/close the native overview; never synthesize a keyboard gesture.
        guard let handle = hiservices,
              let pointer = dlsym(handle, "CoreDockSendNotification") else {
            throw SwitchError.missionControlUnavailable
        }
        let send = unsafeBitCast(pointer, to: CoreDockSendNotification.self)
        let error = send("com.apple.expose.awake" as CFString, 0)
        guard error == 0 else { throw SwitchError.missionControlToggleFailed(error) }
    }

    private enum SwitchError: LocalizedError {
        case missionControlUnavailable
        case spaceDisappeared
        case mappingChanged
        case pressFailed(Int32)
        case missionControlToggleFailed(Int32)
        case switchTimedOut
        case missionControlDidNotClose
        case addUnavailable
        case addPressFailed(Int32)
        case addUnconfirmed
        case addedButNotSelected(String)

        var errorDescription: String? {
            switch self {
            case .missionControlUnavailable:
                return "Mission Control's Space controls are unavailable. Check SpaceStrip's Accessibility permission."
            case .spaceDisappeared:
                return "That desktop disappeared before Mission Control could select it."
            case .mappingChanged:
                return "Mission Control's Space list changed. Refresh the strip and try again."
            case let .pressFailed(code):
                return "Mission Control could not select that desktop (Accessibility error \(code))."
            case let .missionControlToggleFailed(code):
                return "macOS could not open Mission Control (error \(code))."
            case .switchTimedOut:
                return "Mission Control did not switch to the selected desktop."
            case .missionControlDidNotClose:
                return "The Space changed, but Mission Control stayed open. Close it and try again."
            case .addUnavailable:
                return "Mission Control's Add Desktop control is unavailable. Check Accessibility permission and desktop limits."
            case let .addPressFailed(code):
                return "Mission Control could not add a desktop (Accessibility error \(code)). Check Mission Control before retrying."
            case .addUnconfirmed:
                return "Desktop creation could not be confirmed uniquely. Check Mission Control before retrying."
            case let .addedButNotSelected(message):
                return "A desktop was added but could not be selected: \(message)"
            }
        }
    }
}
