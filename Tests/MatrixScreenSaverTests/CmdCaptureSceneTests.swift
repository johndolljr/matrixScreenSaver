import Foundation
import Darwin

/// Runs unit tests for CmdCaptureScene and name-templated NeoMessageScene lines.
func cmdCaptureSceneTests() {
    // NeoMessageScene lines(forName:)
    let customLines = NeoMessageScene.lines(forName: "Trinity")
    ok(customLines.first == "Wake up, Trinity...", "NeoMessageScene: lines(forName:) uses custom name")
    ok(customLines.last == "Knock, knock, Trinity.", "NeoMessageScene: lines(forName:) uses custom name in closing line")

    let fallbackLines = NeoMessageScene.lines(forName: "")
    ok(fallbackLines.first == "Wake up, Neo...", "NeoMessageScene: empty name falls back to Neo")

    let whitespaceLines = NeoMessageScene.lines(forName: "   \t  ")
    ok(whitespaceLines.first == "Wake up, Neo...", "NeoMessageScene: whitespace name falls back to Neo")

    // CmdCaptureScene
    var scene = CmdCaptureScene()
    scene.reset(startTime: 100.0, command: "")
    ok(scene.phase == .done, "CmdCaptureScene: empty command resets immediately to done")

    scene.reset(startTime: 100.0, command: "echo hello")
    ok(scene.phase == .launching, "CmdCaptureScene: command resets to launching phase")
    ok(scene.scheduledDuration == nil, "CmdCaptureScene: scheduledDuration is nil while launching")

    scene.receiveCapture("abcdef\n\nsecond\nthird\n", maxLines: 2, maxColumns: 3, now: 101)
    ok(scene.lines == ["abc", "", "sec", "thi"],
       "CmdCaptureScene: clips width, preserves blank rows and retains output beyond screen height")
    ok(scene.renderState.lines == [""], "CmdCaptureScene: starts with an empty typing row")
    scene.advance(now: 101.13)
    ok(scene.renderState.lines == ["abc"], "CmdCaptureScene: types the first clipped row")
    scene.advance(now: 101.17)
    ok(scene.renderState.lines == ["abc", ""], "CmdCaptureScene: appends instead of clearing between rows")
    scene.advance(now: 101.25)
    ok(scene.renderState.lines == ["", "s"], "CmdCaptureScene: scrolls only the top row off when viewport fills")
    scene.shiftTimeline(by: 20)
    scene.advance(now: 121.25)
    ok(scene.renderState.lines == ["", "s"], "CmdCaptureScene: suspension preserves partially typed scrolling output")
    scene.advance(now: 122)
    ok(scene.renderState.lines == ["sec", "thi"], "CmdCaptureScene: final screen retains the last rows during hold")
    scene.advance(now: 130)
    ok(scene.phase == .done && scene.renderState.lines.isEmpty, "CmdCaptureScene: finishes after final hold")
    let duration = scene.scheduledDuration!
    scene.reset(startTime: 100, command: "next", speedFactor: 100)
    ok(scene.renderState.lines.isEmpty && scene.lines.isEmpty, "CmdCaptureScene: new command clears prior output")
    scene.receiveCapture("abcdef\n\nsecond\nthird\n", maxLines: 2, maxColumns: 3, now: 101)
    ok(scene.scheduledDuration! < duration, "CmdCaptureScene: independent custom speed accelerates output")

    var emptyOutputScene = CmdCaptureScene()
    emptyOutputScene.reset(startTime: 100.0, command: "true")
    emptyOutputScene.receiveCapture("", maxLines: 10, maxColumns: 50, now: 101.0)
    ok(emptyOutputScene.lines == ["(no output)"], "CmdCaptureScene: empty output falls back to placeholder")

    var live = CmdCaptureScene()
    live.reset(startTime: 100, command: "stream", speedFactor: 1)
    live.receiveCapture("one\n", maxLines: 2, maxColumns: 20, now: 101, isComplete: false)
    live.advance(now: 120)
    ok(live.phase == .presenting && live.renderState.lines == ["one"] && live.scheduledDuration == nil,
       "CmdCaptureScene: an idle live command keeps its visible rows without completing")
    live.receiveCapture("one\ntwo\n", maxLines: 2, maxColumns: 20, now: 121, isComplete: false)
    ok(live.renderState.lines == ["one"], "CmdCaptureScene: idle time does not pretype newly arriving output")
    live.advance(now: 121.2)
    ok(live.renderState.lines == ["one", "two"], "CmdCaptureScene: later output appends without retyping earlier rows")
    live.receiveCapture("one\ntwo\n", maxLines: 2, maxColumns: 20, now: 130)
    live.advance(now: 131)
    ok(live.phase == .presenting, "CmdCaptureScene: final hold starts at command exit, not first output")
    live.advance(now: 133)
    ok(live.phase == .done, "CmdCaptureScene: completes only after exit and final hold")
    live.reset(startTime: 100, command: "partial stream")
    live.receiveCapture("a", maxLines: 2, maxColumns: 20, now: 101, isComplete: false)
    live.advance(now: 110)
    live.receiveCapture("ab", maxLines: 2, maxColumns: 20, now: 111, isComplete: false)
    ok(live.renderState.lines == ["a"], "CmdCaptureScene: an unterminated row does not bank typing progress for its next character")
    live.advance(now: 111.05)
    ok(live.renderState.lines == ["ab"], "CmdCaptureScene: a partial-line update types only newly arrived characters")
    live.reset(startTime: 100, command: "cursor")
    ok(live.renderState.cursorVisible, "CmdCaptureScene: waiting for output starts with a visible cursor")
    live.advance(now: 100.55)
    ok(!live.renderState.cursorVisible, "CmdCaptureScene: waiting cursor blinks at the Neo cadence")
    live.receiveCapture("a\nb\nc", maxLines: 2, maxColumns: 20, now: 100.6, isComplete: false)
    live.advance(now: 101.1)
    ok(live.renderState.lines == ["b", "c"] && live.renderState.cursorVisible,
       "CmdCaptureScene: scrolling output retains its blinking cursor")
    live.shiftTimeline(by: 20)
    live.advance(now: 121.1)
    ok(live.renderState.cursorVisible, "CmdCaptureScene: suspension preserves the cursor blink phase")
    live.advance(now: 121.6)
    ok(!live.renderState.cursorVisible, "CmdCaptureScene: output cursor continues blinking while the command is idle")
    live.receiveCapture("a\nb\nc", maxLines: 2, maxColumns: 20, now: 122)
    live.advance(now: 125)
    ok(!live.renderState.cursorVisible, "CmdCaptureScene: completion removes the cursor")

    cmdCaptureTaskTests()
}

/// Exercises only authored commands, with all side effects confined to a fresh temporary directory.
func cmdCaptureTaskTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("matrix-capture-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        ok(false, "CmdCaptureTask: creates temporary sandbox")
        return
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("marker").path
    let ready = directory.appendingPathComponent("ready").path
    let late = directory.appendingPathComponent("late").path
    ok(CmdCaptureTask().captureOutput(command: "printf bad > '\(marker)'\0ignored").isEmpty && !FileManager.default.fileExists(atPath: marker),
       "CmdCaptureTask: embedded NUL cannot execute a truncated command")

    ok(CmdCaptureTask().captureOutput(command: "printf 'hello\\n'; printf 'diagnostic' >&2") == "hello\ndiagnostic", "CmdCaptureTask: stdout and stderr appear together in terminal order")
    ok(CmdCaptureTask().captureOutput(command: "printf '  '; printf 'diagnostic' >&2; exit 1") == "  diagnostic", "CmdCaptureTask: diagnostic output survives nonzero exit")
    ok(CmdCaptureTask().captureOutput(command: "printf '%s' \"$HOME\"") == (ProcessInfo.processInfo.environment["HOME"] ?? ""), "CmdCaptureTask: inherits host HOME")
    let dimensions = CmdCaptureTask().captureOutput(command: "printf '%s %s ' \"$COLUMNS\" \"$LINES\"; stty size",
                                                    size: TerminalSize(columns: 37, rows: 9))
    ok(dimensions == "37 9 9 37\n", "CmdCaptureTask: shell environment and native terminal report the viewport dimensions")
    ok(CmdCaptureTask().captureOutput(command: "printf before; /bin/cat; printf after", timeout: 1) == "beforeafter",
        "CmdCaptureTask: size-aware stdin returns EOF instead of blocking unattended readers")
    ok(CmdCaptureTask().captureOutput(command: "test -t 1 && test -t 2 && printf terminal") == "terminal",
       "CmdCaptureTask: both output streams are terminals so line-buffered programs flush promptly")
    let ping = CmdCaptureTask()
    let pingFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        _ = ping.captureOutput(command: "/sbin/ping -c 14 127.0.0.1", timeout: nil)
        pingFinished.signal()
    }
    let pingDeadline = ProcessInfo.processInfo.systemUptime + 1.5
    while ping.outputSnapshot?.contains("icmp_seq=0") != true && ProcessInfo.processInfo.systemUptime < pingDeadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    ok(ping.outputSnapshot?.contains("icmp_seq=0") == true && pingFinished.wait(timeout: .now()) == .timedOut,
       "CmdCaptureTask: real ping replies are observable before ping exits")
    ok(pingFinished.wait(timeout: .now() + 16) == .success && ping.outputSnapshot?.contains("14 packets transmitted") == true,
       "CmdCaptureTask: live ping runs beyond the former twelve-second limit and finishes with statistics")
    ok(CmdCaptureTask().captureOutput(command: "printf partial; sleep 2", timeout: 0.1) == "partial",
       "CmdCaptureTask: a bounded capture preserves partial output on timeout")

    let reusable = CmdCaptureTask()
    _ = reusable.captureOutput(command: "true")
    ok(reusable.captureOutput(command: "printf bad > '\(marker)'").isEmpty && !FileManager.default.fileExists(atPath: marker), "CmdCaptureTask: repeated execution cannot spawn")
    ok(CmdCaptureTask().captureOutput(command: "printf bad > '\(marker)'", timeout: .nan).isEmpty && !FileManager.default.fileExists(atPath: marker), "CmdCaptureTask: invalid timeout cannot spawn")

    let descriptorsBefore = (0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count
    for _ in 0..<5 { _ = CmdCaptureTask().captureOutput(command: "printf checked") }
    let descriptorsAfter = (0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count
    ok(descriptorsBefore == descriptorsAfter, "CmdCaptureTask: repeated captures close pipe descriptors")

    let flood = "(/usr/bin/head -c 262144 /dev/zero | /usr/bin/tr '\\000' x) & /usr/bin/head -c 262144 /dev/zero | /usr/bin/tr '\\000' e >&2; wait"
    let large = CmdCaptureTask().captureOutput(command: flood, timeout: 3)
    ok(large.utf8.count == 65536 && large.allSatisfy { $0 == "x" || $0 == "e" }, "CmdCaptureTask: drains simultaneous streams with bounded combined output")
    let largeError = CmdCaptureTask().captureOutput(command: "/usr/bin/head -c 262144 /dev/zero | /usr/bin/tr '\\000' e >&2", timeout: 3)
    ok(largeError.utf8.count == 65536, "CmdCaptureTask: stderr retention is bounded too")
    let unicodeBoundary = CmdCaptureTask().captureOutput(
        command: "/usr/bin/head -c 65535 /dev/zero | /usr/bin/tr '\\000' x; printf '\\303\\251'", timeout: 3)
    ok(unicodeBoundary.hasPrefix(String(repeating: "x", count: 65535)),
       "CmdCaptureTask: a UTF-8 sequence crossing the byte cap does not discard the valid prefix")

    let start = ProcessInfo.processInfo.systemUptime
    let timedOut = CmdCaptureTask().captureOutput(command: "exec 1>&- 2>&-; /bin/sleep 5", timeout: 0.1)
    ok(timedOut.isEmpty && ProcessInfo.processInfo.systemUptime - start < 1.5, "CmdCaptureTask: early EOF does not bypass timeout")

    let cancelled = CmdCaptureTask()
    cancelled.cancel()
    ok(cancelled.captureOutput(command: "printf bad > '\(marker)'").isEmpty && !FileManager.default.fileExists(atPath: marker), "CmdCaptureTask: cancellation before launch prevents side effects")

    let running = CmdCaptureTask()
    let finished = DispatchSemaphore(value: 0)
    let command = "trap '' TERM; (trap '' TERM; printf '%s' $$ > '\(ready)'; /bin/sleep 0.7; printf escaped > '\(late)') | /bin/cat; wait"
    DispatchQueue.global().async {
        _ = running.captureOutput(command: command, timeout: 3)
        finished.signal()
    }
    let readyDeadline = ProcessInfo.processInfo.systemUptime + 2
    while !FileManager.default.fileExists(atPath: ready) && ProcessInfo.processInfo.systemUptime < readyDeadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    ok(FileManager.default.fileExists(atPath: ready), "CmdCaptureTask: descendant pipeline starts")
    running.cancel()
    ok(finished.wait(timeout: .now() + 1.5) == .success, "CmdCaptureTask: cancellation of TERM-refusing pipeline is bounded")
    let pidText = (try? String(contentsOfFile: ready, encoding: .utf8)) ?? ""
    let pid = Int32(pidText) ?? 0
    ok(pid > 0 && kill(pid, 0) == -1 && errno == ESRCH, "CmdCaptureTask: cancelled shell is reaped")
    Thread.sleep(forTimeInterval: 0.8)
    ok(!FileManager.default.fileExists(atPath: late), "CmdCaptureTask: cancelled descendants cannot write later")

    let timeoutStart = ProcessInfo.processInfo.systemUptime
    _ = CmdCaptureTask().captureOutput(command: command, timeout: 0.1)
    ok(ProcessInfo.processInfo.systemUptime - timeoutStart < 1.5, "CmdCaptureTask: TERM-refusing pipeline timeout is bounded")
    Thread.sleep(forTimeInterval: 0.8)
    ok(!FileManager.default.fileExists(atPath: late), "CmdCaptureTask: timed-out descendants cannot write later")
}
