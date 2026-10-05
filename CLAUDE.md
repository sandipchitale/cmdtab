# CmdTab

A Swift/AppKit macOS menu bar app (no Xcode project): a window-level Cmd+Tab switcher, an on-demand Option+Tab Dock, green-button maximize and a tiling menu. The README is the user-facing spec; keep it in step with any behavior change, including the key tables, the feature's section and the Menu section. The keys in the `?` help live in `Sources/KeyHelp.swift`.

## Build and install
- `./install.sh` builds a universal app (arm64 + x86_64), signs it with the stable self-signed "CmdTab Local Signing" certificate, installs it to /Applications and relaunches it. Always install this way. `./build.sh install` signs ad-hoc, which makes macOS drop the Accessibility and Screen Recording grants.
- `./build.sh` alone builds `build/CmdTab.app` with an ad-hoc signature. Only use it for the release zip.
- There are no unit or UI test targets. Check that it builds with `./build.sh`, then test on screen (see below).

## Sources
- `HotkeyTap`: the event tap. It maps keys to the `Command` enum and routes them to the switcher, the Dock or the search. Keep the tap callback fast and queue work to the main queue.
- `SwitcherController`: one Cmd+Tab session.
  - Windows or (G) app groups.
  - Search (F).
  - Z's view of running apps with no windows.
  - The previews.
  - The actions W/Q/M/H/N/T.
- `DockController`, `DockItems`: the Option+Tab Dock, including its Z view of running apps with no windows.
- `PanelGroup`: the panels on each display, the preview strips (or arc cards in a ring), the search bubble and the help. `SwitcherPanel`: one panel, plus `TileLayout` (grid, row, ring) and `AccentTint`. `TileViews`: the tile views and the ring's band.
- `Overlay`: `OverlayPanel` and the bubbles, which share the `BubblePanel` base: tooltip, hub title, search, help.
- `WindowManager`: window enumeration in most-recently-used order, focus, close, minimize, hide, quit, new window, and apps with no windows. `OffSpaceWindows`: windows on other desktops.
- `GreenButtonTap`: the green button and title-bar double-click. `WindowTiling`: the tiling menu. `WindowGeometry`: AX and AppKit coordinates, plus `FrameHistory`.
- `Settings`: `@Stored` user defaults. `StatusMenu`, `MenuItems`: the menu bar menu. `Thumbnails`: ScreenCaptureKit snapshots.
- The ring layout (R, `Settings.ringEnabled` / `ringLayout`) is experimental and off by default.

## Code style
Match the surrounding code. Doc comments say what something is for, in plain words. Names are descriptive. There are no third-party dependencies.

## Release (when asked to "squash ... prepare the release 0.0.1 ... push as a single commit")
History is one commit on `main`, tagged `v0.0.1`, with one GitHub release. To fold in new work:
1. **Back up first.** Save the current release notes (`gh release view v0.0.1 --json body -q .body`) and the commit message (`git log -1 --format=%B`) to the scratchpad.
2. **Commit message:** the same message, extended for the new feature: add it to the keys line and give it its own section. **No attribution lines** (no Co-Authored-By).
3. **Release notes:** the same notes, plus a bullet for the feature, with the SHA line updated at the end.
4. **Build the zip:**
   - `rm -f build/CmdTab-0.0.1.zip`, then `./build.sh` for the ad-hoc signature.
   - `ditto -c -k --norsrc --noextattr --keepParent build/CmdTab.app build/CmdTab-0.0.1.zip`. Plain zips carry `._` files that break the signature when someone uses `unzip`.
5. **Verify:**
   - Unpack with both `unzip` and `ditto -x -k`.
   - `codesign --verify --strict --deep` passes on both copies, and `Signature=adhoc`.
   - `lipo -archs` shows `x86_64 arm64`, and the version is 0.0.1.
   - `unzip -l` shows no `._` entries.
   - Note the SHA-256.
6. **Install:** then `./install.sh`, which re-signs `build/` with the local certificate. That's why the zip comes first.
7. **Commit:** `git add -u`, then `git commit --amend -F <msg>`. Check that `git rev-list --count HEAD` is 1 and the tree is clean.
8. **Publish:**
   - `git push --force-with-lease=main:<old sha> origin main`.
   - `gh release delete v0.0.1 --yes --cleanup-tag`, which also removes the local tag.
   - `git tag v0.0.1 && git push origin v0.0.1`.
   - `gh release create v0.0.1 build/CmdTab-0.0.1.zip --verify-tag --title "CmdTab 0.0.1" --notes-file <notes>`.
9. **Confirm:**
   - `git ls-remote origin` shows only `main` and `v0.0.1`, at the same commit.
   - GitHub's asset digest matches the SHA.
   - The installed app is running.

## On-screen testing
- Write small Swift helpers in the scratchpad:
  - One posts synthetic keys, with ⌘ held, and captures CmdTab's windows with `screencapture -R`.
  - One moves the pointer.
  - One double-clicks.
- They only work while the terminal app has Accessibility permission. Check with `AXIsProcessTrusted()`; without it, macOS drops the posted keys silently.
- **Before every run,** check that no modifier is held (`CGEventSource.flagsState(.hidSystemState)`) and that no CmdTab window is open. Otherwise stop: the user may be at the keyboard, and stray ⌘ shortcuts would reach their apps.
- Use temporary Finder windows for multi-window cases, and close them afterwards. Afterwards, restore the settings you changed (`defaults read com.sandipchitale.cmdtab`) and the frontmost app.
