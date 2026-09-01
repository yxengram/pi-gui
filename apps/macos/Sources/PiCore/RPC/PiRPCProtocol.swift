import Foundation

// MARK: - Commands

/// A command sent to `pi --mode rpc` on stdin, one JSON object per line.
///
/// Every command carries an optional `id` that pi echoes back on the matching
/// response, which is how `PiRPCClient` correlates concurrent requests.
public struct PiRPCCommand: Encodable, Sendable {
    public let id: String?
    public let type: String
    /// Command-specific fields, merged into the top level of the encoded object.
    public let arguments: [String: JSONValue]

    public init(id: String?, type: String, arguments: [String: JSONValue] = [:]) {
        self.id = id
        self.type = type
        self.arguments = arguments
    }

    private struct CodingKeysDynamic: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
        init(_ name: String) { stringValue = name }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeysDynamic.self)
        // `type` and `id` are reserved by the envelope; arguments may not shadow them.
        for (key, value) in arguments where key != "type" && key != "id" {
            try container.encode(value, forKey: CodingKeysDynamic(key))
        }
        try container.encode(type, forKey: CodingKeysDynamic("type"))
        if let id {
            try container.encode(id, forKey: CodingKeysDynamic("id"))
        }
    }
}

/// How a prompt should behave when the agent is already streaming.
///
/// pi rejects a bare `prompt` during streaming, so the UI must say which queue the
/// message joins.
public enum PiStreamingBehavior: String, Codable, Sendable {
    /// Delivered after the current assistant turn finishes its tool calls,
    /// before the next LLM call.
    case steer
    /// Delivered only once the agent has fully stopped.
    case followUp
}

public enum PiThinkingLevel: String, Codable, Sendable, CaseIterable {
    case off, minimal, low, medium, high, xhigh, max
}

extension PiRPCCommand {
    public static func prompt(
        id: String? = nil,
        message: String,
        images: [PiImageContent] = [],
        streamingBehavior: PiStreamingBehavior? = nil
    ) -> PiRPCCommand {
        var arguments: [String: JSONValue] = ["message": .string(message)]
        if !images.isEmpty {
            arguments["images"] = .array(images.map(\.jsonValue))
        }
        if let streamingBehavior {
            arguments["streamingBehavior"] = .string(streamingBehavior.rawValue)
        }
        return PiRPCCommand(id: id, type: "prompt", arguments: arguments)
    }

    public static func steer(id: String? = nil, message: String, images: [PiImageContent] = []) -> PiRPCCommand {
        var arguments: [String: JSONValue] = ["message": .string(message)]
        if !images.isEmpty {
            arguments["images"] = .array(images.map(\.jsonValue))
        }
        return PiRPCCommand(id: id, type: "steer", arguments: arguments)
    }

    public static func followUp(id: String? = nil, message: String, images: [PiImageContent] = []) -> PiRPCCommand {
        var arguments: [String: JSONValue] = ["message": .string(message)]
        if !images.isEmpty {
            arguments["images"] = .array(images.map(\.jsonValue))
        }
        return PiRPCCommand(id: id, type: "follow_up", arguments: arguments)
    }

    public static func abort(id: String? = nil) -> PiRPCCommand {
        PiRPCCommand(id: id, type: "abort")
    }

    public static func getState(id: String? = nil) -> PiRPCCommand {
        PiRPCCommand(id: id, type: "get_state")
    }

    public static func getEntries(id: String? = nil) -> PiRPCCommand {
        PiRPCCommand(id: id, type: "get_entries")
    }

    public static func getTree(id: String? = nil) -> PiRPCCommand {
        PiRPCCommand(id: id, type: "get_tree")
    }

    public static func getMessages(id: String? = nil) -> PiRPCCommand {
        PiRPCCommand(id: id, type: "get_messages")
    }

    public static func getAvailableModels(id: String? = nil) -> PiRPCCommand {
        PiRPCCommand(id: id, type: "get_available_models")
    }

    public static func getCommands(id: String? = nil) -> PiRPCCommand {
        PiRPCCommand(id: id, type: "get_commands")
    }

    public static func getSessionStats(id: String? = nil) -> PiRPCCommand {
        PiRPCCommand(id: id, type: "get_session_stats")
    }

    public static func setModel(id: String? = nil, provider: String, modelId: String) -> PiRPCCommand {
        PiRPCCommand(
            id: id,
            type: "set_model",
            arguments: ["provider": .string(provider), "model": .string(modelId)]
        )
    }

    public static func setThinkingLevel(id: String? = nil, level: PiThinkingLevel) -> PiRPCCommand {
        PiRPCCommand(id: id, type: "set_thinking_level", arguments: ["level": .string(level.rawValue)])
    }

    public static func setSessionName(id: String? = nil, name: String) -> PiRPCCommand {
        PiRPCCommand(id: id, type: "set_session_name", arguments: ["name": .string(name)])
    }

    public static func bash(id: String? = nil, command: String) -> PiRPCCommand {
        PiRPCCommand(id: id, type: "bash", arguments: ["command": .string(command)])
    }

    public static func abortBash(id: String? = nil) -> PiRPCCommand {
        PiRPCCommand(id: id, type: "abort_bash")
    }

    public static func compact(id: String? = nil, prompt: String? = nil) -> PiRPCCommand {
        var arguments: [String: JSONValue] = [:]
        if let prompt { arguments["prompt"] = .string(prompt) }
        return PiRPCCommand(id: id, type: "compact", arguments: arguments)
    }

    public static func newSession(id: String? = nil) -> PiRPCCommand {
        PiRPCCommand(id: id, type: "new_session")
    }

    public static func switchSession(id: String? = nil, sessionFile: String) -> PiRPCCommand {
        PiRPCCommand(id: id, type: "switch_session", arguments: ["session": .string(sessionFile)])
    }
}

/// A base64 image attachment, in the `ImageContent` shape pi expects.
public struct PiImageContent: Sendable, Hashable {
    public let base64Data: String
    public let mimeType: String

    public init(base64Data: String, mimeType: String) {
        self.base64Data = base64Data
        self.mimeType = mimeType
    }

    var jsonValue: JSONValue {
        .object([
            "type": .string("image"),
            "data": .string(base64Data),
            "mimeType": .string(mimeType),
        ])
    }
}

// MARK: - Incoming records

/// One decoded record from pi's stdout: either a reply to a command, or an
/// asynchronous event. Responses always carry `type: "response"`; events never
/// carry an `id`.
public enum PiRPCIncoming: Sendable {
    case response(PiRPCResponse)
    case event(PiRPCEvent)

    public init(json: JSONValue) throws {
        guard let type = json["type"]?.stringValue else {
            throw PiRPCError.malformedRecord(reason: "record has no \"type\"")
        }
        if type == "response" {
            self = .response(PiRPCResponse(json: json))
        } else {
            self = .event(PiRPCEvent(type: type, payload: json))
        }
    }
}

public struct PiRPCResponse: Sendable {
    public let id: String?
    public let command: String
    public let success: Bool
    public let error: String?
    public let data: JSONValue?

    init(json: JSONValue) {
        id = json["id"]?.stringValue
        command = json["command"]?.stringValue ?? ""
        success = json["success"]?.boolValue ?? false
        error = json["error"]?.stringValue
        data = json["data"]
    }
}

/// An asynchronous event from the agent run.
///
/// `kind` covers the event types this app renders; anything pi adds later still
/// arrives intact as `.other` with its full `payload`, so an upstream addition
/// degrades to "not displayed" rather than "dropped connection".
public struct PiRPCEvent: Sendable {
    public let type: String
    public let payload: JSONValue

    public init(type: String, payload: JSONValue) {
        self.type = type
        self.payload = payload
    }

    public enum Kind: Sendable, Equatable {
        case agentStart
        case agentEnd
        case agentSettled
        case turnStart
        case turnEnd
        case messageStart
        case messageUpdate
        case messageEnd
        case toolExecutionStart
        case toolExecutionUpdate
        case toolExecutionEnd
        case queueUpdate
        case compactionStart
        case compactionEnd
        case autoRetryStart
        case autoRetryEnd
        case extensionError
        case sessionInfoChanged
        case other(String)
    }

    public var kind: Kind {
        switch type {
        case "agent_start": return .agentStart
        case "agent_end": return .agentEnd
        case "agent_settled": return .agentSettled
        case "turn_start": return .turnStart
        case "turn_end": return .turnEnd
        case "message_start": return .messageStart
        case "message_update": return .messageUpdate
        case "message_end": return .messageEnd
        case "tool_execution_start": return .toolExecutionStart
        case "tool_execution_update": return .toolExecutionUpdate
        case "tool_execution_end": return .toolExecutionEnd
        case "queue_update": return .queueUpdate
        case "compaction_start": return .compactionStart
        case "compaction_end": return .compactionEnd
        case "auto_retry_start": return .autoRetryStart
        case "auto_retry_end": return .autoRetryEnd
        case "extension_error": return .extensionError
        case "session_info_changed": return .sessionInfoChanged
        default: return .other(type)
        }
    }

    // Convenience accessors for the fields the timeline consumes.
    public var toolCallId: String? { payload["toolCallId"]?.stringValue }
    public var toolName: String? { payload["toolName"]?.stringValue }
    public var message: JSONValue? { payload["message"] }
    public var assistantMessageEvent: JSONValue? { payload["assistantMessageEvent"] }

    /// The text delta of a `message_update` carrying `text_delta`, if any.
    public var textDelta: String? {
        guard let event = assistantMessageEvent,
              event["type"]?.stringValue == "text_delta" else { return nil }
        return event["delta"]?.stringValue
    }

    /// The thinking delta of a `message_update` carrying `thinking_delta`, if any.
    public var thinkingDelta: String? {
        guard let event = assistantMessageEvent,
              event["type"]?.stringValue == "thinking_delta" else { return nil }
        return event["delta"]?.stringValue
    }
}

// MARK: - Errors

public enum PiRPCError: Error, CustomStringConvertible, Sendable {
    case executableNotFound(searched: [String])
    case launchFailed(reason: String)
    case notRunning
    case malformedRecord(reason: String)
    case commandFailed(command: String, message: String)
    case terminated(exitCode: Int32, stderr: String)

    public var description: String {
        switch self {
        case let .executableNotFound(searched):
            return "Could not find the `pi` executable. Searched: \(searched.joined(separator: ", "))"
        case let .launchFailed(reason):
            return "Failed to launch pi: \(reason)"
        case .notRunning:
            return "The pi process is not running"
        case let .malformedRecord(reason):
            return "Malformed record from pi: \(reason)"
        case let .commandFailed(command, message):
            return "pi rejected `\(command)`: \(message)"
        case let .terminated(exitCode, stderr):
            let detail = stderr.isEmpty ? "" : " — \(stderr)"
            return "pi exited with code \(exitCode)\(detail)"
        }
    }
}
