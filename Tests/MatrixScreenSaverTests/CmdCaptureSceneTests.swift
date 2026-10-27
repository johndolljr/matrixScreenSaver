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

    scene.receiveCapture("line 1\nline 2\nline 3\n", maxLines: 2, maxColumns: 50, now: 101.0)
    ok(scene.phase == .revealing, "CmdCaptureScene: receiveCapture transitions to revealing phase")
    ok(scene.lines.count == 2, "CmdCaptureScene: receiveCapture caps lines to maxLines")
    ok(scene.lines == ["line 1", "line 2"], "CmdCaptureScene: receiveCapture parses output correctly")
    ok(scene.scheduledDuration != nil, "CmdCaptureScene: scheduledDuration is populated after capture")

    scene.advance(now: 101.0)
    ok(scene.visibleLineCount == 1, "CmdCaptureScene: first line reveals immediately")
    scene.shiftTimeline(by: 20)
    scene.advance(now: 121.08)
    ok(scene.visibleLineCount == 2 && scene.phase == .revealing, "CmdCaptureScene: suspension preserves progressive reveal")
    scene.advance(now: 121.2)
    ok(scene.phase == .holding, "CmdCaptureScene: holds after revealing all lines")
    scene.shiftTimeline(by: -20)

    var emptyOutputScene = CmdCaptureScene()
    emptyOutputScene.reset(startTime: 100.0, command: "true")
    emptyOutputScene.receiveCapture("", maxLines: 10, maxColumns: 50, now: 101.0)
    ok(emptyOutputScene.lines == ["(no output)"], "CmdCaptureScene: empty output falls back to placeholder")

    // Advance past reveal and hold
    let totalDuration = scene.scheduledDuration ?? 0
    scene.advance(now: 100.0 + totalDuration + 1.0)
    ok(scene.phase == .done, "CmdCaptureScene: advance past hold duration transitions to done")

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

    ok(CmdCaptureTask().captureOutput(command: "printf 'hello\\n'; printf 'diagnostic' >&2") == "hello\n", "CmdCaptureTask: stdout takes priority")
    ok(CmdCaptureTask().captureOutput(command: "printf '  '; printf 'diagnostic' >&2; exit 1") == "diagnostic", "CmdCaptureTask: stderr fallback survives nonzero exit")
    ok(CmdCaptureTask().captureOutput(command: "printf '%s' \"$HOME\"") == (ProcessInfo.processInfo.environment["HOME"] ?? ""), "CmdCaptureTask: inherits host HOME")

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
    ok(large.utf8.count == 65536 && large.allSatisfy { $0 == "x" }, "CmdCaptureTask: drains simultaneous streams with bounded retained output")
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
