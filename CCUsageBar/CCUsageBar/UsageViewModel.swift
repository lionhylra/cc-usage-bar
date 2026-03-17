import AppKit
import Combine
import Darwin
import OSLog

private let log = Logger(subsystem: "com.ccusagebar", category: "UsageViewModel")

// fork() is marked unavailable in Swift for thread-safety reasons, but we need it for PTY.
// Access it via dlsym to bypass the Swift-level unavailability annotation.
private let _fork: @convention(c) () -> pid_t = {
    let handle = dlopen(nil, RTLD_LAZY)
    let sym = dlsym(handle, "fork")
    return unsafeBitCast(sym, to: (@convention(c) () -> pid_t).self)
}()

// WIFEXITED and WEXITSTATUS are C macros not available in Swift — implement manually.
// From sys/wait.h: _WSTATUS(x) = (x & 0x7f), WIFEXITED = (_WSTATUS(x) == 0),
// WEXITSTATUS = ((x >> 8) & 0xff)
@inline(__always) private func swiftWIFEXITED(_ status: Int32) -> Bool {
    return (status & 0x7f) == 0
}
@inline(__always) private func swiftWEXITSTATUS(_ status: Int32) -> Int32 {
    return (status >> 8) & 0xff
}

enum UsageState {
    case idle
    case loading
    case loaded(NSAttributedString)
    case rateLimited
    case needsSetup
    case error(String)
}

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var state: UsageState = .idle

    private enum Stage {
        case idle               // session alive, no active query — discard incoming data
        case waitingForBanner   // waiting for "Claude Code v2"
        case waitingForResult   // sent /usage, waiting for "Current session"
        case capturing          // collecting final output
    }

    private var childPid: pid_t = 0
    private var masterFd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timeoutWork: DispatchWorkItem?
    private var idleWork: DispatchWorkItem?
    private var stage: Stage = .idle
    private var scanBuffer = ""
    private var accumulatedData = Data()

    // Incremented on every run(). Every async callback (Task, DispatchWorkItem) captures
    // the ID at creation time and bails out if it no longer matches — preventing stale
    // callbacks from a previous query from clobbering the new one.
    private var queryId = 0

    private var sessionLive: Bool { childPid > 0 && masterFd >= 0 }

    func run() {
        cancelQuery()
        queryId += 1
        let currentQueryId = queryId
        log.info("run() qid=\(currentQueryId) sessionLive=\(self.sessionLive) pid=\(self.childPid) fd=\(self.masterFd)")

        // Cancel and recreate the read source for each query.
        // A DispatchSourceRead on a PTY master FD can lose its kqueue registration
        // after extended inactivity on macOS, causing it to silently stop firing even
        // when new data arrives. Recreating it guarantees a fresh kernel event filter.
        readSource?.cancel()
        readSource = nil

        accumulatedData = Data()
        scanBuffer = ""
        state = .loading

        if sessionLive {
            // Reuse the existing claude session — send /usage directly.
            log.info("run() reusing session fd=\(self.masterFd)")
            stage = .waitingForResult
            let capturedMaster = masterFd
            readSource = makeReadSource(master: capturedMaster, queryId: currentQueryId)
            readSource?.resume()

            // ESC was already sent on popover dismiss (see dismissPopover()), so the
            // REPL is back at the › prompt. Mirror the first-launch timing with a short
            // delay before the command and a separate newline write.
            log.info("write /usage fd=\(capturedMaster)")
            let n = "/usage".withCString { ptr in write(capturedMaster, ptr, strlen(ptr)) }
            log.info("write /usage result=\(n) errno=\(errno)")
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
                log.info("write \\r fd=\(capturedMaster)")
                let n2 = "\r".withCString { ptr in write(capturedMaster, ptr, strlen(ptr)) }
                log.info("write \\r result=\(n2) errno=\(errno)")
            }
            scheduleTimeout(queryId: currentQueryId)
        } else {
            // Launch a fresh claude session.
            log.info("run() launching fresh session")
            stage = .waitingForBanner
            launchSession(queryId: currentQueryId)
        }
    }

    // MARK: - Session launch

    private func launchSession(queryId: Int) {
        // Open PTY master
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0 else {
            state = .error("Failed to open PTY: \(String(cString: strerror(errno)))")
            return
        }
        guard let slaveNamePtr = ptsname(master) else {
            close(master)
            state = .error("Failed to get PTY slave name")
            return
        }
        let slaveName = String(cString: slaveNamePtr)
        masterFd = master

        // Set PTY window size to match the popover width
        // Popover: 560px, padding: 12px each side → 536px usable
        // Menlo 13pt ≈ 7.8px per char → ~68 columns
        var winSize = winsize(ws_row: 24, ws_col: 68, ws_xpixel: 536, ws_ypixel: 0)
        _ = ioctl(master, UInt(TIOCSWINSZ), &winSize)

        let pid = _fork()
        guard pid >= 0 else {
            close(master)
            masterFd = -1
            state = .error("fork() failed: \(String(cString: strerror(errno)))")
            return
        }

        if pid == 0 {
            // Child: set up PTY as controlling terminal and exec claude
            close(master)
            _ = setsid()
            let slave = slaveName.withCString { open($0, O_RDWR) }
            guard slave >= 0 else { _exit(1) }
            _ = ioctl(slave, UInt(TIOCSCTTY), 0)
            _ = dup2(slave, STDIN_FILENO)
            _ = dup2(slave, STDOUT_FILENO)
            _ = dup2(slave, STDERR_FILENO)
            if slave > STDERR_FILENO { close(slave) }
            _ = setenv("TERM", "xterm-256color", 1)
            _ = setenv("COLORTERM", "truecolor", 1)
            // Start in an empty temp directory so Claude has no project context.
            var template = "/tmp/cc-usage-XXXXXX".utf8CString.map { $0 }
            if mkdtemp(&template) != nil {
                _ = chdir(template)
            }
            // Use login shell so claude is on PATH
            var args: [UnsafeMutablePointer<Int8>?] = [
                strdup("/bin/zsh"), strdup("-l"), strdup("-c"), strdup("claude"), nil
            ]
            execv("/bin/zsh", &args)
            _exit(127)
        }

        // Parent: attach read source and start monitoring
        childPid = pid
        log.info("launchSession() forked pid=\(pid) fd=\(master)")
        readSource = makeReadSource(master: master, queryId: queryId)
        readSource?.resume()

        scheduleTimeout(queryId: queryId)

        // Safety net: if claude exits unexpectedly, surface the error and mark session dead.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let exitStatus = status
            Task { @MainActor [weak self] in
                log.info("waitpid returned pid=\(pid) status=\(exitStatus) WIFEXITED=\(swiftWIFEXITED(exitStatus)) code=\(swiftWEXITSTATUS(exitStatus))")
                guard let self else { return }
                // Mark session dead if we haven't already replaced it with a new one.
                if self.childPid == pid {
                    log.info("marking session dead (childPid was \(pid))")
                    self.childPid = 0
                }
                // Only surface an exit error if we were actively loading.
                // Closing the PTY master (in teardownSession) sends SIGHUP to claude,
                // causing zsh to exit — expected and not an error.
                guard case .loading = self.state else { return }
                if swiftWIFEXITED(exitStatus) && swiftWEXITSTATUS(exitStatus) != 0 {
                    let code = swiftWEXITSTATUS(exitStatus)
                    self.state = .error("claude exited with code \(code). Is it installed and on your PATH?")
                    self.teardownSession()
                }
            }
        }
    }

    // MARK: - Read source

    private func makeReadSource(master: Int32, queryId: Int) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: master,
            queue: .global(qos: .userInitiated)
        )
        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(master, &buf, buf.count)
            if n <= 0 {
                log.warning("read() returned \(n) errno=\(errno) fd=\(master) qid=\(queryId)")
                return
            }
            let chunk = Data(buf[0..<n])
            log.debug("read \(n) bytes qid=\(queryId)")
            Task { @MainActor [weak self] in
                // Discard events from a previous query's source that fired after run()
                // incremented queryId and installed a fresh source.
                guard let self, self.queryId == queryId else {
                    log.debug("discarding stale event (currentQid=\(self?.queryId ?? -1) eventQid=\(queryId))")
                    return
                }
                let text = String(data: chunk, encoding: .utf8)
                    ?? String(data: chunk, encoding: .isoLatin1)
                    ?? ""
                self.scanBuffer += self.stripANSI(text)
                log.debug("stage=\(String(describing: self.stage)) scanBuf=\(self.scanBuffer.suffix(80))")
                switch self.stage {
                case .idle:
                    // Session alive but no active query — discard output.
                    break
                case .waitingForBanner:
                    if self.scanBuffer.contains("Welcome to Claude Code")
                        || self.scanBuffer.contains("Choose the text style that looks best with your terminal")
                        || self.scanBuffer.contains("Claude Code can be used with your Claude subscription") {
                        log.info("→ needsSetup detected")
                        self.state = .needsSetup
                        self.teardownSession()
                        return
                    }
                    if self.scanBuffer.contains("Quick safety check") {
                        // Optional trust prompt — confirm and reset scan to await the banner.
                        log.info("→ trust prompt, sending \\r")
                        self.scanBuffer = ""
                        DispatchQueue.global(qos: .userInitiated).async {
                            "\r".withCString { ptr in _ = write(master, ptr, strlen(ptr)) }
                        }
                    } else if self.scanBuffer.range(of: "Claude Code v\\d+", options: .regularExpression) != nil {
                        log.info("→ banner detected, sending /usage")
                        self.stage = .waitingForResult
                        // Delay before sending command — the banner appears before the REPL
                        // is fully interactive. Send /usage then \r with a short gap.
                        "/usage".withCString { ptr in _ = write(master, ptr, strlen(ptr)) }
                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
                            "\r".withCString { ptr in _ = write(master, ptr, strlen(ptr)) }
                        }
                    }
                case .waitingForResult:
                    if self.scanBuffer.contains("rate_limit_error") {
                        log.info("→ rate_limit_error detected")
                        self.state = .rateLimited
                        self.teardownSession()
                        return
                    }
                    if self.scanBuffer.contains("Current session") {
                        log.info("→ 'Current session' detected, entering capturing")
                        self.stage = .capturing
                        self.accumulatedData = Data()
                        self.scanBuffer = ""
                        // Force Ink to do a full re-render. Ink optimizes redraws
                        // by skipping unchanged characters with cursor-forward,
                        // but those skipped cells are blank in our virtual screen
                        // parser. A PTY resize sends SIGWINCH which makes Ink
                        // clear and redraw with every character written explicitly.
                        let fd = self.masterFd
                        if fd >= 0 {
                            DispatchQueue.global(qos: .userInitiated).async {
                                var ws = winsize(ws_row: 24, ws_col: 67, ws_xpixel: 0, ws_ypixel: 0)
                                _ = ioctl(fd, UInt(TIOCSWINSZ), &ws)
                                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
                                    var ws = winsize(ws_row: 24, ws_col: 68, ws_xpixel: 536, ws_ypixel: 0)
                                    _ = ioctl(fd, UInt(TIOCSWINSZ), &ws)
                                }
                            }
                        }
                        self.rescheduleIdleTimer(queryId: queryId)
                    }
                case .capturing:
                    self.accumulatedData.append(chunk)
                    self.rescheduleIdleTimer(queryId: queryId)
                }
            }
        }
        return source
    }

    // MARK: - Timers

    private func scheduleTimeout(queryId: Int) {
        let capturedId = queryId
        let timeout = DispatchWorkItem { [weak self] in
            self?.handleTimeout(queryId: capturedId)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        timeoutWork = timeout
    }

    private func rescheduleIdleTimer(queryId: Int) {
        idleWork?.cancel()
        let capturedId = queryId
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.finalize(queryId: capturedId)
            }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - Finalization

    private func finalize(queryId: Int) {
        // Discard stale finalize calls: either from a previous query (queryId mismatch)
        // or from a race where run() changed the stage before this Task ran.
        guard self.queryId == queryId, stage == .capturing else {
            log.info("finalize() skipped qid=\(queryId) currentQid=\(self.queryId) stage=\(String(describing: self.stage))")
            return
        }
        log.info("finalize() executing qid=\(queryId) accumulatedBytes=\(self.accumulatedData.count)")
        timeoutWork?.cancel()
        timeoutWork = nil
        idleWork?.cancel()
        idleWork = nil
        stage = .idle
        // PTY and process are kept alive for the next query.
        guard case .loading = state else { return }
        let raw = String(data: accumulatedData, encoding: .utf8)
            ?? String(data: accumulatedData, encoding: .isoLatin1)
            ?? ""
        let fullAttr = ANSIParser.parse(raw)
        // The SIGWINCH re-render includes the full Ink UI (input area,
        // tab bar, content). Trim to start from "Current session".
        let plain = fullAttr.string
        if let range = plain.range(of: "Current session") {
            let lineStart = plain[..<range.lowerBound].lastIndex(of: "\n")
                .map { plain.index(after: $0) }
                ?? plain.startIndex
            state = .loaded(fullAttr.attributedSubstring(from: NSRange(lineStart..<plain.endIndex, in: plain)))
        } else {
            state = .loaded(fullAttr)
        }
    }

    private func handleTimeout(queryId: Int) {
        guard self.queryId == queryId else {
            log.info("handleTimeout() skipped stale qid=\(queryId)")
            return
        }
        log.error("handleTimeout() fired qid=\(queryId) stage=\(String(describing: self.stage))")
        let stageName: String
        switch stage {
        case .idle:             stageName = "idle"
        case .waitingForBanner: stageName = "waitingForBanner"
        case .waitingForResult: stageName = "waitingForResult"
        case .capturing:        stageName = "capturing"
        }
        let tail = String(scanBuffer.suffix(500))
        // Set error BEFORE tearing down so finalize()'s guard exits early.
        state = .error("Timed out (stage: \(stageName))\n\nLast output:\n\(tail)")
        teardownSession()
    }

    // MARK: - ANSI

    private func stripANSI(_ text: String) -> String {
        // Replace ANSI sequences with a space (not empty) so cursor-movement commands
        // between words don't cause adjacent words to merge together.
        let stripped = text.replacingOccurrences(
            of: "\u{1B}(?:\\[[^@-~]*[@-~]|[^\\[])",
            with: " ",
            options: .regularExpression
        )
        // Collapse runs of spaces/tabs to a single space so trigger strings match cleanly.
        return stripped.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
    }

    // MARK: - Session lifecycle

    /// Called when the popover is dismissed. Sends ESC to exit the /usage view so
    /// the REPL is back at the › prompt before the next query, then cancels timers.
    func dismissPopover() {
        if sessionLive {
            let fd = masterFd
            log.info("dismissPopover() sending ESC fd=\(fd)")
            DispatchQueue.global(qos: .userInitiated).async {
                "\u{1B}".withCString { ptr in _ = write(fd, ptr, strlen(ptr)) }
            }
        }
        cancelQuery()
    }

    /// Cancels any in-progress query timers but keeps the claude session alive.
    func cancelQuery() {
        log.info("cancelQuery() stage=\(String(describing: self.stage))")
        timeoutWork?.cancel()
        timeoutWork = nil
        idleWork?.cancel()
        idleWork = nil
        stage = .idle
    }

    /// Full teardown: kills the claude process and closes the PTY.
    /// Called on timeout, rate-limit errors, and needs-setup conditions.
    func teardownSession() {
        log.info("teardownSession() pid=\(self.childPid) fd=\(self.masterFd)")
        cancelQuery()
        readSource?.cancel()
        readSource = nil
        if childPid > 0 { kill(childPid, SIGTERM); childPid = 0 }
        if masterFd >= 0 { close(masterFd); masterFd = -1 }
    }
}
