import Foundation
import PiCore

/// One thread: a live `pi --mode rpc` process plus the timeline the user sees.
///
/// The authoritative transcript always comes from pi — after every settled run this
/// asks pi for its entries rather than assembling messages locally. Streaming deltas
/// are kept as a separate overlay that exists only while a run is in flight, so a
/// half-assembled local guess can never become the record.
@MainActor
public final class ThreadSession: ObservableObject, Identifiable {
    public enum RunState: Equatable {
        case idle
        case starting
        case streaming
        case failed(String)

        public var isBusy: Bool {
            switch self {
            case .starting, .streaming: return true
            case .idle, .failed: return false
            }
        }
    }

    public let id: String
    /// Directory the agent runs in: the workspace root, or this thread's worktree.
    public let workingDirectory: URL
    /// Worktree backing this thread, when it was created in one.
    public let worktree: Worktree?

    @Published public private(set) var title: String
    @Published public private(set) var timeline: [TimelineItem] = []
    @Published public private(set) var runState: RunState = .idle
    /// Text streaming in from the current assistant message.
    @Published public private(set) var streamingText: String = ""
    /// Reasoning streaming in, shown separately from prose.
    @Published public private(set) var streamingThinking: String = ""
    /// Tool calls started but not yet finished in this run.
    @Published public private(set) var runningTools: [RunningTool] = []
    /// Messages queued while the agent is busy.
    @Published public private(set) var queuedMessages: [String] = []
    @Published public private(set) var modelName: String?
    @Published public private(set) var sessionFile: URL?
    @Published public private(set) var lastError: String?

    public struct RunningTool: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let arguments: JSONValue
        public var output: String
    }

    private let client: PiRPCClient
    private var eventTask: Task<Void, Never>?
    /// Read per refresh rather than captured at init, so toggling the setting takes
    /// effect on the next update instead of only for threads opened afterwards.
    private var showsThinking: Bool { Preferences.shared.showThinking }
    /// Error reported by the run in flight, so a failed run is not announced as a
    /// successful one when it settles.
    private var failureInCurrentRun: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        workingDirectory: URL,
        worktree: Worktree? = nil,
        configuration: PiRPCClient.Configuration
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.worktree = worktree
        client = PiRPCClient(configuration: configuration)
    }

    // MARK: - Lifecycle

    public func start() async {
        runState = .starting
        do {
            try await client.start()
            consumeEvents()
            await refreshFromPi()
            runState = .idle
        } catch {
            runState = .failed(String(describing: error))
            lastError = String(describing: error)
        }
    }

    public func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        await client.shutdown()
    }

    private func consumeEvents() {
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.client.events {
                await self.handle(event)
            }
        }
    }

    // MARK: - Sending

    /// Sends a prompt, choosing the right queue when the agent is already running.
    ///
    /// pi rejects a bare `prompt` mid-stream, so a message typed during a run is sent
    /// as a steer — the behavior that matches what a user expects when they interrupt.
    public func send(_ text: String, images: [PiImageContent] = []) async {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !images.isEmpty else { return }

        lastError = nil
        let busy = runState.isBusy
        if busy {
            queuedMessages.append(message)
        }

        do {
            try await client.send { requestID in
                .prompt(
                    id: requestID,
                    message: message,
                    images: images,
                    streamingBehavior: busy ? .steer : nil
                )
            }
            if !busy {
                runState = .streaming
                streamingText = ""
                streamingThinking = ""
                runningTools = []
            }
        } catch {
            queuedMessages.removeAll { $0 == message }
            lastError = String(describing: error)
        }
    }

    public func abort() async {
        do {
            try await client.send { .abort(id: $0) }
        } catch {
            lastError = String(describing: error)
        }
    }

    public func setModel(provider: String, modelId: String) async {
        do {
            try await client.send { .setModel(id: $0, provider: provider, modelId: modelId) }
            await refreshState()
        } catch {
            lastError = String(describing: error)
        }
    }

    public func rename(to newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await client.send { .setSessionName(id: $0, name: trimmed) }
            title = trimmed
        } catch {
            lastError = String(describing: error)
        }
    }

    public func availableModels() async -> [ModelOption] {
        guard let response = try? await client.send({ .getAvailableModels(id: $0) }),
              let models = response.data?["models"]?.arrayValue else { return [] }
        return models.compactMap(ModelOption.init(json:))
    }

    /// Runs a shell command through pi, so it lands in the session transcript the
    /// same way pi's own `!command` does.
    @discardableResult
    public func runShellCommand(_ command: String) async -> String? {
        defer { Task { await refreshFromPi() } }
        guard let response = try? await client.send({ .bash(id: $0, command: command) }) else { return nil }
        return response.data?["output"]?.stringValue
    }

    // MARK: - Events

    private func handle(_ event: PiRPCEvent) async {
        switch event.kind {
        case .agentStart:
            runState = .streaming
            streamingText = ""
            streamingThinking = ""
            runningTools = []
            failureInCurrentRun = nil

        case .messageUpdate:
            if let delta = event.textDelta {
                streamingText += delta
            }
            if let delta = event.thinkingDelta {
                streamingThinking += delta
            }

        case .toolExecutionStart:
            guard let id = event.toolCallId else { break }
            runningTools.append(RunningTool(
                id: id,
                name: event.toolName ?? "tool",
                arguments: event.payload["args"] ?? .object([:]),
                output: ""
            ))

        case .toolExecutionUpdate:
            guard let id = event.toolCallId,
                  let index = runningTools.firstIndex(where: { $0.id == id }) else { break }
            // pi streams partial tool output (bash as it runs); append what arrived.
            if let chunk = event.payload["output"]?.stringValue ?? event.payload["delta"]?.stringValue {
                runningTools[index].output += chunk
            }

        case .toolExecutionEnd:
            guard let id = event.toolCallId else { break }
            runningTools.removeAll { $0.id == id }

        case .messageEnd, .turnEnd:
            // A run can fail *after* the prompt was accepted: pi answers the command
            // with success, then the turn ends carrying stopReason "error" and an
            // errorMessage, with empty content. Observed against a real pi with bad
            // credentials — without this the run would report as a normal finish.
            if event.message?["stopReason"]?.stringValue == "error" {
                failureInCurrentRun = event.message?["errorMessage"]?.stringValue
                    ?? "The run failed."
            }

            // The finished message is now in pi's entries; drop the overlay so the
            // same text cannot render twice.
            streamingText = ""
            streamingThinking = ""
            await refreshFromPi()

        case .agentSettled:
            runState = .idle
            streamingText = ""
            streamingThinking = ""
            runningTools = []
            queuedMessages.removeAll()
            await refreshFromPi()

            // `agent_settled` — not `agent_end` — is the point at which pi will not
            // continue on its own through a retry, compaction or queued follow-up.
            // Notifying on agent_end would fire mid-run on every retry.
            if let failure = failureInCurrentRun {
                lastError = failure
                RunNotifier.shared.runFailed(threadTitle: title, message: failure)
            } else {
                RunNotifier.shared.runFinished(
                    threadTitle: title,
                    summary: timeline.last { $0.kind == .assistantMessage }?.text
                )
            }
            failureInCurrentRun = nil

        case .queueUpdate:
            if let pending = event.payload["queued"]?.arrayValue {
                queuedMessages = pending.compactMap { $0["message"]?.stringValue ?? $0.stringValue }
            }

        case .sessionInfoChanged:
            if let name = event.payload["name"]?.stringValue {
                title = name
            }

        case .extensionError:
            let message = event.payload["error"]?.stringValue ?? "An extension failed"
            lastError = message
            RunNotifier.shared.runFailed(threadTitle: title, message: message)

        case .autoRetryStart:
            lastError = nil

        default:
            break
        }
    }

    // MARK: - Reading state back from pi

    /// Rebuilds the timeline from pi's own entries — the source of truth.
    public func refreshFromPi() async {
        guard let response = try? await client.send({ .getEntries(id: $0) }),
              let rawEntries = response.data?["entries"]?.arrayValue else { return }

        let entries = rawEntries.compactMap(SessionEntry.init(json:))

        // pi reports the active leaf explicitly; that beats any local heuristic.
        let leafID = response.data?["leafId"]?.stringValue
        let branch = SessionTree(entries: entries).activeBranch(leafID: leafID)
        timeline = TimelineBuilder.build(branch: branch, includeThinking: showsThinking)

        if let name = entries.last(where: { $0.kind == .sessionInfo })?.sessionName {
            title = name
        }
    }

    public func refreshState() async {
        guard let response = try? await client.send({ .getState(id: $0) }) else { return }
        modelName = response.data?.path("model.name")?.stringValue
            ?? response.data?.path("model.id")?.stringValue
        if let file = response.data?["sessionFile"]?.stringValue {
            sessionFile = URL(fileURLWithPath: file)
        }
        if response.data?["isStreaming"]?.boolValue == true {
            runState = .streaming
        }
    }
}

/// A model offered by pi, flattened for the picker.
public struct ModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let provider: String
    public let reasoning: Bool
    public let contextWindow: Int?

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue,
              let provider = json["provider"]?.stringValue else { return nil }
        self.id = id
        self.provider = provider
        name = json["name"]?.stringValue ?? id
        reasoning = json["reasoning"]?.boolValue ?? false
        contextWindow = json["contextWindow"]?.intValue
    }

    public var displayName: String { "\(name) · \(provider)" }
}
