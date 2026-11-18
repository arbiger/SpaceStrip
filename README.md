# SpaceStrip

SpaceStrip is a macOS menu bar utility for selecting regular virtual desktops from a floating strip. It was designed for a Mac controlled through Screen Sharing, where the local keyboard shortcuts may not reach the remote Mac.

## Status and requirements

The Swift package targets macOS 14 or later and requires a Swift 6 toolchain. It uses unsupported macOS window-server and Mission Control interfaces, which may change between macOS releases. Regular desktop switching was tried over Screen Sharing on the original Mac mini setup. The self-tests do not exercise live switching or screen capture.

The source package declares no third-party dependencies. Run `./build.sh` to build and ad-hoc sign `build/SpaceStrip.app`, or `./run.sh` to build if needed and launch it. Run `./install.sh` to install and start it in `/Applications`; an existing copy is moved to `/tmp` first. These launch and install scripts stop a running SpaceStrip process.

## Use

Click the menu bar icon to show or hide the floating strip. Right-click it for refresh, tile appearance, floating strip, launch-at-login, permission settings, and quit options. Click a desktop tile to select it; the confirmed current desktop is highlighted. The floating panel can be dragged and closed with its cross. The **+** button asks Mission Control to add a desktop and attempts to select the uniquely detected new desktop. If creation cannot be confirmed, check Mission Control before retrying.

Only **regular desktops** are shown as tiles. Full-screen app Spaces and tiled layouts are not selectable tiles, even though they are included when mapping the full Mission Control Space order. If a full-screen Space is active, no regular-desktop tile may be highlighted. The strip selects the display containing the active Space when possible, otherwise the first display with Spaces; it is not a simultaneous multi-display overview.

## Icons, screenshots and permissions

App icons are the default tile appearance. A tile uses a representative eligible window's app icon, then the Space owner or Finder as a fallback when available; an empty tile is possible. Choose **Tile appearance → Screenshots** to request a preview of one representative app window, not a composite screenshot of the whole desktop. When capture is unavailable, pending or fails, the app uses an available icon; a previously captured frame for the same window can remain visible after a later capture failure. Window identity changes invalidate reuse of a different window's frame. An empty desktop can therefore show Finder's icon rather than wallpaper.

- **Accessibility** is needed to select and add desktops through Mission Control. Use the menu's Accessibility action or System Settings → Privacy & Security → Accessibility to grant SpaceStrip access.
- **Screen & System Audio Recording** permission is needed for window screenshots, not for icon mode. Grant it to SpaceStrip in Privacy & Security if screenshots are wanted. The menu provides a settings shortcut and reports permission or preview status.

macOS may require reopening the app after permission changes, or renewing permissions for a replaced ad-hoc-signed app. Capture can also fail for reasons other than permission, including an unavailable window.

## Implementation and development

SpaceStrip reads the ordered Spaces using private SkyLight interfaces. It opens Mission Control, matches the display and Space buttons through the WindowManager accessibility tree, presses the corresponding button, and checks the active Space and closure of Mission Control. It reports failure when its mapping or confirmation is unavailable. The production switch path does not directly set a Space ID. This approach depends on macOS internals and may stop working after an OS update.

```bash
swift build
swift run SpaceStrip --dump
swift run SpaceStrip --selftest
```

`--dump` reports observed state; `--selftest` checks switch gating, mapping, screenshot fallback and geometry without proving a live switch or rendered-window behavior. Set `SPACESTRIP_LOG=1` for debug output. Historical `Tools/` probes are not app tests; some use guessed private APIs and can change Space state.

## References and credits

- [Hammerspoon's Mission Control discussion](https://github.com/Hammerspoon/hammerspoon/issues/3897), [patch](https://github.com/Hammerspoon/hammerspoon/pull/3904), and [Spaces implementation](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/spaces.lua) informed the Mission Control accessibility approach and WindowManager hierarchy. The Swift switcher uses the same described technique: it finds WindowManager’s Mission Control display and Space list, then presses a matched accessibility button. Its recursive lookup, snapshot checks and asynchronous confirmation are Swift implementation details; this comparison does not establish whether code was copied or adapted.
- [yabai's payload source](https://github.com/asmvik/yabai/blob/master/src/osax/payload.m) was consulted for earlier private API and ABI research. yabai is not a dependency, and the current switch path does not use its direct Space setter. The available record does not establish code provenance conclusively.
- [Spaceman by Sasindu Jayasinghe](https://github.com/Jaysce/Spaceman), [René Uittenbogaard's fork](https://github.com/ruittenb/Spaceman), the [janweigel fork](https://github.com/janweigel/interise_spaceman), and [Screen Switcher](https://github.com/Binary-Web-Solutions/screen-switcher) were evaluated for comparison only; neither fork nor the other comparison projects is a declared dependency or documented source of borrowed code.

Thanks to the maintainers and contributors of these projects for publishing their work. The [Hammerspoon license notice](THIRD_PARTY_NOTICES/Hammerspoon.txt) accompanies the Mission Control reference. SpaceStrip does not currently declare a project-wide license.
