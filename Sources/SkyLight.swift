import Foundation

/// macOS has no public API for virtual desktops (Spaces). The window server
/// exposes them through SkyLight.framework, which is what Dock, Mission
/// Control and other space managers use internally.
///
/// Every entry point is resolved lazily with dlsym so that a future macOS
/// that renames or removes one of them degrades to a disabled feature instead
/// of crashing the app.
enum SkyLight {
    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY
    )

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        return dlsym(handle, name)
    }

    static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let symbol = symbol(name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    /// True when the space APIs this app needs are all present.
    static var isSupported: Bool {
        for name in [
            "CGSMainConnectionID",
            "CGSCopyManagedDisplaySpaces",
        ] where symbol(name) == nil {
            return false
        }
        return true
    }
}
