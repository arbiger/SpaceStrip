import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum PreviewSource: Equatable {
    case capture(CGWindowID)
    case icon(pid_t)
    case empty
}

/// Captures the actual representative app window for each Space. A wallpaper
/// image is never treated as a successful app preview.
@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()

    private struct RequestKey: Hashable {
        let spaceID: UInt64
        let windowID: CGWindowID
    }

    private struct CachedThumbnail {
        let windowID: CGWindowID
        let image: NSImage
    }

    private var cache: [UInt64: CachedThumbnail] = [:]
    private var capturedAt: [RequestKey: Date] = [:]
    private var inFlight: Set<RequestKey> = []
    private var desiredWindowBySpace: [UInt64: CGWindowID] = [:]
    private var icons: [pid_t: NSImage] = [:]
    private var shareableContent: SCShareableContent?
    private var shareableContentFetchedAt = Date.distantPast

    private(set) var lastError: String?

    var hasScreenRecordingAccess: Bool { CGPreflightScreenCaptureAccess() }

    static func source(
        hasScreenRecordingAccess: Bool,
        windowID: CGWindowID?,
        windowOwnerPID: pid_t?,
        spaceOwnerPID: pid_t?,
        fallbackPID: pid_t?
    ) -> PreviewSource {
        if hasScreenRecordingAccess, let windowID { return .capture(windowID) }
        if let windowOwnerPID { return .icon(windowOwnerPID) }
        if let spaceOwnerPID { return .icon(spaceOwnerPID) }
        if let fallbackPID { return .icon(fallbackPID) }
        return .empty
    }

    func cachedImage(forSpace spaceID: UInt64, windowID: CGWindowID) -> NSImage? {
        guard let cached = cache[spaceID], cached.windowID == windowID else { return nil }
        return cached.image
    }

    func icon(for pid: pid_t) -> NSImage? {
        if let cached = icons[pid] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        icons[pid] = icon
        return icon
    }

    func requestImage(
        forSpace spaceID: UInt64,
        windowID: CGWindowID,
        size: CGSize,
        maxAge: TimeInterval,
        onReady: @escaping () -> Void
    ) {
        guard hasScreenRecordingAccess else {
            lastError = "Screen Recording permission is required for desktop previews."
            cache.removeValue(forKey: spaceID)
            return
        }
        desiredWindowBySpace[spaceID] = windowID

        let key = RequestKey(spaceID: spaceID, windowID: windowID)
        if let captured = capturedAt[key], Date().timeIntervalSince(captured) < maxAge { return }
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)

        Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight.remove(key) }

            do {
                let content = try await self.currentShareableContent()
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    throw CaptureError.windowUnavailable
                }

                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                configuration.width = max(Int(size.width * 2), 1)
                configuration.height = max(Int(size.height * 2), 1)
                configuration.showsCursor = false
                configuration.scalesToFit = true

                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                guard self.desiredWindowBySpace[spaceID] == windowID else { return }
                self.cache[spaceID] = CachedThumbnail(
                    windowID: windowID,
                    image: Self.thumbnail(from: cgImage, size: size)
                )
                self.capturedAt[key] = Date()
                self.lastError = nil
                Debug.log("preview captured: space=\(spaceID) window=\(windowID)")
            } catch {
                guard self.desiredWindowBySpace[spaceID] == windowID else { return }
                // An inactive fullscreen window may temporarily refuse capture.
                // Keep its last real frame until a fresh capture succeeds.
                self.capturedAt[key] = Date()
                self.lastError = Self.describe(error)
                Debug.log("preview failed: space=\(spaceID) window=\(windowID): \(Self.describe(error))")
            }

            onReady()
        }
    }

    func invalidate(spaceID: UInt64) {
        cache.removeValue(forKey: spaceID)
        capturedAt = capturedAt.filter { $0.key.spaceID != spaceID }
        shareableContent = nil
        shareableContentFetchedAt = .distantPast
    }

    func invalidate() {
        cache.removeAll()
        capturedAt.removeAll()
    }

    private func currentShareableContent() async throws -> SCShareableContent {
        if let shareableContent, Date().timeIntervalSince(shareableContentFetchedAt) < 3 {
            return shareableContent
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        shareableContent = content
        shareableContentFetchedAt = Date()
        return content
    }

    private static func thumbnail(from image: CGImage, size: CGSize) -> NSImage {
        let width = max(Int(size.width * 2), 1)
        let height = max(Int(size.height * 2), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return NSImage(cgImage: image, size: size) }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().map { NSImage(cgImage: $0, size: size) }
            ?? NSImage(cgImage: image, size: size)
    }

    private static func describe(_ error: Error) -> String {
        if case CaptureError.windowUnavailable = error {
            return "The app window for this desktop is not available to ScreenCaptureKit."
        }
        return error.localizedDescription
    }

    private enum CaptureError: Error {
        case windowUnavailable
    }
}
