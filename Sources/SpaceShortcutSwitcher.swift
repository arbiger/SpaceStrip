import AppKit
import ApplicationServices
import Foundation

@MainActor
enum SpaceShortcutSwitcher {
    static let waitOptions = [150, 300, 450, 650]
    nonisolated static let defaultWait = 150

    static func storedWait(_ value: Any?) -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              let wait = value as? Int, waitOptions.contains(wait) else { return defaultWait }
        return wait
    }
    struct Binding: Equatable {
        let keyCode: UInt16
        let flags: UInt64

        init?(_ entry: [String: Any]?) {
            guard let entry, (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any], value["type"] as? String == "standard",
                  let parameters = value["parameters"] as? [NSNumber], parameters.count == 3 else { return nil }
            let code = parameters[1].int64Value
            let raw = parameters[2].int64Value
            let allowed: UInt64 = 0x00fe0000 // Caps Lock, Shift, Control, Option, Command, numeric pad, Help, Fn
            guard (0...127).contains(code), raw >= 0, UInt64(raw) & ~allowed == 0 else { return nil }
            keyCode = UInt16(code)
            flags = UInt64(raw)
        }
    }

    static func route(spaces: [VirtualSpace], source: UInt64, target: UInt64) -> [UInt64]? {
        let all = spaces.map(\.id)
        guard Set(all).count == all.count,
              let start = all.firstIndex(of: source), let end = all.firstIndex(of: target), start != end,
              spaces[min(start, end)...max(start, end)].allSatisfy(\.isSelectable) else { return nil }
        let step = start < end ? 1 : -1
        return stride(from: start + step, through: end, by: step).map { all[$0] }
    }

    static func binding(left: Bool) -> Binding? {
        guard let settings = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any] else { return nil }
        return Binding(settings[left ? "79" : "81"] as? [String: Any])
    }

    static func switchTo(target: UInt64, display: ManagedDisplay, source: UInt64, waitMilliseconds: Int) async -> SpaceSwitchResult {
        guard CGPreflightPostEventAccess() else {
            return .failed("Input event posting is not permitted. Enable SpaceStrip in Privacy & Security → Accessibility, then reopen it.")
        }
        guard let steps = route(spaces: display.spaces, source: source, target: target),
              let sourceIndex = display.spaces.firstIndex(where: { $0.id == source }),
              let targetIndex = display.spaces.firstIndex(where: { $0.id == target }) else {
            return .failed("The Space order is ambiguous or changed. Refresh and try again.")
        }
        let left = targetIndex < sourceIndex
        guard let shortcut = binding(left: left) else {
            return .failed("The required Move left/right a Space shortcut is missing, disabled, or unsupported. Check Keyboard Shortcuts in System Settings.")
        }
        let original = display.spaces.map(\.id)
        let selectable = display.spaces.map(\.isSelectable)
        var current = source
        for next in steps {
            guard let before = SpaceAPI.managedDisplays().first(where: { $0.identifier == display.identifier }),
                  before.spaces.map(\.id) == original, before.spaces.map(\.isSelectable) == selectable, before.currentSpaceID == current,
                  SpaceAPI.activeSpaceID() == current, binding(left: left) == shortcut else {
                return .failed("Space order, current Space, or shortcut changed; switching stopped.")
            }
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: false) else {
                return .failed("Could not create the configured keyboard shortcut events.")
            }
            down.flags = CGEventFlags(rawValue: shortcut.flags)
            up.flags = CGEventFlags(rawValue: shortcut.flags)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)

            let deadline = ProcessInfo.processInfo.systemUptime + 3
            var stableSince: TimeInterval?
            var confirmed = false
            var reachedNext = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                guard let observed = SpaceAPI.managedDisplays().first(where: { $0.identifier == display.identifier }),
                      observed.spaces.map(\.id) == original, observed.spaces.map(\.isSelectable) == selectable,
                      binding(left: left) == shortcut else {
                    return .failed("Space order or shortcut changed; switching stopped.")
                }
                let active = SpaceAPI.activeSpaceID()
                guard (active == current || active == next),
                      (observed.currentSpaceID == current || observed.currentSpaceID == next) else {
                    return .failed("An unexpected Space became active; switching stopped.")
                }
                if active == next && observed.currentSpaceID == next {
                    reachedNext = true
                    let now = ProcessInfo.processInfo.systemUptime
                    if let since = stableSince, now - since >= Double(waitMilliseconds) / 1000 { confirmed = true; break }
                    if stableSince == nil { stableSince = now }
                } else {
                    if reachedNext { return .failed("The Space returned after changing; switching stopped.") }
                    stableSince = nil
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            guard confirmed else { return .failed("The expected adjacent Space was not confirmed; switching stopped.") }
            current = next
        }
        return .switched
    }
}
