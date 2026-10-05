import Foundation

/// A setting kept in the user defaults under `key`, reading as `defaultValue` until it's first set.
@propertyWrapper
struct Stored<Value> {
    let key: String
    let defaultValue: Value

    init(wrappedValue: Value, _ key: String) {
        self.key = key
        self.defaultValue = wrappedValue
    }

    var wrappedValue: Value {
        get { UserDefaults.standard.object(forKey: key) as? Value ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum Settings {
    /// Cmd+Tab shows the window switcher (and the system's app switcher is turned off).
    @Stored("enabled") static var enabled = true
    @Stored("includeMinimized") static var includeMinimized = true
    @Stored("includeHiddenApps") static var includeHiddenApps = true
    /// Also list windows on other Spaces (desktops), not just the current one.
    @Stored("includeAllSpaces") static var includeAllSpaces = false
    /// Window thumbnails instead of app icons.
    @Stored("showThumbnails") static var showThumbnails = false
    /// In icon view, the switcher previews the selected window under its icon.
    @Stored("switcherPreviews") static var switcherPreviews = false

    /// Option+Tab shows the Dock switcher.
    @Stored("dockEnabled") static var dockEnabled = true
    /// The Option+Tab Dock previews the selected app's windows under its icon.
    @Stored("dockPreviews") static var dockPreviews = false

    /// Show the switcher and the Dock on every display, not just one.
    @Stored("showOnAllDisplays") static var showOnAllDisplays = true
    /// With showOnAllDisplays off, where they appear: "pointer" (the display with the mouse pointer) or
    /// "activeWindow" (the display with the frontmost window).
    @Stored("switcherDisplay") static var switcherDisplay = "pointer"
    /// Panel appearance: "system", "light", or "dark".
    @Stored("appearance") static var appearance = "system"

    /// Whether the switcher's and the Dock's help has been shown once already, unasked (the first time each appears).
    @Stored("switcherHelpShown") static var switcherHelpShown = false
    @Stored("dockHelpShown") static var dockHelpShown = false

    /// Clicking a window's green button toggles it between filling the screen and its previous frame, instead of
    /// entering full screen.
    @Stored("greenButtonZooms") static var greenButtonZooms = true
}
