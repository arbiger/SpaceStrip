import AppKit
import CoreGraphics
import Foundation

struct WindowInfo {
    let id: CGWindowID
    let ownerName: String
    let ownerPID: pid_t
    let title: String?
    let bounds: CGRect
    let isOnScreen: Bool
    let layer: Int
    let spaceIDs: Set<UInt64>

    /// Windows that could stand in for a desktop: real app windows, not
    /// menu bar extras, panels or the wallpaper.
    var isTileCandidate: Bool {
        guard layer == 0 else { return false }
        guard bounds.width >= 160, bounds.height >= 110 else { return false }
        return !WindowCatalog.systemOwners.contains(ownerName)
    }
}

enum WindowCatalog {
    static let systemOwners: Set<String> = [
        "Window Server", "WindowManager", "Dock", "MenuBarAgent", "loginwindow",
        "Notification Center", "Siri", "Control Center", "Spotlight",
        "SystemUIServer", "Universal Control", "TextInputSwitcher",
        "AirPlayUIAgent", "Wallpaper", "Screen Sharing", "coreaudiod",
        "AutoFill", "Open and Save Panel Service", "CursorUIViewService",
    ]

    /// Every window the window server knows about, grouped by the space it lives on.
    static func windowsBySpace() -> [UInt64: [WindowInfo]] {
        var grouped: [UInt64: [WindowInfo]] = [:]
        for window in allWindows() {
            for spaceID in window.spaceIDs {
                grouped[spaceID, default: []].append(window)
            }
        }
        return grouped
    }

    static func allWindows() -> [WindowInfo] {
        let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return raw.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID else { return nil }
            let boundsDict = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let bounds = CGRect(
                x: boundsDict["X"] as? CGFloat ?? 0,
                y: boundsDict["Y"] as? CGFloat ?? 0,
                width: boundsDict["Width"] as? CGFloat ?? 0,
                height: boundsDict["Height"] as? CGFloat ?? 0
            )
            return WindowInfo(
                id: id,
                ownerName: entry[kCGWindowOwnerName as String] as? String ?? "?",
                ownerPID: entry[kCGWindowOwnerPID as String] as? pid_t ?? -1,
                title: entry[kCGWindowName as String] as? String,
                bounds: bounds,
                isOnScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false,
                layer: entry[kCGWindowLayer as String] as? Int ?? -1,
                spaceIDs: SpaceAPI.spaceIDs(forWindow: id)
            )
        }
    }

    /// The window that best represents a space: a full screen window if there
    /// is one, otherwise the largest ordinary window on that space.
    static func representativeWindow(
        in windows: [WindowInfo],
        screenBounds: CGRect
    ) -> WindowInfo? {
        let candidates = windows.filter { $0.isTileCandidate }
        guard !candidates.isEmpty else { return nil }

        if let fullScreen = candidates.first(where: { window in
            window.bounds.width >= screenBounds.width * 0.9 && window.bounds.height >= screenBounds.height * 0.85
        }) {
            return fullScreen
        }

        return candidates.max { lhs, rhs in
            lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
        }
    }

}
