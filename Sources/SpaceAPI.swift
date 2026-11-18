import AppKit
import CoreGraphics
import Foundation

typealias CGSMainConnectionIDFn = @convention(c) () -> Int32
typealias CGSCopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias SLSGetActiveSpaceFn = @convention(c) (Int32) -> UInt64
typealias SLSWindowGetBestSpaceFn = @convention(c) (UInt32, UInt32) -> UInt64

/// A single virtual desktop.
struct VirtualSpace: Hashable {
    enum Kind: Int {
        case desktop = 0
        case fullScreenApp = 3
        case tiledLayout = 4
        case tile = 5
        case wall = 6
        case unknown = -1
    }

    let id: UInt64
    let kind: Kind
    /// The app that owns the desktop, when macOS tells us.
    let ownerPID: pid_t?
    /// Window IDs reported by the tiled layout manager, if this is a tile.
    let windowIDs: [CGWindowID]

    var isTiledLayout: Bool { kind == .tiledLayout }
}

/// A display and the spaces that live on it, in Mission Control order.
struct ManagedDisplay {
    let identifier: String
    let spaces: [VirtualSpace]
    let currentSpaceID: UInt64
}

enum SpaceAPI {
    static var connection: Int32 {
        SkyLight.function("CGSMainConnectionID", as: CGSMainConnectionIDFn.self)?() ?? 0
    }

    /// All displays with their spaces, in the order Mission Control shows them.
    static func managedDisplays() -> [ManagedDisplay] {
        guard let copy = SkyLight.function(
            "CGSCopyManagedDisplaySpaces", as: CGSCopyManagedDisplaySpacesFn.self
        ) else { return [] }

        guard let raw = copy(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }

        return raw.compactMap { entry -> ManagedDisplay? in
            guard let identifier = entry["Display Identifier"] as? String else { return nil }

            let spaces = (entry["Spaces"] as? [[String: Any]] ?? []).compactMap { space -> VirtualSpace? in
                guard let id = number(space["ManagedSpaceID"]) else { return nil }
                let type = number(space["type"]).flatMap(Int.init(exactly:)) ?? -1
                let owner = (space["pid"] as? NSNumber)?.int32Value
                let layout = space["TileLayoutManager"] as? [String: Any]
                let tileSpaces = layout?["TileSpaces"] as? [[String: Any]] ?? []
                let tileWindowIDs = tileSpaces.compactMap { tile -> CGWindowID? in
                    guard let id = number(tile["TileWindowID"]) else { return nil }
                    return UInt32(exactly: id)
                }
                let fullscreenWindowIDs = number(space["fs_wid"])
                    .flatMap { UInt32(exactly: $0) }
                    .map { [$0] } ?? []
                var seenWindowIDs: Set<CGWindowID> = []
                let windowIDs = (tileWindowIDs + fullscreenWindowIDs).filter {
                    $0 != 0 && seenWindowIDs.insert($0).inserted
                }
                return VirtualSpace(
                    id: id,
                    kind: VirtualSpace.Kind(rawValue: type) ?? .unknown,
                    ownerPID: owner,
                    windowIDs: windowIDs
                )
            }

            let current = (entry["Current Space"] as? [String: Any])
                .flatMap { number($0["ManagedSpaceID"]) } ?? 0

            return ManagedDisplay(identifier: identifier, spaces: spaces, currentSpaceID: current)
        }
    }

    /// The space that is on screen right now.
    static func activeSpaceID() -> UInt64 {
        if let get = SkyLight.function("SLSGetActiveSpace", as: SLSGetActiveSpaceFn.self) {
            return get(connection)
        }
        return managedDisplays().first?.currentSpaceID ?? 0
    }

    /// The Finder, which owns the desktop space.
    static var finderPID: pid_t? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder"
        ).first?.processIdentifier
    }

    /// Every space a window belongs to.
    ///
    /// The window server reports up to four spaces per window: slot 0 is the
    /// space that is on screen right now, the next slots hold the spaces the
    /// window actually lives on.
    static func spaceIDs(forWindow windowID: CGWindowID) -> Set<UInt64> {
        guard let get = SkyLight.function("SLSWindowGetBestSpace", as: SLSWindowGetBestSpaceFn.self) else { return [] }
        var spaces: Set<UInt64> = []
        for index in 0..<4 {
            let space = get(windowID, UInt32(index))
            if space != 0 { spaces.insert(space) }
        }
        return spaces
    }

    private static func number(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let value = value as? Int { return UInt64(value) }
        if let value = value as? UInt64 { return value }
        return nil
    }
}
