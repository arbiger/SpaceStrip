import Foundation

/// Logging to stderr, enabled with SPACESTRIP_LOG=1.
enum Debug {
    static let enabled = ProcessInfo.processInfo.environment["SPACESTRIP_LOG"] == "1"

    static func log(_ message: String) {
        guard enabled else { return }
        let line = "[SpaceStrip] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
