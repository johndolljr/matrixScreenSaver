import AppKit
import ScreenSaver

/// Menu bar host for native Matrix animation behind desktop content.
final class WallpaperApp: NSObject, NSApplicationDelegate {
    /// Retains the status item for the lifetime of the application.
    private var statusItem: NSStatusItem?

    /// Owns the native desktop surfaces until playback ends.
    private var windows: [DesktopWindow] = []

    /// User intent and independent suspension conditions for this session.
    private var playback = WallpaperPlaybackState()

    /// Menu action whose label follows requested playback, not temporary suspension.
    private let playbackItem = NSMenuItem(title: "Stop", action: #selector(togglePlayback(_:)), keyEquivalent: "")

    /// Retains native options UI independently of transient wallpaper views.
    private var optionsController: MatrixScreenSaverOptionsSheetController?

    /// Notification registrations paired with their owning centers for deterministic cleanup.
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Shared wall-clock pause anchor; duplicate suspension events must not replace it.
    private var suspendedAt: TimeInterval?

    /// Options currently applied to the preserved session.
    private var currentOptions = MatrixScreenSaverOptions()

    /// Captured display geometry distinguishes real topology changes from wake notifications.
    private struct DisplayLayout: Equatable {
        let id: UInt32
        let frame: NSRect
        let scale: CGFloat
    }

    private var displayLayout: [DisplayLayout] = []

    private var currentDisplayLayout: [DisplayLayout] {
        NSScreen.screens.map {
            DisplayLayout(id: $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0,
                          frame: $0.frame, scale: $0.backingScaleFactor)
        }.sorted { $0.id < $1.id }
    }

    /// Creates menu controls and begins observing desktop playback conditions.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Matrix"
        let menu = NSMenu()
        playbackItem.target = self
        menu.addItem(playbackItem)
        let options = NSMenuItem(title: "Options…", action: #selector(showOptions(_:)), keyEquivalent: "")
        options.target = self
        menu.addItem(options)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Matrix Wallpaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item

        observeSystemState()
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            playback.setSuspended(.sessionInactive, (session[kCGSessionOnConsoleKey as String] as? Bool) == false)
        }
        playback.setSuspended(.displaysSleeping, NSScreen.screens.allSatisfy { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return false }
            return CGDisplayIsAsleep(id) != 0
        })
        reconcilePlayback()
    }

    /// Starts or stops at the user's request without overriding system suspension.
    @objc private func togglePlayback(_ sender: Any?) {
        playback.isRequested.toggle()
        reconcilePlayback()
    }

    /// Presents the shared native options window; only this explicit action activates the app.
    @objc private func showOptions(_ sender: Any?) {
        if let optionsController {
            optionsController.configureSheet().makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = MatrixScreenSaverOptionsSheetController { [weak self] options in
            self?.applyOptions(options)
        }
        controller.onClose = { [weak self] in self?.optionsController = nil }
        controller.prepare(using: MatrixScreenSaverView.loadSaverOptions())
        optionsController = controller
        controller.configureSheet().center()
        controller.configureSheet().makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Updates ordinary rendering settings in place; grid and scene-cycle changes restart together.
    private func applyOptions(_ options: MatrixScreenSaverOptions) {
        let options = options.sanitized()
        let restart = options.requiresSceneRestart(comparedTo: currentOptions)
        options.save(to: MatrixScreenSaverView.defaults)
        currentOptions = options
        if restart {
            reconcilePlayback(restart: true)
        } else {
            for window in windows { (window.contentView as? MatrixScreenSaverView)?.applyWallpaperOptions(options) }
        }
    }

    /// Rebuilds the whole participating session, never leaving stale scene-barrier members.
    ///
    /// - Parameter restart: Forces coordinated reconstruction after options or display changes.
    private func reconcilePlayback(restart: Bool = false) {
        playbackItem.title = playback.isRequested ? "Stop" : "Start"
        if !playback.isRequested || restart { removeDesktopWindows() }
        guard playback.isRequested else { return }
        guard playback.shouldRun else {
            if suspendedAt == nil && !windows.isEmpty {
                suspendedAt = Date.timeIntervalSinceReferenceDate
                for window in windows {
                    (window.contentView as? MatrixScreenSaverView)?.pauseWallpaperAnimation()
                    window.orderOut(nil)
                }
            }
            return
        }
        if let suspendedAt {
            let duration = Date.timeIntervalSinceReferenceDate - suspendedAt
            ScreenSyncCoordinator.shared.shiftTimeline(by: duration)
            for window in windows {
                window.orderBack(nil)
                (window.contentView as? MatrixScreenSaverView)?.resumeWallpaperAnimation(after: duration)
            }
            self.suspendedAt = nil
        }
        guard windows.isEmpty else { return }
        currentOptions = MatrixScreenSaverView.loadSaverOptions()
        displayLayout = currentDisplayLayout
        for screen in NSScreen.screens {
            guard let saver = MatrixScreenSaverView(frame: NSRect(origin: .zero, size: screen.frame.size), isPreview: false) else {
                let alert = NSAlert()
                alert.messageText = "Could not start Matrix Wallpaper"
                alert.informativeText = "The native screen saver view could not be created."
                alert.runModal()
                NSApp.terminate(nil)
                return
            }
            saver.isWallpaperHost = true
            let window = DesktopWindow(screen: screen, saverView: saver)
            windows.append(window)
        }
        // Attach every display before starting registration and the framework's animation timers.
        for window in windows {
            window.orderBack(nil)
            (window.contentView as? ScreenSaverView)?.startAnimation()
        }
    }

    /// Unregisters every view before closing any window or starting a replacement session.
    private func removeDesktopWindows() {
        for window in windows { (window.contentView as? ScreenSaverView)?.stopAnimation() }
        for window in windows {
            window.close()
        }
        windows.removeAll()
        suspendedAt = nil
        displayLayout = []
    }

    /// Observes documented workspace state plus best-effort lock/saver distributed signals.
    private func observeSystemState() {
        let workspace = NSWorkspace.shared.notificationCenter
        for (start, end, reason) in [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, WallpaperPlaybackState.Suspension.sleeping),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, .displaysSleeping),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive),
        ] {
            observeSuspension(in: workspace, start: start, end: end, reason: reason)
        }
        let distributed = DistributedNotificationCenter.default()
        // These names are best-effort macOS observations, not a documented lock/security contract.
        observeSuspension(in: distributed, start: Notification.Name("com.apple.screenIsLocked"),
                          end: Notification.Name("com.apple.screenIsUnlocked"), reason: .locked)
        observeSuspension(in: distributed, start: Notification.Name("com.apple.screensaver.didstart"),
                          end: Notification.Name("com.apple.screensaver.didstop"), reason: .screenSaver)
        observe(distributed, name: Notification.Name("com.apple.screensaver.willstart")) { [weak self] in
            self?.setSuspended(.screenSaver, true)
        }
        observe(NotificationCenter.default, name: NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self, self.displayLayout != self.currentDisplayLayout else { return }
            self.reconcilePlayback(restart: true)
        }
    }

    /// Registers a matching pair of notifications for one independent suspension reason.
    private func observeSuspension(in center: NotificationCenter, start: Notification.Name, end: Notification.Name,
                                   reason: WallpaperPlaybackState.Suspension) {
        observe(center, name: start) { [weak self] in self?.setSuspended(reason, true) }
        observe(center, name: end) { [weak self] in self?.setSuspended(reason, false) }
    }

    /// Retains a main-thread notification registration until Quit.
    private func observe(_ center: NotificationCenter, name: Notification.Name, action: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in action() }
        observers.append((center, token))
    }

    /// Applies a system condition without starting a stopped or still-suspended session.
    private func setSuspended(_ reason: WallpaperPlaybackState.Suspension, _ suspended: Bool) {
        playback.setSuspended(reason, suspended)
        reconcilePlayback()
    }

    /// Removes observers and native animation work before the process exits.
    func applicationWillTerminate(_ notification: Notification) {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        removeDesktopWindows()
        optionsController?.configureSheet().close()
        optionsController = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
}
