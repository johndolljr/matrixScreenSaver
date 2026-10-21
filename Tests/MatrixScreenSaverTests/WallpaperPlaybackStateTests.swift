import Foundation

/// Verifies user intent remains independent of overlapping system suspension reasons.
func wallpaperPlaybackStateTests() {
    var state = WallpaperPlaybackState()
    ok(state.shouldRun, "WallpaperPlaybackState: launches with playback requested")
    state.setSuspended(.locked, true)
    state.setSuspended(.locked, true)
    state.setSuspended(.sleeping, true)
    ok(!state.shouldRun, "WallpaperPlaybackState: duplicate and overlapping suspension is idempotent")
    state.setSuspended(.sleeping, false)
    ok(!state.shouldRun, "WallpaperPlaybackState: waking does not override lock")
    state.isRequested = false
    state.setSuspended(.locked, false)
    ok(!state.shouldRun, "WallpaperPlaybackState: Stop while suspended survives unlocking")
    state.setSuspended(.screenSaver, true)
    state.isRequested = true
    ok(!state.shouldRun, "WallpaperPlaybackState: Start does not override an active screen saver")
    state.setSuspended(.screenSaver, false)
    ok(state.shouldRun, "WallpaperPlaybackState: resumes after the last suspension clears")
    for reason in [WallpaperPlaybackState.Suspension.sessionInactive, .displaysSleeping] {
        state.setSuspended(reason, true)
    }
    state.setSuspended(.sessionInactive, false)
    ok(!state.shouldRun, "WallpaperPlaybackState: session activation does not override display sleep")
    state.setSuspended(.displaysSleeping, false)
    state.setSuspended(.displaysSleeping, false)
    ok(state.shouldRun, "WallpaperPlaybackState: duplicate resume notifications are harmless")
}
