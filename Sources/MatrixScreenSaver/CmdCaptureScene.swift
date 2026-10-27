import Foundation
import Darwin

/// The drawing state snapshot the view uses to render the current cmd capture frame.
struct CmdCaptureRenderState {
    /// Captured rows, already clipped to the display dimensions.
    let lines: [String]
    /// Number of rows currently revealed.
    let visibleLineCount: Int
    /// Launching indicator, absent after capture finishes.
    let statusLine: String?
}

/// Time-driven reveal and hold sequence for output supplied by a background capture task.
struct CmdCaptureScene {
    /// Stages of capture presentation.
    enum Phase: Equatable {
        /// Waiting for a background capture result.
        case launching
        /// Showing captured rows progressively.
        case revealing
        /// Keeping all captured rows visible.
        case holding
        /// Finished or skipped because the command was empty.
        case done
    }

    /// Rows revealed per active second.
    static let linesPerSecond: Double = 14.0
    /// Seconds the fully revealed output remains visible.
    static let holdDuration: TimeInterval = 2.5
    /// Maximum command and pipe-completion duration, excluding bounded cleanup.
    static let captureTimeout: TimeInterval = 12.0
    /// Indicator shown while the background task runs.
    static let statusLineText = "Querying..."

    /// Current presentation stage.
    private(set) var phase: Phase = .done
    /// Number of captured rows revealed so far.
    private(set) var visibleLineCount: Int = 0
    /// Captured rows clipped to display dimensions.
    private(set) var lines: [String] = []

    private var startTime: TimeInterval = 0
    private var captureElapsed: TimeInterval?
    private var revealEndElapsed: TimeInterval = 0
    private var holdEndElapsed: TimeInterval = 0

    /// Active duration of the scene; `nil` while still launching.
    var scheduledDuration: TimeInterval? {
        captureElapsed == nil ? nil : holdEndElapsed
    }

    /// Resets presentation without launching a command.
    /// Call ``CmdCaptureTask/captureOutput(command:timeout:)`` on a background queue,
    /// then deliver its result through ``receiveCapture(_:maxLines:maxColumns:now:)``.
    ///
    /// - Parameters:
    ///   - startTime: Reference-relative time the scene begins.
    ///   - command: Command to capture. Empty skips straight to `.done`.
    mutating func reset(startTime: TimeInterval, command: String) {
        self.startTime = startTime
        lines = []
        visibleLineCount = 0
        captureElapsed = nil
        revealEndElapsed = 0
        holdEndElapsed = 0
        phase = command.isEmpty ? .done : .launching
    }

    /// Records a capture result and schedules its reveal and hold.
    ///
    /// - Parameters:
    ///   - output: Captured command output.
    ///   - maxLines: Maximum retained nonempty rows, clamped to at least one.
    ///   - maxColumns: Maximum characters per row, clamped to at least one.
    ///   - now: Same reference-relative clock used by ``advance(now:)``.
    mutating func receiveCapture(_ output: String, maxLines: Int, maxColumns: Int, now: TimeInterval) {
        guard phase == .launching else { return }
        let trimmedLines = output
            .split(separator: "\n", maxSplits: max(maxLines, 1), omittingEmptySubsequences: true)
            .prefix(max(maxLines, 1))
            .map { String($0.prefix(max(maxColumns, 1))) }
        lines = trimmedLines.isEmpty ? ["(no output)"] : trimmedLines

        let elapsed = max(now - startTime, 0)
        captureElapsed = elapsed
        let revealDuration = Double(lines.count) / Self.linesPerSecond
        revealEndElapsed = elapsed + revealDuration
        holdEndElapsed = revealEndElapsed + Self.holdDuration
        phase = .revealing
    }

    /// Excludes a suspended interval without rebuilding the reveal schedule.
    ///
    /// - Parameter duration: Seconds during which animation was paused.
    mutating func shiftTimeline(by duration: TimeInterval) {
        startTime += duration
    }

    /// Updates the reveal stage using the scene's reference-relative clock.
    ///
    /// - Parameter now: Current reference-relative time in seconds.
    mutating func advance(now: TimeInterval) {
        guard phase != .done else { return }
        guard let captureElapsed else { return }
        let sceneTime = now - startTime

        if sceneTime < captureElapsed {
            visibleLineCount = 0
            phase = .revealing
        } else if sceneTime < revealEndElapsed {
            let revealElapsed = sceneTime - captureElapsed
            visibleLineCount = min(lines.count, Int(revealElapsed * Self.linesPerSecond) + 1)
            phase = .revealing
        } else if sceneTime < holdEndElapsed {
            visibleLineCount = lines.count
            phase = .holding
        } else {
            visibleLineCount = lines.count
            phase = .done
        }
    }

    /// Snapshot for the native renderer at the current presentation stage.
    var renderState: CmdCaptureRenderState {
        switch phase {
        case .done:
            return CmdCaptureRenderState(lines: [], visibleLineCount: 0, statusLine: nil)
        case .launching:
            return CmdCaptureRenderState(lines: [], visibleLineCount: 0, statusLine: Self.statusLineText)
        case .revealing, .holding:
            return CmdCaptureRenderState(lines: lines, visibleLineCount: visibleLineCount, statusLine: nil)
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

    /// Executes `/bin/sh -c` on the calling background thread, once per task.
    /// Retains at most 64 KiB per stream while draining excess bytes. One monotonic
    /// deadline covers both child exit and pipe EOF, followed by TERM/KILL cleanup.
    /// Cleanup adds at most 100 ms TERM grace and a one-second exit-event wait;
    /// a kernel-delayed exit is reaped by that event without blocking the caller further.
    ///
    /// - Parameters:
    ///   - command: Shell command, interpreted with the host environment and extended tool PATH.
    ///   - timeout: Finite positive deadline in seconds; invalid values prevent execution.
    /// - Returns: UTF-8 stdout, or stderr when stdout is blank. Empty on cancellation,
    ///   timeout, invalid UTF-8, launch failure, or repeated use. Nonzero exit may still yield output.
    func captureOutput(command: String, timeout: TimeInterval = CmdCaptureScene.captureTimeout) -> String {
        guard !command.isEmpty, !command.utf8.contains(0), timeout.isFinite, timeout > 0 else { return "" }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        guard var outputPipe = Self.makePipe() else { return "" }
        defer { outputPipe.forEach { close($0) } }
        guard var errorPipe = Self.makePipe() else { return "" }
        defer { errorPipe.forEach { close($0) } }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return "" }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return "" }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO) == 0 else { return "" }

        var environment = ProcessInfo.processInfo.environment
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
        close(outputPipe[1])
        close(errorPipe[1])
        outputPipe[1] = -1
        errorPipe[1] = -1

        var stdout = Data()
        var stderr = Data()
        var outputOpen = true
        var errorOpen = true
        var completed = false
        while !isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
            Self.drain(outputPipe[0], into: &stdout, open: &outputOpen)
            Self.drain(errorPipe[0], into: &stderr, open: &errorOpen)
            var info = siginfo_t()
            // Keep the leader unreaped until group cleanup to prevent PID/group-ID reuse.
            let exited = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
            if exited && !outputOpen && !errorOpen {
                completed = true
                break
            }
            var descriptors = [
                pollfd(fd: outputOpen ? outputPipe[0] : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: errorOpen ? errorPipe[0] : -1, events: Int16(POLLIN), revents: 0),
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
        guard completed, !isCancelled else { return "" }
        let output = String(data: stdout, encoding: .utf8) ?? ""
        let error = String(data: stderr, encoding: .utf8) ?? ""
        return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !error.isEmpty ? error : output
    }

    /// Creates a pipe above standard descriptors, with a nonblocking reader and close-on-exec endpoints.
    ///
    /// - Returns: Reader and writer descriptors owned by the caller, or `nil` on setup failure.
    private static func makePipe() -> [Int32]? {
        var raw: [Int32] = [0, 0]
        guard pipe(&raw) == 0 else { return nil }
        defer { raw.forEach { close($0) } }
        let reader = fcntl(raw[0], F_DUPFD_CLOEXEC, 3)
        guard reader >= 0 else { return nil }
        let writer = fcntl(raw[1], F_DUPFD_CLOEXEC, 3)
        guard writer >= 0 else { close(reader); return nil }
        guard fcntl(reader, F_SETFL, O_NONBLOCK) == 0 else {
            close(reader)
            close(writer)
            return nil
        }
        return [reader, writer]
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
