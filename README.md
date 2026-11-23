# SpaceStrip

SpaceStrip is a macOS menu bar utility for selecting virtual desktops and fullscreen Spaces from a floating strip. It was designed for a Mac controlled through Screen Sharing, where the local keyboard shortcuts may not reach the remote Mac.

## Download

On Apple silicon Macs, download **SpaceStrip-macOS.zip** from [GitHub Releases](https://github.com/arbiger/SpaceStrip/releases/latest), unzip it, and move **SpaceStrip.app** to Applications. The download is ad-hoc signed and is not Apple-notarized.

## Status and requirements

The Swift package targets macOS 14 or later and requires a Swift 6 toolchain. It uses unsupported macOS window-server and Mission Control interfaces, which may change between macOS releases. Desktop and fullscreen shortcut switching were tried over Screen Sharing on the Mac mini. The self-tests do not exercise live switching or screen capture.

The source package declares no third-party dependencies. Run `./build.sh` to build and ad-hoc sign `build/SpaceStrip.app`, or `./run.sh` to build if needed and launch it. Run `./install.sh` to install and start it in `/Applications`; an existing copy is moved to `/tmp` first. These launch and install scripts stop a running SpaceStrip process.

## Use

Hover over the menu bar icon to reveal the floating strip above app windows. It hides two seconds after the pointer leaves both the icon and strip; returning cancels the countdown. Right-click the icon and choose **Hide delay** to select 1–10 seconds or **Manual**, which uses clicks to show and hide the strip. The choice is saved. Clicking the icon also toggles the strip in hover mode. Click a desktop tile to select it; in hover mode, a successful switch to a regular desktop hides the strip. Move off the icon and back to reveal it again. The confirmed current desktop is highlighted. Right-click for refresh, tile appearance, floating strip, launch-at-login, permission settings, and quit options. The floating panel can be dragged and closed with its cross. The **+** button asks Mission Control to add a desktop and attempts to select the uniquely detected new desktop. If creation cannot be confirmed, check Mission Control before retrying.

Regular desktops appear by default. Select **Show fullscreen Spaces** to include eligible fullscreen apps and tiled layouts. The strip appears when you enter one of these Spaces, and fullscreen tiles use app icons. The strip follows one display at a time.

Under **Switching mode**, **All Slide** is the default and uses the Mac’s configured Move left/right a Space shortcuts. **Mixed** uses Mission Control between regular desktops and slides when fullscreen is involved. **All Jump** uses Mission Control for every tile. Mission Control jumps involving fullscreen can cause visual overlap on some setups.

Clicking the current tile hides the strip. A Mission Control jump between regular desktops can complete for an empty destination after the active Space and overview closure are confirmed. A fullscreen-to-desktop jump requires additional window evidence and may remain unconfirmed for an empty desktop. These checks do not establish rendered pixels or keyboard focus.

**Slide wait** offers 150, 300, 450, and 650 ms, with 150 ms as the default. This is how long the destination must report as active before the next step or completion. macOS controls the animation. On the Mac you control through Screen Sharing, **System Settings → Accessibility → Motion → Reduce Motion** can make the slide less distracting.

## Icons, screenshots and permissions

App icons are the default tile appearance. A tile uses a representative eligible window's app icon, then the Space owner or Finder as a fallback when available; an empty tile is possible. Choose **Tile appearance → Screenshots** to request a preview of one representative app window, not a composite screenshot of the whole desktop. When capture is unavailable, pending or fails, the app uses an available icon; a previously captured frame for the same window can remain visible after a later capture failure. Window identity changes invalidate reuse of a different window's frame. An empty desktop can therefore show Finder's icon rather than wallpaper.

- **Accessibility** is needed to send Space shortcuts and manage desktops through Mission Control. Use the menu's Accessibility action or System Settings → Privacy & Security → Accessibility to grant SpaceStrip access.
- **Screen & System Audio Recording** permission is needed for window screenshots, not for icon mode. Grant it to SpaceStrip in Privacy & Security if screenshots are wanted. The menu provides a settings shortcut and reports permission or preview status.

macOS may require reopening the app after permission changes, or renewing permissions for a replaced ad-hoc-signed app. Capture can also fail for reasons other than permission, including an unavailable window.

## Implementation and development

SpaceStrip reads the ordered Spaces using private SkyLight interfaces. For slides it sends configured shortcuts and verifies each expected adjacent Space. For jumps it opens Mission Control, matches the display and Space buttons through the WindowManager accessibility tree, presses the corresponding button, and checks the active Space and closure of Mission Control. It reports failure when its mapping or confirmation is unavailable. The production switch path does not directly set a Space ID. This approach depends on macOS internals and may stop working after an OS update.

```bash
swift build
swift run SpaceStrip --dump
swift run SpaceStrip --selftest
```

`--dump` reports observed state; `--selftest` checks hover timing, switch gating, mapping, screenshot fallback and geometry without proving a live switch or rendered-window behavior. Set `SPACESTRIP_LOG=1` for debug output. Historical `Tools/` probes are not app tests; some use guessed private APIs and can change Space state.

## References and credits

- [Hammerspoon's Mission Control discussion](https://github.com/Hammerspoon/hammerspoon/issues/3897), [patch](https://github.com/Hammerspoon/hammerspoon/pull/3904), and [Spaces implementation](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/spaces.lua) informed the Mission Control accessibility approach and WindowManager hierarchy. The Swift switcher uses the same described technique: it finds WindowManager’s Mission Control display and Space list, then presses a matched accessibility button. Its recursive lookup, snapshot checks and asynchronous confirmation are Swift implementation details; this comparison does not establish whether code was copied or adapted.
- [yabai's payload source](https://github.com/asmvik/yabai/blob/master/src/osax/payload.m) was consulted for earlier private API and ABI research. yabai is not a dependency, and the current switch path does not use its direct Space setter. The available record does not establish code provenance conclusively.
- [Spaceman by Sasindu Jayasinghe](https://github.com/Jaysce/Spaceman), [René Uittenbogaard's fork](https://github.com/ruittenb/Spaceman), the [janweigel fork](https://github.com/janweigel/interise_spaceman), and [Screen Switcher](https://github.com/Binary-Web-Solutions/screen-switcher) were evaluated for comparison. René Uittenbogaard’s smooth switching informed the shortcut approach. SpaceStrip uses its own Core Graphics implementation and has no runtime dependency on these projects.

Thanks to the maintainers and contributors of these projects for publishing their work. The [Hammerspoon license notice](THIRD_PARTY_NOTICES/Hammerspoon.txt) accompanies the Mission Control reference. SpaceStrip does not currently declare a project-wide license.
