# CmdTab

A tiny menu bar app that makes **Cmd+Tab switch between windows** the way Alt+Tab works on Windows. Nothing else changes, and Cmd+` keeps working as before.

## Switcher

![CmdTab switcher in thumbnail view, with the selected window highlighted and hidden-app badges](screenshots/cmdtab-switcher.png)

## Options

![CmdTab menu bar options](screenshots/cmdtab-options.png)

## Keys (while holding Cmd)

| Key | Action |
| --- | --- |
| Tab / Shift+Tab | Next / previous window |
| ← → ↑ ↓ | Move the selection around the grid |
| Release Cmd, or press Return | Switch to the selected window |
| W | Close the selected window |
| Q | Quit the selected window's app |
| M | Minimize / restore the selected window |
| H | Hide / show the selected window's app |
| Esc | Cancel |
| Mouse hover / click | Select / switch (in icon view, hovering also shows the window title) |

A quick Cmd+Tab tap jumps straight to the previous window without showing the switcher. Windows are listed in most-recently-used order, with minimized windows last.

W, Q, M and H act on the selected tile and keep the switcher open, so you can tidy up several windows in one go. Holding one of these keys acts only once. Finder can't be quit with Q. Restoring a minimized window of a hidden app with M also unhides that app, the same as clicking the window's thumbnail in the Dock.

## Views

- **App icons** (default): one large app icon per window, styled like the native macOS switcher. The selected icon gets a soft rounded highlight with its app name centered below it. Rest the pointer on an icon to see that window's title in a tooltip.
- **Window thumbnails**: a live snapshot of each window, with the app icon and window title above it. The selected tile gets an accent-colored border.

On macOS 26 and later, the switcher panel uses the same Liquid Glass material as the native switcher. Earlier versions get a blurred, tinted panel instead. Either way it follows the **Appearance** setting.

Choose between them in the menu. Thumbnails need **Screen Recording** permission (System Settings → Privacy & Security → Screen & System Audio Recording), and CmdTab must be relaunched after you grant it. Until then, tiles show the app icon. Minimized windows and windows of hidden apps can't be captured live, so they show their last snapshot, or the app icon if CmdTab hasn't captured them yet.

## Window state badges

A small yellow badge marks windows you can't currently see:

| Badge | Meaning |
| --- | --- |
| ● dot | The window is minimized |
| ◯ ring | The window's app is hidden |
| ◉ ring around the dot | Both |

Normal windows have no badge. In icon view the badge sits on the icon's bottom-right corner; in thumbnail view it's at the right end of the title row.

## Menu

The menu bar icon has these options:

- **Enabled**: turn CmdTab on or off. While it's off, the system Cmd+Tab works as usual.
- **Include Minimized Windows** / **Include Windows of Hidden Apps**: show or skip those windows.
- **Show App Icons** / **Show Window Thumbnails**: choose the view.
- **Appearance**: System, Light or Dark, for the switcher panel only.
- **Launch at Login**
- **Accessibility Permission**: shows whether it's granted, and opens System Settings if it isn't.
- **Quit CmdTab**

## Build & install

```sh
./install.sh           # builds, signs, copies to /Applications, launches
```

On first launch, grant **Accessibility** permission in System Settings → Privacy & Security → Accessibility. CmdTab starts working as soon as you turn it on. You don't need to relaunch.

The first time you run it, `install.sh` creates a self-signed code-signing certificate called "CmdTab Local Signing" in your login keychain. macOS asks for your password to trust it, and may ask once whether `codesign` can use the key (choose **Always Allow**). Every build is then signed with that certificate, so the Accessibility and Screen Recording grants survive rebuilds.

For window thumbnails, also grant **Screen Recording** permission and relaunch CmdTab (see [Views](#views)).

`./build.sh` alone builds `build/CmdTab.app` with an ad-hoc signature, and `./build.sh install` installs that. macOS treats each ad-hoc build as a new app, so you'd have to grant permissions again every time.

## Notes

- While CmdTab is running and enabled, it turns off the system Cmd+Tab app switcher. It turns it back on when you quit CmdTab or uncheck **Enabled**.
- Permissions are tied to the code signature. When it changes (for example, the first `install.sh` run after an ad-hoc build), the install resets the old Accessibility and Screen Recording entries and you grant them once more. To sign with your own certificate instead, set `CODESIGN_IDENTITY`.
- Like the Windows default, only windows on the current Space (desktop) are shown.

## License

[MIT](LICENSE) © 2026 Sandip Chitale
