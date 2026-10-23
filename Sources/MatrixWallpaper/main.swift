import AppKit

/// Accessory application without a Dock icon or desktop activation.
let app = NSApplication.shared
/// Retains the application delegate for the lifetime of the menu bar host.
let delegate = WallpaperApp()
app.setActivationPolicy(.accessory)
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }
