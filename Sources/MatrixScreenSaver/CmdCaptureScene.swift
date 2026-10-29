import Foundation
import Darwin

/// The drawing state snapshot the view uses to render the current cmd capture frame.
struct CmdCaptureRenderState {
    /// Visible output rows, including the partially typed bottom row.
    let lines: [String]
    /// Launching indicator, absent as soon as output arrives.
    let statusLine: String?
    /// Uses the same blink cadence as Neo messages, including while waiting for output.
    let cursorVisible: Bool
}

/// Types live command output into a bounded viewport, scrolling rather than clearing between rows.
struct CmdCaptureScene {
    /// Stages of capture presentation.
    enum Phase: Equatable {
        /// Waiting for a background capture result.
        case launching
        /// Appending rows and holding the completed output.
        case presenting
        /// Finished or skipped because the command was empty.
        case done
    }

    /// Default deadline for bounded standalone captures; live scene commands run until exit or cancellation.
    static let captureTimeout: TimeInterval = 12.0
    /// Indicator shown while the background task runs.
    static let statusLineText = "Querying..."

    /// Current presentation stage.
    private(set) var phase: Phase = .done
    /// All captured rows, clipped horizontally but retained for scrolling.
    private(set) var lines: [String] = []

    private var startTime: TimeInterval = 0
    private var lastAdvanceTime: TimeInterval = 0
    private var typedCharacters: Double = 0
    private var captureFinished = false
    private var holdStart: TimeInterval?
    private var viewportRows = 1
    private var characterCount = 0
    private var speedFactor: Double = 1

    /// Projected active duration, available only after the command finishes.
    private(set) var scheduledDuration: TimeInterval?

    /// Resets presentation without launching a command.
    /// Poll the background task's latest snapshot on active animation frames.
    ///
    /// - Parameters:
    ///   - startTime: Reference-relative time the scene begins.
    ///   - command: Command to capture. Empty skips straight to `.done`.
    ///   - speedFactor: Custom typing multiplier; 1 types 25 characters per second.
    mutating func reset(startTime: TimeInterval, command: String, speedFactor: Double = 1) {
        self.startTime = startTime
        self.speedFactor = speedFactor.isFinite && speedFactor > 0 ? speedFactor : 1
        typedCharacters = 0
        lastAdvanceTime = startTime
        captureFinished = false
        holdStart = nil
        lines = []
        scheduledDuration = nil
        phase = command.isEmpty ? .done : .launching
    }

    /// Applies the latest bounded output snapshot without restarting its typing progress.
    ///
    /// - Parameters:
    ///   - output: Captured command output.
    ///   - maxLines: Visible viewport height, clamped to at least one.
    ///   - maxColumns: Maximum characters per row, clamped to at least one.
    ///   - now: Same reference-relative clock used by ``advance(now:)``.
    ///   - isComplete: Whether the shell has exited; only then can the final hold begin.
    mutating func receiveCapture(_ output: String, maxLines: Int, maxColumns: Int, now: TimeInterval,
                                 isComplete: Bool = true) {
        guard phase != .done, !captureFinished else { return }
        if phase == .presenting { advance(now: now) }
        guard !output.isEmpty || isComplete else { return }
        viewportRows = max(maxLines, 1)
        var rows = output.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        if rows.last == "" { rows.removeLast() }
        lines = (rows.isEmpty ? ["(no output)"] : rows).map {
            String(String.UnicodeScalarView($0.unicodeScalars.prefix(max(maxColumns, 1))))
        }
        characterCount = lines.reduce(0) { $0 + $1.unicodeScalars.count } + max(lines.count - 1, 0)
        typedCharacters = min(typedCharacters, Double(characterCount))
        lastAdvanceTime = now
        captureFinished = isComplete
        if isComplete {
            scheduledDuration = max(now - startTime, 0) + (Double(characterCount) - typedCharacters) * 0.04 / speedFactor + 2.5
            if typedCharacters >= Double(characterCount) { holdStart = now }
        }
        phase = .presenting
    }

    /// Excludes a suspended interval without rebuilding the message schedule.
    ///
    /// - Parameter duration: Seconds during which animation was paused.
    mutating func shiftTimeline(by duration: TimeInterval) {
        startTime += duration
        lastAdvanceTime += duration
        if let holdStart { self.holdStart = holdStart + duration }
    }

    /// Advances the current message using the scene's reference-relative clock.
    ///
    /// - Parameter now: Current reference-relative time in seconds.
    mutating func advance(now: TimeInterval) {
        guard phase != .done else { return }
        if phase == .launching {
            lastAdvanceTime = now
            return
        }
        let needed = max(Double(characterCount) - typedCharacters, 0)
        let progress = max(0, now - lastAdvanceTime) * 25 * speedFactor
        typedCharacters = min(Double(characterCount), typedCharacters + progress)
        if captureFinished, typedCharacters >= Double(characterCount) {
            if holdStart == nil { holdStart = lastAdvanceTime + needed * 0.04 / speedFactor }
            if now >= holdStart! + 2.5 { phase = .done }
        }
        lastAdvanceTime = now
    }

    /// Snapshot for the native renderer at the current presentation stage.
    var renderState: CmdCaptureRenderState {
        let cursorVisible = Int(max(0, lastAdvanceTime - startTime) / NeoMessageScene.cursorBlinkInterval) % 2 == 0
        switch phase {
        case .done:
            return CmdCaptureRenderState(lines: [], statusLine: nil, cursorVisible: false)
        case .launching:
            return CmdCaptureRenderState(lines: [], statusLine: Self.statusLineText, cursorVisible: cursorVisible)
        case .presenting:
            var remaining = floor(typedCharacters)
            var currentRow = 0
            while currentRow < lines.count - 1 {
                let count = lines[currentRow].unicodeScalars.count
                if remaining < Double(count + 1) { break }
                remaining -= Double(count + 1)
                currentRow += 1
            }
            var visible = Array(lines[max(0, currentRow - viewportRows + 1)..<currentRow])
            let line = lines[currentRow]
            visible.append(String(String.UnicodeScalarView(line.unicodeScalars.prefix(Int(min(remaining, Double(line.unicodeScalars.count)))))))
            return CmdCaptureRenderState(lines: visible, statusLine: nil, cursorVisible: cursorVisible)
        }
    }
}

/// Single-use synchronous command capture with thread-safe cancellation.
/// Owns a process group so timeout/cancellation also stops ordinary shell pipelines.
/// Commands and captured payloads are never logged; host HOME and sandbox restrictions remain intact.
/// Descendants that deliberately create a new session/process group are outside this group's control.
final class CmdCaptureTask {
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private var latestOutput: String?
    private static let byteLimit = 64 * 1024
    private static let extraPathDirectories = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    /// Prevents launch or asks the running capture to stop; safe from any thread.
    /// Running work observes cancellation within its 20 ms poll interval, then cleans up.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Latest terminal buffer prefix, coalesced under the task lock rather than queued per read.
    /// Poll on active frames so a suspended renderer cannot accumulate delivery callbacks.
    var outputSnapshot: String? {
        lock.lock()
        defer { lock.unlock() }
        return latestOutput
    }

    /// Executes `/bin/sh -c` on the calling background thread, once per task.
    /// Stdout and stderr share a terminal so line-buffered programs publish promptly.
    /// Retains at most 64 KiB while draining excess bytes; cancellation always kills the process group.
    /// Cleanup adds at most 100 ms TERM grace and a one-second exit-event wait;
    /// a kernel-delayed exit is reaped by that event without blocking the caller further.
    ///
    /// - Parameters:
    ///   - command: Shell command, interpreted with the host environment and extended tool PATH.
    ///   - timeout: Finite positive deadline, or `nil` to run until exit or cancellation.
    ///   - size: Character dimensions exposed through COLUMNS, LINES and stdin's terminal size.
    /// - Returns: Combined terminal output, including partial output on timeout. Invalid UTF-8
    ///   uses replacement characters. Empty on cancellation, launch failure, or repeated use.
    func captureOutput(command: String, timeout: TimeInterval? = CmdCaptureScene.captureTimeout,
                       size: TerminalSize = TerminalSize(columns: 80, rows: 24)) -> String {
        guard !command.isEmpty, !command.utf8.contains(0),
              timeout.map({ $0.isFinite && $0 > 0 }) ?? true else { return "" }
        let deadline = timeout.map { ProcessInfo.processInfo.systemUptime + $0 } ?? .infinity
        var master: Int32 = -1
        var slave: Int32 = -1
        var windowSize = winsize(ws_row: UInt16(clamping: max(size.rows, 1)),
                                 ws_col: UInt16(clamping: max(size.columns, 1)), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &windowSize) == 0 else { return "" }
        defer { close(master); if slave >= 0 { close(slave) } }
        // Keep terminal-size ioctls available without waiting for input in an unattended host.
        var inputSettings = termios()
        guard tcgetattr(slave, &inputSettings) == 0 else { return "" }
        inputSettings.c_lflag &= ~tcflag_t(ICANON | ECHO)
        inputSettings.c_oflag &= ~tcflag_t(OPOST)
        withUnsafeMutableBytes(of: &inputSettings.c_cc) {
            $0[Int(VMIN)] = 0
            $0[Int(VTIME)] = 0
        }
        guard tcsetattr(slave, TCSANOW, &inputSettings) == 0 else { return "" }
        guard fcntl(master, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(slave, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(master, F_SETFL, O_NONBLOCK) == 0 else { return "" }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return "" }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return "" }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO) == 0 else { return "" }

        var environment = ProcessInfo.processInfo.environment
        environment["COLUMNS"] = String(windowSize.ws_col)
        environment["LINES"] = String(windowSize.ws_row)
        let existingPath = environment["PATH"] ?? ""
        let existingComponents = Set(existingPath.split(separator: ":").map(String.init))
        environment["PATH"] = (Self.extraPathDirectories.filter { !existingComponents.contains($0) } + [existingPath])
            .filter { !$0.isEmpty }.joined(separator: ":")
        let arguments = ["/bin/sh", "-c", command].map { strdup($0) }
        let variables = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { (arguments + variables).forEach { free($0) } }
        var argv = arguments + [nil]
        var envp = variables + [nil]
        var pid: pid_t = 0

        // Serialize the launch boundary with cancel so pre-launch cancellation cannot spawn.
        lock.lock()
        guard !cancelled, !started, ProcessInfo.processInfo.systemUptime < deadline else {
            lock.unlock()
            return ""
        }
        started = true
        let result = posix_spawn(&pid, "/bin/sh", &actions, &attributes, &argv, &envp)
        lock.unlock()
        guard result == 0 else { return "" }

        // Arm before observing exit, but do not reap until the process group has been killed.
        let reaped = DispatchSemaphore(value: 0)
        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        exitSource.setEventHandler {
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
            exitSource.cancel()
            exitSource.setEventHandler {}
            reaped.signal()
        }
        close(slave)
        slave = -1

        var stdout = Data()
        var outputOpen = true
        var completed = false
        while !isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
            let previousCount = stdout.count
            Self.drain(master, into: &stdout, open: &outputOpen)
            if stdout.count != previousCount {
                let snapshot = String(decoding: stdout, as: UTF8.self)
                lock.lock()
                latestOutput = snapshot
                lock.unlock()
            }
            var info = siginfo_t()
            // Keep the leader unreaped until group cleanup to prevent PID/group-ID reuse.
            let exited = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
            if exited && !outputOpen {
                completed = true
                break
            }
            var descriptors = [
                pollfd(fd: outputOpen ? master : -1, events: Int16(POLLIN), revents: 0),
            ]
            _ = poll(&descriptors, nfds_t(descriptors.count), 20)
        }

        if !completed {
            kill(-pid, SIGTERM)
            usleep(100_000)
        }
        // Kill remaining descendants even when the leader exited and closed both pipes.
        kill(-pid, SIGKILL)
        exitSource.resume()
        // Kernel-delayed exit must not block the caller; the exit event still reaps it later.
        _ = reaped.wait(timeout: .now() + 1)
        guard !isCancelled else { return "" }
        return String(decoding: stdout, as: UTF8.self)
    }

    /// Drains a bounded batch so a continuously writing child cannot starve cancellation checks.
    ///
    /// - Parameters:
    ///   - fd: Nonblocking read descriptor.
    ///   - data: Retained stream prefix, capped at ``byteLimit`` bytes.
    ///   - open: Cleared on EOF or a permanent read error; descriptor ownership stays with the caller.
    private static func drain(_ fd: Int32, into data: inout Data, open: inout Bool) {
        guard open else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<8 {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(min(count, byteLimit - data.count)))
            } else {
                if count == 0 || (errno != EAGAIN && errno != EINTR) { open = false }
                return
            }
        }
    }
}
