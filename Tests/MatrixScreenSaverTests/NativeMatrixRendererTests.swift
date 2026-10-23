import Foundation

func nativeMatrixRendererTests() {
    ok(NativeMatrixRenderer().seedOffset == 0,
       "NativeMatrixRenderer: seedOffset defaults to 0")

    let palette = NativeMatrixRenderer().levelColors
    let hasNoPureWhite = !palette.contains { color in
        color.red == 255 && color.green == 255 && color.blue == 255
    }
    ok(hasNoPureWhite,
       "NativeMatrixRenderer: palette avoids pure white highlight")

    let hasMaxGreenHighlight = palette.contains { color in
        color.green == 255
    }
    ok(hasMaxGreenHighlight,
       "NativeMatrixRenderer: palette keeps max-green highlight")

    let r1: NativeMatrixRenderer = .init()
    let r2: NativeMatrixRenderer = .init()
    r1.seedOffset = 0
    r2.seedOffset = 0xDEAD_BEEF
    var cfg = NativeMatrixRenderer.Configuration()
    cfg.neoMessageSceneEnabled = false
    cfg.numberSceneEnabled = false
    r1.resize(to: TerminalSize(columns: 40, rows: 20))
    r2.resize(to: TerminalSize(columns: 40, rows: 20))
    r1.updateConfiguration(cfg)
    r2.updateConfiguration(cfg)
    r1.start()
    r2.start()
    for _ in 0..<60 { r1.advance(); r2.advance() }
    let differ = (0..<20).contains { row in (0..<40).contains { col in r1[row, col] != r2[row, col] } }
    ok(differ, "NativeMatrixRenderer: renderers with different seedOffsets diverge after 60 frames")

    var neo = NeoMessageScene()
    neo.reset(startTime: 100, seed: 1)
    neo.advance(now: 100.25)
    let before = neo.renderState
    neo.shiftTimeline(by: 3600)
    neo.advance(now: 3700.25)
    let after = neo.renderState
    ok(before.currentLine == after.currentLine && before.visibleCharCount == after.visibleCharCount && before.cursorVisible == after.cursorVisible,
       "NeoMessageScene: suspension preserves text and cursor rather than skipping the intro")

    let paused = NativeMatrixRenderer()
    var intro = NativeMatrixRenderer.Configuration()
    intro.neoMessageSpeedFactor = 0.1
    paused.updateConfiguration(intro)
    paused.resize(to: TerminalSize(columns: 40, rows: 20))
    paused.overrideSceneStartTime = Date.timeIntervalSinceReferenceDate - 0.25
    paused.start()
    Thread.sleep(forTimeInterval: 0.05)
    paused.advance()
    let cursorBefore = paused.neoSceneCursor
    let rain = NativeMatrixRenderer()
    cfg.twinkleEnabled = false
    rain.updateConfiguration(cfg)
    rain.resize(to: TerminalSize(columns: 40, rows: 20))
    rain.start()
    let rainBefore = (0..<20).flatMap { row in (0..<40).map { rain[row, $0] } }
    let pauseStart = Date.timeIntervalSinceReferenceDate
    Thread.sleep(forTimeInterval: 1.2)
    let pausedDuration = Date.timeIntervalSinceReferenceDate - pauseStart
    paused.shiftTimeline(by: pausedDuration)
    rain.shiftTimeline(by: pausedDuration)
    paused.advance()
    rain.advance()
    let rainAfter = (0..<20).flatMap { row in (0..<40).map { rain[row, $0] } }
    ok(rainBefore == rainAfter, "NativeMatrixRenderer: rain cells retain their positions across suspension")
    let cursorAfter = paused.neoSceneCursor
    ok(cursorBefore != nil && cursorBefore?.column == cursorAfter?.column && cursorBefore?.visible == cursorAfter?.visible,
       "NativeMatrixRenderer: resuming excludes suspended time without resetting the intro")

    let early = NativeMatrixRenderer(), late = NativeMatrixRenderer(), lateStartup = NativeMatrixRenderer()
    var scripted = NativeMatrixRenderer.Configuration()
    scripted.neoMessageLines = ["X"]
    scripted.neoMessageSpeedFactor = 1000
    let sharedStart = Date.timeIntervalSinceReferenceDate - 3
    var schedule = NeoMessageScene()
    schedule.reset(startTime: sharedStart, seed: UInt64(bitPattern: Int64(sharedStart)) &+ 1,
                   lines: scripted.neoMessageLines, speedFactor: scripted.neoMessageSpeedFactor)
    for renderer in [early, late] {
        renderer.updateConfiguration(scripted)
        renderer.resize(to: TerminalSize(columns: 100, rows: 12))
        renderer.overrideSceneStartTime = sharedStart
        renderer.start()
    }
    early.advanceToNextScene()
    let suspendedAt = Date.timeIntervalSinceReferenceDate
    Thread.sleep(forTimeInterval: 1.2)
    let duration = Date.timeIntervalSinceReferenceDate - suspendedAt
    early.shiftTimeline(by: duration)
    late.shiftTimeline(by: duration)
    late.advanceToNextScene()
    lateStartup.updateConfiguration(scripted)
    lateStartup.resize(to: TerminalSize(columns: 100, rows: 12))
    lateStartup.overrideSceneStartTime = sharedStart + duration
    lateStartup.overrideSceneContentStartTime = sharedStart
    lateStartup.start()
    lateStartup.advanceToNextScene()
    let timestamp = Date(timeIntervalSinceReferenceDate: sharedStart + schedule.scheduledDuration + 2)
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd-yy"
    let dateText = formatter.string(from: timestamp)
    formatter.dateFormat = "H:mm:ss"
    let expectedText = "Call trans opt: received. \(dateText) \(formatter.string(from: timestamp)) REC:Log>"
    var typingRNG = Xorshift64(seed: UInt64(bitPattern: Int64(sharedStart)) &+ 2)
    let typingDuration = NativeMatrixRenderer.naturalTypingTimings(for: expectedText,
                                                                 baseInterval: 1.0 / 40 / scripted.neoMessageSpeedFactor,
                                                                 rng: &typingRNG).last ?? 0
    let typingTime = sharedStart + duration + schedule.scheduledDuration + 2 + typingDuration + 0.1
    Thread.sleep(forTimeInterval: max(0, typingTime - Date.timeIntervalSinceReferenceDate))
    early.advance()
    late.advance()
    lateStartup.advance()
    let row = NativeMatrixRenderer.contentMargin
    let earlyText = (0..<100).map { early[row, $0].scalar }
    let lateText = (0..<100).map { late[row, $0].scalar }
    let startupText = (0..<100).map { lateStartup[row, $0].scalar }
    ok(String(String.UnicodeScalarView(earlyText)).contains(expectedText) && earlyText == lateText,
       "NativeMatrixRenderer: pause between display phase advances preserves identical Number-scene timestamps")
    ok(earlyText == startupText, "NativeMatrixRenderer: a display starting after resume keeps the same scripted content and seed")
}
