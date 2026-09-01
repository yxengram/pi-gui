import Foundation

/// One row in the conversation timeline.
///
/// The timeline is the product: a thread reads as user prompts, assistant prose, and
/// collapsible tool calls that pair a request with its result. Tool calls and their
/// results arrive as *separate* entries in the session file, so building this view
/// means joining them by `toolCallId` rather than rendering entries one-for-one.
public struct TimelineItem: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable {
        case userMessage
        case assistantMessage
        case toolCall
        case thinking
        case compactionSummary
        case branchSummary
        case notice
    }

    public struct ToolDetail: Sendable, Hashable {
        public let name: String
        public let arguments: JSONValue
        /// `nil` while the tool is still running.
        public let output: String?
        public let isError: Bool
        public let isRunning: Bool

        public init(name: String, arguments: JSONValue, output: String?, isError: Bool, isRunning: Bool) {
            self.name = name
            self.arguments = arguments
            self.output = output
            self.isError = isError
            self.isRunning = isRunning
        }

        public var summary: String {
            AgentMessageText.ToolCall(id: "", name: name, arguments: arguments).summary
        }
    }

    public let id: String
    public let kind: Kind
    public let text: String
    public let timestamp: Date?
    public let tool: ToolDetail?
    /// True while an assistant message is still streaming in.
    public let isStreaming: Bool

    public init(
        id: String,
        kind: Kind,
        text: String,
        timestamp: Date? = nil,
        tool: ToolDetail? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.timestamp = timestamp
        self.tool = tool
        self.isStreaming = isStreaming
    }
}

/// Projects a session's active branch into timeline rows.
public enum TimelineBuilder {
    /// Builds the timeline for one root-to-leaf branch.
    ///
    /// - Parameter includeThinking: whether reasoning blocks get their own rows.
    public static func build(branch: [SessionEntry], includeThinking: Bool = true) -> [TimelineItem] {
        // Tool results are their own entries and may arrive well after the call that
        // produced them, so index them up front and join by id.
        var resultsByToolCallID: [String: JSONValue] = [:]
        for entry in branch where entry.kind == .message {
            guard let message = entry.message,
                  message["role"]?.stringValue == "toolResult",
                  let toolCallID = message["toolCallId"]?.stringValue else { continue }
            resultsByToolCallID[toolCallID] = message
        }

        var items: [TimelineItem] = []

        for entry in branch {
            switch entry.kind {
            case .message:
                items.append(contentsOf: itemsForMessage(
                    entry: entry,
                    resultsByToolCallID: resultsByToolCallID,
                    includeThinking: includeThinking
                ))

            case .compaction:
                if let summary = entry.summary {
                    items.append(TimelineItem(
                        id: entry.id,
                        kind: .compactionSummary,
                        text: summary,
                        timestamp: entry.timestamp
                    ))
                }

            case .branchSummary:
                if let summary = entry.summary {
                    items.append(TimelineItem(
                        id: entry.id,
                        kind: .branchSummary,
                        text: summary,
                        timestamp: entry.timestamp
                    ))
                }

            case .customMessage:
                // Extension-injected context, shown only when the extension asked for it.
                guard entry.payload["display"]?.boolValue == true else { continue }
                let text = entry.payload["content"]?.stringValue
                    ?? AgentMessageText.plainText(from: entry.payload)
                if let text, !text.isEmpty {
                    items.append(TimelineItem(
                        id: entry.id,
                        kind: .notice,
                        text: text,
                        timestamp: entry.timestamp
                    ))
                }

            case .modelChange, .thinkingLevelChange, .sessionInfo, .label, .custom, .unknown:
                // State bookkeeping, not conversation. The header and settings surfaces
                // read these; the transcript stays conversation-first.
                continue
            }
        }

        return items
    }

    private static func itemsForMessage(
        entry: SessionEntry,
        resultsByToolCallID: [String: JSONValue],
        includeThinking: Bool
    ) -> [TimelineItem] {
        guard let message = entry.message, let role = message["role"]?.stringValue else { return [] }

        switch role {
        case "user":
            guard let text = AgentMessageText.plainText(from: message) else { return [] }
            return [TimelineItem(id: entry.id, kind: .userMessage, text: text, timestamp: entry.timestamp)]

        case "assistant":
            var items: [TimelineItem] = []

            if includeThinking, let thinking = AgentMessageText.thinkingText(from: message) {
                items.append(TimelineItem(
                    id: entry.id + ":thinking",
                    kind: .thinking,
                    text: thinking,
                    timestamp: entry.timestamp
                ))
            }

            if let text = AgentMessageText.plainText(from: message) {
                items.append(TimelineItem(
                    id: entry.id,
                    kind: .assistantMessage,
                    text: text,
                    timestamp: entry.timestamp
                ))
            }

            for call in AgentMessageText.toolCalls(from: message) {
                let result = resultsByToolCallID[call.id]
                items.append(TimelineItem(
                    id: call.id,
                    kind: .toolCall,
                    text: call.name,
                    timestamp: entry.timestamp,
                    tool: TimelineItem.ToolDetail(
                        name: call.name,
                        arguments: call.arguments,
                        output: result.flatMap { AgentMessageText.plainText(from: $0) },
                        isError: result?["isError"]?.boolValue ?? false,
                        // No result entry yet means the tool is still running — the
                        // spinner state the user sees mid-run.
                        isRunning: result == nil
                    )
                ))
            }

            // An assistant turn that produced neither prose nor a tool call still
            // deserves a row when it failed, so the error is not swallowed.
            if items.isEmpty, let errorMessage = message["errorMessage"]?.stringValue {
                items.append(TimelineItem(
                    id: entry.id,
                    kind: .notice,
                    text: errorMessage,
                    timestamp: entry.timestamp
                ))
            }
            return items

        case "toolResult":
            // Rendered as part of its tool call row, never on its own.
            return []

        case "bashExecution":
            let command = message["command"]?.stringValue ?? ""
            let output = AgentMessageText.plainText(from: message) ?? message["output"]?.stringValue
            return [TimelineItem(
                id: entry.id,
                kind: .toolCall,
                text: "bash",
                timestamp: entry.timestamp,
                tool: TimelineItem.ToolDetail(
                    name: "bash",
                    arguments: .object(["command": .string(command)]),
                    output: output,
                    isError: (message["exitCode"]?.intValue ?? 0) != 0,
                    isRunning: false
                )
            )]

        default:
            guard let text = AgentMessageText.plainText(from: message) else { return [] }
            return [TimelineItem(id: entry.id, kind: .notice, text: text, timestamp: entry.timestamp)]
        }
    }
}
