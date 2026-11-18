import AppKit
import CoreGraphics
import Foundation
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var loginItem: NSMenuItem?
    private var accessibilityItem: NSMenuItem?
    private var switchStatusItem: NSMenuItem?
    private var screenRecordingItem: NSMenuItem?
    private var previewStatusItem: NSMenuItem?
    private var screenshotStyleItem: NSMenuItem?
    private var iconStyleItem: NSMenuItem?
    private var menu: NSMenu!
    private var rightClickMonitor: Any?
    private var pollTimer: Timer?
    private var tiles: [SpaceTile] = []
    private var displayIdentifier: String?
    private var showsThumbnails = UserDefaults.standard.object(forKey: "showScreenshots") as? Bool ?? false
    private var scannedWindows: [UInt64: [WindowInfo]] = [:]
    private var lastWindowScan = Date.distantPast
    private var lastObservedActiveSpaceID: UInt64?
    private var switchGate = SpaceSwitchGate()
    private let missionControlSwitcher = MissionControlSpaceSwitcher()
    private var overlay: OverlayController!
    private var overlayItem: NSMenuItem?

    /// The menu bar has room for small tiles, the floating panel for large ones.
    private let overlayLayout = TileStripLayout(
        tileSize: NSSize(width: 64, height: 36),
        gap: 6,
        padding: 6,
        closeSize: 20
    )

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Debug.log("didFinishLaunching")
        Debug.log("screen capture allowed: \(CGPreflightScreenCaptureAccess())")
        Debug.log("accessibility allowed: \(MissionControlSpaceSwitcher.isAccessibilityTrusted)")
        guard SkyLight.isSupported else {
            NSLog("SpaceStrip: the Space APIs are not available on this macOS version.")
            return
        }
        setUpStatusItem()
        setUpOverlay()
        refresh()
        schedulePoll()
        observeWorkspace()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        Debug.log("status item created, button=\(button)")
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.imagePosition = .imageOnly
        button.image = MenuBarIcon.image()
        button.toolTip = "SpaceStrip - click to show or hide the desktop strip"

        menu = NSMenu()
        let header = NSMenuItem(title: "SpaceStrip", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let appearanceItem = NSMenuItem(title: "Tile appearance", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu()
        for (title, tag) in [("Screenshots", 1), ("App icons", 0)] {
            let item = NSMenuItem(title: title, action: #selector(selectTileAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = showsThumbnails == (tag == 1) ? .on : .off
            appearanceMenu.addItem(item)
            if tag == 1 { screenshotStyleItem = item } else { iconStyleItem = item }
        }
        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)

        let previewStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        previewStatus.isEnabled = false
        previewStatus.isHidden = true
        menu.addItem(previewStatus)
        previewStatusItem = previewStatus

        let switchStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        switchStatus.isEnabled = false
        switchStatus.isHidden = true
        menu.addItem(switchStatus)
        switchStatusItem = switchStatus

        let overlayMenuItem = NSMenuItem(
            title: "Show floating strip",
            action: #selector(toggleOverlay),
            keyEquivalent: ""
        )
        overlayMenuItem.target = self
        overlayMenuItem.state = .on
        menu.addItem(overlayMenuItem)
        overlayItem = overlayMenuItem

        let loginMenuItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginMenuItem.target = self
        menu.addItem(loginMenuItem)
        loginItem = loginMenuItem

        menu.addItem(.separator())
        let axItem = NSMenuItem(
            title: MissionControlSpaceSwitcher.isAccessibilityTrusted
                ? "Accessibility: allowed"
                : "Allow Accessibility for switching…",
            action: #selector(requestAccessibilityPermission),
            keyEquivalent: ""
        )
        axItem.target = self
        menu.addItem(axItem)
        accessibilityItem = axItem

        let permissionItem = NSMenuItem(
            title: CGPreflightScreenCaptureAccess()
                ? "Screen Recording: allowed"
                : "Allow screen recording…",
            action: #selector(requestScreenRecording),
            keyEquivalent: ""
        )
        permissionItem.target = self
        menu.addItem(permissionItem)
        screenRecordingItem = permissionItem

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit SpaceStrip", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // The button must not own the menu: a status item with a menu shows it
        // on click and never sends the action, which would break the tiles.
        // The right click menu is opened by hand instead.
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let button = self.statusItem.button else { return event }
            guard event.window === button.window else { return event }

            let point = button.convert(event.locationInWindow, from: nil)
            guard point.x >= 0, point.x <= button.bounds.width else { return event }

            self.menu.popUp(positioning: nil, at: point, in: button)
            return nil
        }

        updateLoginItemState()
    }

    private func setUpOverlay() {
        overlay = OverlayController(menu: menu) { [weak self] space in
            self?.switchTo(space)
        }
        overlay.onClose = { [weak self] in
            self?.hideOverlay()
        }
        overlay.onAdd = { [weak self] in
            self?.addDesktop()
        }
    }

    private func hideOverlay() {
        overlay.hide()
        overlayItem?.state = .off
    }

    private func updateLoginItemState() {
        guard let loginItem else { return }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFastRefresh() }
        }
        center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFastRefresh() }
        }
    }

    private func schedulePoll() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func scheduleFastRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Refresh

    private func refresh() {
        updatePermissionMenuItems()
        let displays = SpaceAPI.managedDisplays()
        let activeSpace = SpaceAPI.activeSpaceID()

        if lastObservedActiveSpaceID != activeSpace {
            lastObservedActiveSpaceID = activeSpace
            lastWindowScan = .distantPast
            ThumbnailService.shared.invalidate(spaceID: activeSpace)
        }

        let chosen = displays.first(where: { $0.spaces.contains { $0.id == activeSpace } })
            ?? displays.first(where: { !$0.spaces.isEmpty })

        guard let chosen, !chosen.spaces.isEmpty else {
            tiles = []
            updateButton()
            return
        }
        displayIdentifier = chosen.identifier

        let grouped = windowIndex()
        let screenBounds = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)

        var newTiles: [SpaceTile] = []
        for space in chosen.spaces where space.kind == .desktop {
            let window = WindowCatalog.representativeWindow(
                in: grouped[space.id] ?? [],
                screenBounds: screenBounds
            )
            let isCurrent = space.id == activeSpace
            let image = thumbnail(for: space, window: window, isCurrent: space.id == activeSpace)
            newTiles.append(
                SpaceTile(
                    space: space,
                    window: window,
                    image: image,
                    isCurrent: isCurrent
                )
            )
        }

        let changed = newTiles.map { "\($0.space.id)" } != tiles.map { "\($0.space.id)" }
        tiles = newTiles
        updateButton()
        overlay.update(tiles: newTiles, layout: overlayLayout)

        if changed { ThumbnailService.shared.invalidate() }
    }

    /// The window list changes slowly, so it is scanned every few seconds
    /// rather than on every poll.
    private func windowIndex() -> [UInt64: [WindowInfo]] {
        if Date().timeIntervalSince(lastWindowScan) < 3, !scannedWindows.isEmpty {
            return scannedWindows
        }
        lastWindowScan = Date()
        scannedWindows = WindowCatalog.windowsBySpace()
        return scannedWindows
    }

    private func thumbnail(for space: VirtualSpace, window: WindowInfo?, isCurrent: Bool) -> NSImage? {
        let service = ThumbnailService.shared
        let windowID = space.windowIDs.first ?? window?.id

        let source = ThumbnailService.source(
            hasScreenRecordingAccess: showsThumbnails && service.hasScreenRecordingAccess,
            windowID: windowID,
            windowOwnerPID: window?.ownerPID,
            spaceOwnerPID: space.ownerPID,
            fallbackPID: SpaceAPI.finderPID
        )
        if case let .capture(windowID) = source {
            service.requestImage(
                forSpace: space.id,
                windowID: windowID,
                size: overlayLayout.tileSize,
                maxAge: isCurrent ? 1 : 30
            ) { [weak self] in
                self?.refresh()
            }
            if let cached = service.cachedImage(forSpace: space.id, windowID: windowID) { return cached }
        }
        if case let .icon(pid) = source { return service.icon(for: pid) }
        if let pid = window?.ownerPID ?? space.ownerPID ?? SpaceAPI.finderPID {
            return service.icon(for: pid)
        }
        return nil
    }

    private func updateButton() {
        // The menu bar holds a single icon now, so there is nothing to redraw
        // here. The floating strip draws itself.
        if tiles.isEmpty {
            overlay.hide()
        }
    }

    private func updatePermissionMenuItems() {
        overlay?.panel.title = "SpaceStrip — Accessibility: \(MissionControlSpaceSwitcher.isAccessibilityTrusted), Screen Recording: \(ThumbnailService.shared.hasScreenRecordingAccess). \(switchStatusItem?.title ?? "") \(ThumbnailService.shared.lastError ?? "")"
        accessibilityItem?.title = MissionControlSpaceSwitcher.isAccessibilityTrusted
            ? "Accessibility: allowed"
            : "Allow Accessibility for switching…"
        screenRecordingItem?.title = ThumbnailService.shared.hasScreenRecordingAccess
            ? "Screen Recording: allowed"
            : "Allow screen recording…"
        if showsThumbnails && !ThumbnailService.shared.hasScreenRecordingAccess {
            previewStatusItem?.title = "App previews need Screen Recording permission"
        } else {
            previewStatusItem?.title = showsThumbnails ? ThumbnailService.shared.lastError ?? "" : ""
        }
        previewStatusItem?.isHidden = previewStatusItem?.title.isEmpty ?? true
        switchStatusItem?.isHidden = switchStatusItem?.title.isEmpty ?? true
    }

    // MARK: - Actions

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        toggleOverlay()
    }

    private func addDesktop() {
        guard let displayIdentifier else {
            switchStatusItem?.title = "Display is unavailable. Refresh and try again."
            return
        }
        guard let token = switchGate.begin() else {
            switchStatusItem?.title = "A desktop operation is already in progress."
            return
        }
        switchStatusItem?.title = "Adding desktop…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await missionControlSwitcher.addDesktop(displayID: displayIdentifier)
            guard switchGate.isActive(token) else { return }
            switchGate.finish(token)
            handle(result)
        }
    }

    private func handle(_ result: SpaceSwitchResult) {
        switch result {
        case .switched, .alreadyCurrent:
            switchStatusItem?.title = ""
        case .accessibilityRequired:
            switchStatusItem?.title = "Enable Accessibility to manage desktops"
            accessibilityItem?.title = "Allow Accessibility for switching…"
            MissionControlSpaceSwitcher.requestAccessibilityPermission()
        case let .failed(message):
            switchStatusItem?.title = message
        }
        refresh()
    }

    private func switchTo(_ space: VirtualSpace) {
        guard let displayIdentifier else {
            if let switchStatusItem { switchStatusItem.title = "Display is unavailable. Refresh and try again." }
            return
        }
        guard let display = SpaceAPI.managedDisplays().first(where: { $0.identifier == displayIdentifier }) else {
            if let switchStatusItem { switchStatusItem.title = "Display changed. Refresh and try again." }
            return
        }
        guard let token = switchGate.begin(
            targetID: space.id,
            availableSpaceIDs: Set(display.spaces.map(\.id))
        ) else {
            if !switchGate.isBusy, let switchStatusItem {
                switchStatusItem.title = "That desktop is no longer available. Refresh and try again."
            }
            return
        }

        if let switchStatusItem { switchStatusItem.title = "Switching desktop…" }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await missionControlSwitcher.switchTo(
                spaceID: space.id,
                displayID: display.identifier
            )
            guard switchGate.isActive(token) else { return }
            Debug.log("switch result for \(space.id): \(result)")
            switchGate.finish(token)
            handle(result)
        }
    }

    @objc private func requestAccessibilityPermission() {
        MissionControlSpaceSwitcher.requestAccessibilityPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func refreshNow() {
        ThumbnailService.shared.invalidate()
        refresh()
    }

    @objc private func selectTileAppearance(_ sender: NSMenuItem) {
        showsThumbnails = sender.tag == 1
        UserDefaults.standard.set(showsThumbnails, forKey: "showScreenshots")
        screenshotStyleItem?.state = showsThumbnails ? .on : .off
        iconStyleItem?.state = showsThumbnails ? .off : .on
        ThumbnailService.shared.invalidate()
        refresh()
    }

    @objc private func toggleOverlay() {
        if overlay.isVisible {
            hideOverlay()
        } else {
            overlay.show()
            overlayItem?.state = .on
        }
    }

    @objc private func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url { NSWorkspace.shared.open(url) }
    }

    @objc private func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            // Already answered once, so take the user to the settings pane.
            openScreenRecordingSettings()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            do {
                try SMAppService.mainApp.register()
            } catch {
                Debug.log("could not register login item: \(error)")
            }
        }
        updateLoginItemState()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
