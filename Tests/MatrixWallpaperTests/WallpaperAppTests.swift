import AppKit

/// Exercises the real host's menu actions, notifications, rebuilds, and cleanup.
func wallpaperAppTests() {
    wallpaperIconTests()
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
    if let source = originalWindows.first?.contentView as? MatrixScreenSaverView,
       let screen = originalWindows.first?.screen,
       let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
        var reader: WallpaperFrameReader? = WallpaperFrameReader()
        _ = reader?.frame(displayID: displayID, pointSize: source.bounds.size)
        var first: SharedWallpaperFrame.Frame?
        let deadline = Date(timeIntervalSinceNow: 10)
        repeat {
            wait(0.1)
            first = reader?.frame(displayID: displayID, pointSize: source.bounds.size)
        } while first == nil && Date() < deadline
        check(first != nil, "host discovery publishes a matching display without restarting its renderer")
        let distributed = DistributedNotificationCenter.default()
        distributed.postNotificationName(Notification.Name("com.apple.screensaver.willstart"), object: nil,
                                         userInfo: nil, deliverImmediately: true)
        wait(0.2)
        check(desktopWindowCount() == 0 && source.isAnimating,
              "active saver consumers hide desktop windows but keep their sole renderer running")
        wait(0.6)
        let next = reader?.frame(displayID: displayID, pointSize: source.bounds.size)
        check(next != nil && next!.sequence > (first?.sequence ?? 0),
              "hidden wallpaper publishes advancing frames for the saver")
        if let other = originalWindows.first(where: {
            ($0.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) != displayID
        }), let otherSource = other.contentView as? MatrixScreenSaverView,
           let otherID = other.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            var otherReader: WallpaperFrameReader? = WallpaperFrameReader()
            var otherFrame: SharedWallpaperFrame.Frame?
            let deadline = Date(timeIntervalSinceNow: 10)
            repeat {
                _ = reader?.frame(displayID: displayID, pointSize: source.bounds.size)
                otherFrame = otherReader?.frame(displayID: otherID, pointSize: otherSource.bounds.size)
                wait(0.1)
            } while otherFrame == nil && Date() < deadline
            check(otherFrame != nil, "each display offers its own matching wallpaper frame")
            let otherURL = otherSource.shareWallpaperFrames()
            otherReader = nil
            let expiry = Date(timeIntervalSinceNow: SharedWallpaperFrame.freshnessInterval + 0.6)
            while Date() < expiry {
                _ = reader?.frame(displayID: displayID, pointSize: source.bounds.size)
                wait(0.1)
            }
            check(otherURL != nil && !FileManager.default.fileExists(atPath: otherURL!.path) && source.isAnimating,
                  "one display's consumer expiry releases its buffer while another stays connected")
        }
        reader = nil
        wait(SharedWallpaperFrame.freshnessInterval + 0.6)
        check(!source.isAnimating && desktopWindowCount() == 0,
              "an expired consumer lease stops hidden rendering without discarding the session")
        distributed.postNotificationName(Notification.Name("com.apple.screensaver.didstop"), object: nil,
                                         userInfo: nil, deliverImmediately: true)
        wait(0.2)
        check(source.isAnimating && Set(NSApp.windows.filter { $0 is DesktopWindow && $0.isVisible }.map(ObjectIdentifier.init)) == originalIDs,
              "saver exit reveals the same wallpaper views without replaying the intro")
    }
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

/// Checks the shipped artwork rather than duplicating the generator's drawing logic.
private func wallpaperIconTests() {
    let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    guard let image = NSImage(contentsOf: resources.appendingPathComponent("WallpaperIcon.png")),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        check(false, "app icon preview loads")
        return
    }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    check(bitmap.pixelsWide == 1024 && bitmap.pixelsHigh == 1024, "app icon has a full-resolution master")
    check(bitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0 &&
          bitmap.colorAt(x: 150, y: 512)!.brightnessComponent == 0,
          "app icon has transparent outer corners and a black tile")
    let greens = (300..<700).map { bitmap.colorAt(x: 380, y: $0)!.usingColorSpace(.sRGB)! }
    check(greens.contains { $0.greenComponent > 0.7 && $0.greenComponent > $0.redComponent * 2 },
          "app glyph uses saturated rain green")
    check(zip(greens, greens.dropFirst()).contains { abs($0.greenComponent - $1.greenComponent) > 0.2 },
          "app glyph includes contrasting scanlines")
    check(bitmap.colorAt(x: 300, y: 267)!.usingColorSpace(.sRGB)!.greenComponent > 0.7 &&
          bitmap.colorAt(x: 350, y: 760)!.usingColorSpace(.sRGB)!.greenComponent > 0.4 &&
          bitmap.colorAt(x: 700, y: 760)!.usingColorSpace(.sRGB)!.greenComponent < 0.15,
          "app glyph retains the SVG M's stepped shoulder and uneven feet")
    let icon = NSImage(contentsOf: resources.appendingPathComponent("WallpaperIcon.icns"))
    check(icon != nil && icon!.representations.count > 1, "app icon includes multiple native resolutions")

    guard let document = CGPDFDocument(resources.appendingPathComponent("MenuBarIcon.pdf") as CFURL),
          let page = document.page(at: 1),
          let context = CGContext(data: nil, width: 72, height: 72, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        check(false, "menu icon loads as vector artwork")
        return
    }
    check(page.getBoxRect(.mediaBox).size == CGSize(width: 18, height: 18), "menu icon fits the status bar")
    context.scaleBy(x: 4, y: 4)
    context.drawPDFPage(page)
    let menu = NSBitmapImageRep(cgImage: context.makeImage()!)
    let stem = (12..<60).map { menu.colorAt(x: 20, y: $0)! }
    check(menu.colorAt(x: 0, y: 0)!.alphaComponent == 0 &&
          stem.contains { $0.alphaComponent == 0 } && stem.contains { $0.alphaComponent > 0.9 },
          "menu icon has transparent background and scanline gaps through the M")
    check(stem.allSatisfy { $0.redComponent == $0.greenComponent && $0.greenComponent == $0.blueComponent },
          "menu icon is monochrome for system template tinting")
}

/// Counts visible desktop surfaces without inspecting the host's private storage.
private func desktopWindowCount() -> Int {
    NSApp.windows.filter { $0 is DesktopWindow && $0.isVisible }.count
}
