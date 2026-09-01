import Foundation

/// Drives one `pi --mode rpc` subprocess.
///
/// This is the whole of the app's agent runtime: prompts, model changes, session
/// navigation and shell execution are all commands on this pipe, and pi owns the
/// conversation, persistence and provider auth. Keeping the surface this thin is
/// deliberate — the GUI must not reimplement pi behavior it can ask pi to perform.
///
/// One client owns one session. Parallel threads mean parallel processes, which is
/// also what keeps their state isolated.
public actor PiRPCClient {
    public struct Configuration: Sendable {
        /// Directory the agent runs in — a workspace root or a git worktree.
        public var workingDirectory: URL
        /// Resume an existing session file; `nil` starts a fresh session.
        public var sessionFile: URL?
        /// Display name applied at startup for a new session.
        public var sessionName: String?
        /// Overrides pi's session storage root. `nil` uses `~/.pi/agent/sessions`.
        public var sessionDirectory: URL?
        public var model: String?
        public var provider: String?
        /// Absolute path to `pi`, when the user has pinned one in Settings.
        public var executableOverride: String?
        /// Extra arguments appended verbatim, for flags pi adds that this app predates.
        public var additionalArguments: [String]

        public init(
            workingDirectory: URL,
            sessionFile: URL? = nil,
            sessionName: String? = nil,
            sessionDirectory: URL? = nil,
            model: String? = nil,
            provider: String? = nil,
            executableOverride: String? = nil,
            additionalArguments: [String] = []
        ) {
            self.workingDirectory = workingDirectory
            self.sessionFile = sessionFile
            self.sessionName = sessionName
            self.sessionDirectory = sessionDirectory
            self.model = model
            self.provider = provider
            self.executableOverride = executableOverride
            self.additionalArguments = additionalArguments
        }

        func arguments() -> [String] {
            var arguments = ["--mode", "rpc"]
            if let sessionFile {
                arguments += ["--session", sessionFile.path]
            }
            if let sessionDirectory {
                arguments += ["--session-dir", sessionDirectory.path]
            }
            if let sessionName, !sessionName.isEmpty {
                arguments += ["--name", sessionName]
            }
            if let provider {
                arguments += ["--provider", provider]
            }
            if let model {
                arguments += ["--model", model]
            }
            return arguments + additionalArguments
        }
    }

    public enum State: Sendable, Equatable {
        case idle
        case running
        case exited(code: Int32)
        case failed(String)
    }

    private let configuration: Configuration
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var framer = JSONLFramer()
    private var pendingRequests: [String: CheckedContinuation<PiRPCResponse, Error>] = [:]
    private var nextRequestNumber = 0
    private var stderrBuffer = ""
    private var state: State = .idle

    private let eventStream: AsyncStream<PiRPCEvent>
    private let eventContinuation: AsyncStream<PiRPCEvent>.Continuation
    private let stateStream: AsyncStream<State>
    private let stateContinuation: AsyncStream<State>.Continuation

    public init(configuration: Configuration) {
        self.configuration = configuration
        let events = AsyncStream<PiRPCEvent>.makeStream(bufferingPolicy: .unbounded)
        eventStream = events.stream
        eventContinuation = events.continuation
        let states = AsyncStream<State>.makeStream(bufferingPolicy: .unbounded)
        stateStream = states.stream
        stateContinuation = states.continuation
    }

    /// Agent events, in arrival order.
    public nonisolated var events: AsyncStream<PiRPCEvent> { eventStream }
    /// Process lifecycle transitions.
    public nonisolated var states: AsyncStream<State> { stateStream }

    public var currentState: State { state }

    // MARK: - Lifecycle

    public func start() throws {
        guard process == nil else { return }

        let executable = try PiExecutable.resolve(override: configuration.executableOverride)

        let process = Process()
        process.executableURL = executable.url
        process.arguments = configuration.arguments()
        process.currentDirectoryURL = configuration.workingDirectory

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executable.augmentedPath
        // pi renders ANSI art and spinners when it believes it owns a terminal;
        // in RPC mode we want clean JSONL only.
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Both pipes must be drained. Leaving stderr unread lets its buffer fill and
        // wedges the child mid-write, which looks exactly like a hung agent.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.ingestStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.ingestStderr(data) }
        }
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { await self?.handleTermination(code: code) }
        }

        do {
            try process.run()
        } catch {
            throw PiRPCError.launchFailed(reason: error.localizedDescription)
        }

        self.process = process
        stdinHandle = stdinPipe.fileHandleForWriting
        transition(to: .running)
    }

    /// Ends the session by closing stdin, which lets pi flush its session file.
    /// `SIGTERM` is the fallback for a process that does not exit on its own.
    public func shutdown(gracePeriod: Duration = .seconds(5)) async {
        guard let process, process.isRunning else { return }

        try? stdinHandle?.close()
        stdinHandle = nil

        let deadline = ContinuousClock.now.advanced(by: gracePeriod)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Sending

    /// Sends a command and waits for its correlated response.
    ///
    /// Throws `PiRPCError.commandFailed` when pi reports `success: false`, so callers
    /// get a rejected prompt as an error rather than a silently ignored request.
    @discardableResult
    public func send(_ makeCommand: (String) -> PiRPCCommand) async throws -> PiRPCResponse {
        guard let stdinHandle, process?.isRunning == true else {
            throw PiRPCError.notRunning
        }

        nextRequestNumber += 1
        let requestID = "req-\(nextRequestNumber)"
        let command = makeCommand(requestID)

        let encoder = JSONEncoder()
        // Stable key order keeps captured transcripts diffable when debugging.
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(command)
        line.append(0x0A)

        let response: PiRPCResponse = try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
            do {
                try stdinHandle.write(contentsOf: line)
            } catch {
                pendingRequests.removeValue(forKey: requestID)
                continuation.resume(throwing: PiRPCError.launchFailed(reason: error.localizedDescription))
            }
        }

        guard response.success else {
            throw PiRPCError.commandFailed(
                command: response.command,
                message: response.error ?? "no reason given"
            )
        }
        return response
    }

    /// Fire-and-forget send for commands whose reply the caller does not await.
    public func post(_ command: PiRPCCommand) throws {
        guard let stdinHandle, process?.isRunning == true else {
            throw PiRPCError.notRunning
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(command)
        line.append(0x0A)
        try stdinHandle.write(contentsOf: line)
    }

    // MARK: - Receiving

    private func ingestStdout(_ data: Data) {
        let records: [Data]
        do {
            records = try framer.append(data)
        } catch {
            // A record over the cap means the stream is no longer trustworthy.
            failAllPending(with: PiRPCError.malformedRecord(reason: String(describing: error)))
            return
        }

        for record in records {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: record) else {
                // pi occasionally emits non-JSON noise on stdout (a crash trace, a
                // dependency's stray print). Skipping keeps the session alive rather
                // than tearing it down over a line we never needed.
                continue
            }
            guard let incoming = try? PiRPCIncoming(json: value) else { continue }

            switch incoming {
            case let .response(response):
                if let id = response.id, let continuation = pendingRequests.removeValue(forKey: id) {
                    continuation.resume(returning: response)
                }
            case let .event(event):
                eventContinuation.yield(event)
            }
        }
    }

    private func ingestStderr(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        stderrBuffer += text
        // Keep only the tail; startup banners are long and only the last words
        // matter when reporting why pi died.
        if stderrBuffer.count > 8192 {
            stderrBuffer = String(stderrBuffer.suffix(8192))
        }
    }

    private func handleTermination(code: Int32) {
        stdinHandle = nil
        process = nil
        failAllPending(with: PiRPCError.terminated(exitCode: code, stderr: stderrBuffer))
        transition(to: .exited(code: code))
        eventContinuation.finish()
        stateContinuation.finish()
    }

    private func failAllPending(with error: Error) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
    }

    private func transition(to next: State) {
        state = next
        stateContinuation.yield(next)
    }

    /// stderr tail, for surfacing why a run failed.
    public var diagnostics: String { stderrBuffer }
}
