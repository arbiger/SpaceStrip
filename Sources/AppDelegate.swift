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
    private var hoverTimer: Timer?
    private var hoverState = HoverState()
    private var hoverDelay: Int = {
        guard let value = UserDefaults.standard.object(forKey: "hoverDelay") as? Int,
              (0...10).contains(value) else { return 2 }
        return value
    }()
    private var tiles: [SpaceTile] = []
    private var displayIdentifier: String?
    private var showsThumbnails = UserDefaults.standard.object(forKey: "showScreenshots") as? Bool ?? false
    private var inFullscreenSpace = false
    private var showsFullscreen = UserDefaults.standard.bool(forKey: "showFullscreenSpaces")
    private var switchMode = SpaceSwitchMode.stored(UserDefaults.standard.object(forKey: "switchMode"))
    private var slideWait = SpaceShortcutSwitcher.storedWait(UserDefaults.standard.object(forKey: "slideWait"))
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
        if hoverDelay > 0 && !inFullscreenSpace { hideOverlay() }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        schedulePoll()
        observeWorkspace()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        hoverTimer?.invalidate()
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let title = version.map { "SpaceStrip \($0)" } ?? "SpaceStrip"
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
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

        let fullscreenItem = NSMenuItem(title: "Show fullscreen Spaces", action: #selector(toggleFullscreenSpaces(_:)), keyEquivalent: "")
        fullscreenItem.target = self
        fullscreenItem.state = showsFullscreen ? .on : .off
        menu.addItem(fullscreenItem)

        let modeItem = NSMenuItem(title: "Switching mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for mode in SpaceSwitchMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectSwitchMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            item.state = mode == switchMode ? .on : .off
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let waitItem = NSMenuItem(title: "Slide wait", action: nil, keyEquivalent: "")
        let waitMenu = NSMenu()
        for milliseconds in SpaceShortcutSwitcher.waitOptions {
            let item = NSMenuItem(title: "\(milliseconds) ms", action: #selector(selectSlideWait(_:)), keyEquivalent: "")
            item.target = self
            item.tag = milliseconds
            item.state = milliseconds == slideWait ? .on : .off
            waitMenu.addItem(item)
        }
        waitItem.submenu = waitMenu
        menu.addItem(waitItem)

        let hoverItem = NSMenuItem(title: "Hide delay", action: nil, keyEquivalent: "")
        let hoverMenu = NSMenu()
        for delay in 0...10 {
            let item = NSMenuItem(title: delay == 0 ? "Manual" : "\(delay) second\(delay == 1 ? "" : "s")", action: #selector(selectHoverDelay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = delay
            item.state = delay == hoverDelay ? .on : .off
            hoverMenu.addItem(item)
        }
        hoverItem.submenu = hoverMenu
        menu.addItem(hoverItem)

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
            guard !self.switchGate.isBusy else { return nil }

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
        guard !switchGate.isBusy else { return }
        overlay.hide()
        overlayItem?.state = .off
        hoverState.dismissed()
    }

    private func updateHover() {
        guard !switchGate.isBusy, !inFullscreenSpace else { return }
        guard let button = statusItem.button, let window = button.window else { return }
        let point = NSEvent.mouseLocation
        let iconFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let action = hoverState.update(icon: iconFrame.contains(point), panel: overlay.isVisible && overlay.panel.frame.contains(point), visible: overlay.isVisible, delay: hoverDelay, now: ProcessInfo.processInfo.systemUptime)
        if action == 1 && !tiles.isEmpty {
            overlay.show()
            overlayItem?.state = .on
        } else if action == -1 {
            hideOverlay()
        }
    }

    @objc private func selectHoverDelay(_ sender: NSMenuItem) {
        guard !switchGate.isBusy else { return }
        hoverDelay = sender.tag
        UserDefaults.standard.set(hoverDelay, forKey: "hoverDelay")
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
        hoverState.reset()
    }

    @objc private func selectSwitchMode(_ sender: NSMenuItem) {
        guard !switchGate.isBusy, let mode = SpaceSwitchMode(rawValue: sender.tag) else { return }
        switchMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "switchMode")
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
    }

    @objc private func selectSlideWait(_ sender: NSMenuItem) {
        guard !switchGate.isBusy, SpaceShortcutSwitcher.waitOptions.contains(sender.tag) else { return }
        slideWait = sender.tag
        UserDefaults.standard.set(slideWait, forKey: "slideWait")
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
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
        guard !switchGate.isBusy else { return }
        updatePermissionMenuItems()
        let displays = SpaceAPI.managedDisplays()
        let activeSpace = SpaceAPI.activeSpaceID()

        let activeSpaceChanged = lastObservedActiveSpaceID != activeSpace
        if activeSpaceChanged {
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
        let wasInFullscreen = inFullscreenSpace
        inFullscreenSpace = showsFullscreen && chosen.spaces.contains {
            $0.id == activeSpace && $0.kind != .desktop && $0.isSelectable
        }
        displayIdentifier = chosen.identifier

        let grouped = windowIndex()
        let screenBounds = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)

        var newTiles: [SpaceTile] = []
        for space in chosen.spaces where space.isVisible(showFullscreen: showsFullscreen) {
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
        overlay.update(tiles: newTiles, layout: overlayLayout,
                       screen: MissionControlSpaceSwitcher.screen(for: chosen.identifier) ?? NSScreen.main ?? NSScreen.screens.first)

        if inFullscreenSpace && (activeSpaceChanged || !wasInFullscreen) {
            hoverState.reset()
            overlay.show()
            overlayItem?.state = .on
        } else if wasInFullscreen && !inFullscreenSpace {
            hoverState.reset()
        }
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
        if space.kind != .desktop {
            let matchingWindow = space.windowIDs.lazy.compactMap { id in
                self.scannedWindows.values.lazy.flatMap { $0 }.first { $0.id == id }
            }.first
            guard let pid = matchingWindow?.ownerPID ?? space.ownerPID else { return nil }
            return service.icon(for: pid)
        }
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
        guard !switchGate.isBusy else { return }
        guard let displayIdentifier else {
            switchStatusItem?.title = "Display is unavailable. Refresh and try again."
            return
        }
        guard let token = switchGate.begin() else { return }
        overlay.suspend()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await missionControlSwitcher.addDesktop(displayID: displayIdentifier)
            guard switchGate.isActive(token) else { return }
            switchGate.finish(token)
            handle(result)
            overlay.resume()
            refresh()
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
        guard !switchGate.isBusy else { return }
        if SpaceAPI.activeSpaceID() == space.id {
            hideOverlay()
            return
        }
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

        let selectedMode = switchMode
        let selectedWait = slideWait
        overlay.suspend()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await missionControlSwitcher.switchTo(
                spaceID: space.id,
                displayID: display.identifier,
                mode: selectedMode,
                slideWait: selectedWait
            )
            guard switchGate.isActive(token) else { return }
            Debug.log("switch result for \(space.id): \(result)")
            switchGate.finish(token)
            handle(result)
            if hoverDelay > 0 && !inFullscreenSpace {
                if result == .switched || result == .alreadyCurrent { hideOverlay() }
            }
            overlay.resume()
            refresh()
        }
    }

    @objc private func requestAccessibilityPermission() {
        MissionControlSpaceSwitcher.requestAccessibilityPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func refreshNow() {
        guard !switchGate.isBusy else { return }
        ThumbnailService.shared.invalidate()
        refresh()
    }

    @objc private func toggleFullscreenSpaces(_ sender: NSMenuItem) {
        guard !switchGate.isBusy else { return }
        showsFullscreen.toggle()
        UserDefaults.standard.set(showsFullscreen, forKey: "showFullscreenSpaces")
        sender.state = showsFullscreen ? .on : .off
        refresh()
    }

    @objc private func selectTileAppearance(_ sender: NSMenuItem) {
        guard !switchGate.isBusy else { return }
        showsThumbnails = sender.tag == 1
        UserDefaults.standard.set(showsThumbnails, forKey: "showScreenshots")
        screenshotStyleItem?.state = showsThumbnails ? .on : .off
        iconStyleItem?.state = showsThumbnails ? .off : .on
        ThumbnailService.shared.invalidate()
        refresh()
    }

    @objc private func toggleOverlay() {
        guard !switchGate.isBusy else { return }
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
