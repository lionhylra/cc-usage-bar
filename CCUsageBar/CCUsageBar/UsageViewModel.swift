import AppKit
import Combine
import Darwin

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
        case waitingForBanner   // waiting for "Claude Code v2"
        case waitingForResult   // sent /usage, waiting for "Current session"
        case capturing          // collecting final output
    }

    private var childPid: pid_t = 0
    private var masterFd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timeoutWork: DispatchWorkItem?
    private var idleWork: DispatchWorkItem?
    private var stage: Stage = .waitingForBanner
    private var scanBuffer = ""
    private var accumulatedData = Data()

    func run() {
        cancelCurrent()
        accumulatedData = Data()
        scanBuffer = ""
        stage = .waitingForBanner
        state = .loading

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

        // Parent: read from PTY master asynchronously
        childPid = pid
        let capturedMaster = master

        let source = DispatchSource.makeReadSource(
            fileDescriptor: master,
            queue: .global(qos: .userInitiated)
        )
        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(capturedMaster, &buf, buf.count)
            guard n > 0 else { return }
            let chunk = Data(buf[0..<n])
            Task { @MainActor [weak self] in
                guard let self else { return }
                let text = String(data: chunk, encoding: .utf8)
                    ?? String(data: chunk, encoding: .isoLatin1)
                    ?? ""
                self.scanBuffer += self.stripANSI(text)
                switch self.stage {
                case .waitingForBanner:
                    if self.scanBuffer.contains("Welcome to Claude Code")
                        || self.scanBuffer.contains("Choose the text style that looks best with your terminal")
                        || self.scanBuffer.contains("Claude Code can be used with your Claude subscription") {
                        self.state = .needsSetup
                        self.cancelCurrent()
                        return
                    }
                    if self.scanBuffer.contains("Quick safety check") {
                        // Optional trust prompt — confirm and reset scan to await the banner.
                        self.scanBuffer = ""
                        DispatchQueue.global(qos: .userInitiated).async {
                            "\r".withCString { ptr in _ = write(capturedMaster, ptr, strlen(ptr)) }
                        }
                    } else if self.scanBuffer.range(of: "Claude Code v\\d+", options: .regularExpression) != nil {
                        self.stage = .waitingForResult
                        // Delay before sending command — the banner appears before the REPL
                        // is fully interactive. Send /usage then \r with a short gap.
                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
                            "/usage".withCString { ptr in _ = write(capturedMaster, ptr, strlen(ptr)) }
                            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
                                "\r".withCString { ptr in _ = write(capturedMaster, ptr, strlen(ptr)) }
                            }
                        }
                    }
                case .waitingForResult:
                    if self.scanBuffer.contains("rate_limit_error") {
                        self.state = .rateLimited
                        self.cancelCurrent()
                        return
                    }
                    if self.scanBuffer.contains("Current session") {
                        self.stage = .capturing
                        self.accumulatedData = chunk
                        self.scanBuffer = ""
                        self.rescheduleIdleTimer()
                    }
                case .capturing:
                    self.accumulatedData.append(chunk)
                    self.rescheduleIdleTimer()
                }
            }
        }
        source.setCancelHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.finalize()
            }
        }
        source.resume()
        readSource = source

        // 30-second timeout
        let timeout = DispatchWorkItem { [weak self] in
            self?.handleTimeout()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        timeoutWork = timeout

        // Safety net: if claude exits unexpectedly with non-zero code, surface the error.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let exitStatus = status
            Task { @MainActor [weak self] in
                guard let self else { return }
                if swiftWIFEXITED(exitStatus) && swiftWEXITSTATUS(exitStatus) != 0 {
                    let code = swiftWEXITSTATUS(exitStatus)
                    self.state = .error("claude exited with code \(code). Is it installed and on your PATH?")
                    self.cancelCurrent()
                }
                // Zero exit or signal: idle timer already handled finalize, nothing to do.
            }
        }
    }

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

    private func rescheduleIdleTimer() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.readSource?.cancel()  // triggers finalize() via cancel handler
            }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func finalize() {
        timeoutWork?.cancel()
        timeoutWork = nil
        idleWork?.cancel()
        idleWork = nil
        // Close the master fd here — this is the terminal cleanup point for the fd.
        // cancelCurrent() also guards with >= 0, so double-close is safe.
        if masterFd >= 0 { close(masterFd); masterFd = -1 }
        guard case .loading = state else { return }
        let raw = String(data: accumulatedData, encoding: .utf8)
            ?? String(data: accumulatedData, encoding: .isoLatin1)
            ?? ""
        state = .loaded(ANSIParser.parse(raw))
    }

    private func handleTimeout() {
        let stageName: String
        switch stage {
        case .waitingForBanner:    stageName = "waitingForBanner"
        case .waitingForResult:    stageName = "waitingForResult"
        case .capturing:           stageName = "capturing"
        }
        let tail = String(scanBuffer.suffix(500))
        // Set error BEFORE cancelling so finalize()'s guard exits early.
        state = .error("Timed out (stage: \(stageName))\n\nLast output:\n\(tail)")
        cancelCurrent()
    }

    func cancelCurrent() {
        timeoutWork?.cancel()
        timeoutWork = nil
        idleWork?.cancel()
        idleWork = nil
        readSource?.cancel()
        readSource = nil
        if childPid > 0 { kill(childPid, SIGTERM); childPid = 0 }
        if masterFd >= 0 { close(masterFd); masterFd = -1 }
    }
}
