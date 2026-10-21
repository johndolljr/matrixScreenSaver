import AppKit

/// Exercises the real host's menu actions, notifications, rebuilds, and cleanup.
func wallpaperAppTests() {
    let host = WallpaperApp()
    host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    defer { host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
    check(desktopWindowCount() == NSScreen.screens.count, "app creates one desktop window per display")
    check(ScreenSyncCoordinator.shared.registeredCount == NSScreen.screens.count, "app starts every display as one coordinated session")
    let originalWindows = NSApp.windows.compactMap { $0 as? DesktopWindow }.filter(\.isVisible)
    let originalIDs = Set(originalWindows.map(ObjectIdentifier.init))

    let workspace = NSWorkspace.shared.notificationCenter
    workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
    check(desktopWindowCount() == 0 && ScreenSyncCoordinator.shared.registeredCount == originalWindows.count,
          "sleep hides windows but retains scene synchronization membership")
    check(originalWindows.allSatisfy { ($0.contentView as? MatrixScreenSaverView)?.isAnimating == false },
          "sleep stops framework animation scheduling without destroying the views")
    workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    check(desktopWindowCount() == 0, "computer wake does not override display sleep")

    workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
    let resumedIDs = Set(NSApp.windows.filter { $0 is DesktopWindow && $0.isVisible }.map(ObjectIdentifier.init))
    check(resumedIDs == originalIDs && originalWindows.allSatisfy { ($0.contentView as? MatrixScreenSaverView)?.isAnimating == true },
          "wake resumes the same native views instead of replaying the intro")
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    check(Set(NSApp.windows.filter { $0 is DesktopWindow && $0.isVisible }.map(ObjectIdentifier.init)) == originalIDs,
          "unchanged display notifications do not restart a resumed scene")
    workspace.post(name: NSWorkspace.willSleepNotification, object: nil)

    check(NSApp.sendAction(NSSelectorFromString("togglePlayback:"), to: host, from: nil), "Stop menu action is connected")
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
    check(desktopWindowCount() == 0, "host preserves Stop after suspension clears")
    NSApp.sendAction(NSSelectorFromString("showOptions:"), to: host, from: nil)
    wait(0.1)
    let optionsWindow = NSApp.windows.first { $0.isVisible && !($0 is DesktopWindow) && $0.canBecomeKey }
    check(optionsWindow != nil, "Options opens a normal native window while stopped")
    check(desktopWindowCount() == 0, "opening Options does not start stopped playback")
    optionsWindow?.performClose(nil)

    NSApp.sendAction(NSSelectorFromString("togglePlayback:"), to: host, from: nil)
    check(desktopWindowCount() == NSScreen.screens.count, "Start recreates wallpaper on all displays")
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    check(desktopWindowCount() == NSScreen.screens.count && ScreenSyncCoordinator.shared.registeredCount == NSScreen.screens.count,
          "display reconciliation replaces rather than duplicates session membership")
    host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    check(desktopWindowCount() == 0 && ScreenSyncCoordinator.shared.registeredCount == 0, "Quit removes windows and animation participants")
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    check(desktopWindowCount() == 0, "Quit unregisters system observers")
}

/// Counts visible desktop surfaces without inspecting the host's private storage.
private func desktopWindowCount() -> Int {
    NSApp.windows.filter { $0 is DesktopWindow && $0.isVisible }.count
}
