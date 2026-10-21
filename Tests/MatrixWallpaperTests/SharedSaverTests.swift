import AppKit
import ScreenSaver

/// Exercises the shared view and options controller through their hosting boundaries.
func sharedSaverTests() {
    guard let screen = NSScreen.main,
          let first = MatrixScreenSaverView(frame: screen.frame, isPreview: false),
          let second = MatrixScreenSaverView(frame: screen.frame, isPreview: false) else {
        check(false, "shared saver views can be created")
        return
    }
    first.isWallpaperHost = true
    second.isWallpaperHost = true
    let firstWindow = DesktopWindow(screen: screen, saverView: first)
    let secondWindow = DesktopWindow(screen: screen, saverView: second)
    let additionalWindows = NSScreen.screens.dropFirst(2).map { screen -> DesktopWindow in
        let saver = MatrixScreenSaverView(frame: screen.frame, isPreview: false)!
        saver.isWallpaperHost = true
        return DesktopWindow(screen: screen, saverView: saver)
    }
    secondWindow.setFrame(NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 960, height: 600), display: false)
    firstWindow.orderBack(nil)
    secondWindow.orderBack(nil)
    first.startAnimation()
    second.startAnimation()
    for window in additionalWindows {
        window.orderBack(nil)
        (window.contentView as! ScreenSaverView).startAnimation()
    }
    check(ScreenSyncCoordinator.shared.registeredCount == 2 + additionalWindows.count, "wallpaper hosts register for coordinated scenes")
    check(first.bounds.size != second.bounds.size, "coordinated hosts retain their individual canvas sizes")
    wait(2)
    check(ScreenSyncCoordinator.shared.resolvedStartTime() != nil, "wallpaper participants share a resolved start")
    let sharedStart = ScreenSyncCoordinator.shared.resolvedStartTime()
    var liveOptions = MatrixScreenSaverView.loadSaverOptions()
    liveOptions.frameRate = 42
    liveOptions.characters = "ATGC"
    first.applyWallpaperOptions(liveOptions)
    second.applyWallpaperOptions(liveOptions)
    check(first.animationTimeInterval == 1.0 / 42 && second.animationTimeInterval == 1.0 / 42,
          "live options update frame scheduling across wallpaper views")
    check(ScreenSyncCoordinator.shared.resolvedStartTime() == sharedStart,
          "live options preserve the coordinated scene anchor")
    for name in ["com.apple.screensaver.willstop", "com.apple.screensaver.didstop"] {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
    }
    wait(0.2)
    check(first.isAnimating && second.isAnimating, "saver-stop notifications do not disable wallpaper-host views")
    firstWindow.orderOut(nil)
    wait(0.1)
    check(first.isAnimating, "temporarily hidden wallpaper retains animation for automatic resumption")
    firstWindow.orderBack(nil)
    first.stopAnimation()
    second.stopAnimation()
    for window in additionalWindows {
        (window.contentView as! ScreenSaverView).stopAnimation()
        window.close()
    }
    check(ScreenSyncCoordinator.shared.registeredCount == 0, "stopping all hosts removes synchronization membership")
    firstWindow.close()
    secondWindow.close()

    // Keep real saver preferences untouched while exercising persistence and the native Apply action.
    let domain = "dev.patsch.MatrixWallpaper.tests.\(UUID().uuidString)"
    let defaults = ScreenSaverDefaults(forModuleWithName: domain)!
    defer { defaults.removePersistentDomain(forName: domain); defaults.synchronize() }
    MatrixScreenSaverOptions.registerDefaults(in: defaults)
    var options = MatrixScreenSaverOptions.load(from: defaults)
    options.frameRate = 42
    options.neoMessageLines = ["Shared options"]
    var applied = false
    let controller = MatrixScreenSaverOptionsSheetController { edited in
        edited.save(to: defaults)
        applied = true
    }
    controller.prepare(using: options)
    let applyButton = buttons(in: controller.configureSheet().contentView!).first { $0.title == "OK" }
    check(applyButton != nil, "native options window exposes Apply")
    applyButton?.performClick(nil)
    let loaded = MatrixScreenSaverOptions.load(from: defaults)
    check(applied && loaded.frameRate == 42 && loaded.neoMessageLines == ["Shared options"],
          "native Apply validates and delivers options through the reusable callback")
    options.frameRate = -10
    options.save(to: defaults)
    check(MatrixScreenSaverOptions.load(from: defaults).frameRate > 0, "shared persistence retains option sanitization")

    let original = MatrixScreenSaverOptions()
    var live = original
    live.twinkleEnabled.toggle()
    live.diffuseEnabled.toggle()
    live.rainDensity = 2
    live.frameRate = 42
    live.errorRate = 2
    live.characters = "ATGC"
    live.scanLinesIntensity = 0.5
    live.scanLinesVertical.toggle()
    check(!live.requiresSceneRestart(comparedTo: original), "visual and rain rendering settings apply without scene restart")
    let structuralChanges: [(String, (inout MatrixScreenSaverOptions) -> Void)] = [
        ("character size", { $0.characterWidth += 1 }),
        ("character height", { $0.characterHeight += 1 }),
        ("Neo enablement", { $0.neoMessageSceneEnabled.toggle() }),
        ("intro speed", { $0.neoMessageSpeedFactor = 2 }),
        ("Neo lines", { $0.neoMessageLines = ["Changed intro"] }),
        ("number intro", { $0.numberSceneEnabled.toggle() }),
        ("rain cycle mode", { $0.rainRunForever.toggle() }),
        ("rain cycle duration", { $0.rainDurationSeconds += 1 }),
    ]
    for (name, change) in structuralChanges {
        var changed = original
        change(&changed)
        check(changed.requiresSceneRestart(comparedTo: original), "\(name) requests a coordinated scene restart")
    }
}

/// Finds actual controls so integration checks use the native UI action, not private methods.
private func buttons(in view: NSView) -> [NSButton] {
    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
}
