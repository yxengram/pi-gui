import Foundation

/// The header line of a session file (the first record). It carries metadata only
/// and, unlike every other record, is not a node in the entry tree.
public struct SessionHeader: Sendable, Hashable {
    public let version: Int
    public let id: String
    public let timestamp: Date?
    public let cwd: String
    /// Set when this session was produced by `/fork` or `/clone`.
    public let parentSession: String?

    public init(version: Int, id: String, timestamp: Date?, cwd: String, parentSession: String?) {
        self.version = version
        self.id = id
        self.timestamp = timestamp
        self.cwd = cwd
        self.parentSession = parentSession
    }
}

/// One node in a session's entry tree.
///
/// Entries link through `id`/`parentId`, which is how pi represents branching without
/// writing a new file. `payload` keeps the entry's own fields as pi wrote them, so
/// round-tripping never loses data this app does not model.
public struct SessionEntry: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case message
        case modelChange
        case thinkingLevelChange
        case compaction
        case branchSummary
        case custom
        case customMessage
        case label
        case sessionInfo
        case unknown(String)

        init(rawValue: String) {
            switch rawValue {
            case "message": self = .message
            case "model_change": self = .modelChange
            case "thinking_level_change": self = .thinkingLevelChange
            case "compaction": self = .compaction
            case "branch_summary": self = .branchSummary
            case "custom": self = .custom
            case "custom_message": self = .customMessage
            case "label": self = .label
            case "session_info": self = .sessionInfo
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .message: return "message"
            case .modelChange: return "model_change"
            case .thinkingLevelChange: return "thinking_level_change"
            case .compaction: return "compaction"
            case .branchSummary: return "branch_summary"
            case .custom: return "custom"
            case .customMessage: return "custom_message"
            case .label: return "label"
            case .sessionInfo: return "session_info"
            case let .unknown(value): return value
            }
        }
    }

    public let id: String
    public let parentID: String?
    public let kind: Kind
    public let timestamp: Date?
    public let payload: JSONValue

    public init(id: String, parentID: String?, kind: Kind, timestamp: Date?, payload: JSONValue) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.timestamp = timestamp
        self.payload = payload
    }

    /// The `AgentMessage` of a `message` entry.
    public var message: JSONValue? { payload["message"] }

    /// `user`, `assistant`, `toolResult`, `bashExecution`, `custom`, … for message entries.
    public var messageRole: String? { message?["role"]?.stringValue }

    /// Display name from a `session_info` entry.
    public var sessionName: String? { payload["name"]?.stringValue }

    /// Summary text of a `compaction` or `branch_summary` entry.
    public var summary: String? { payload["summary"]?.stringValue }
}

/// One parsed session file: its header plus every entry, in file order.
public struct SessionFile: Sendable {
    public let url: URL
    public let header: SessionHeader?
    public let entries: [SessionEntry]

    public init(url: URL, header: SessionHeader?, entries: [SessionEntry]) {
        self.url = url
        self.header = header
        self.entries = entries
    }

    /// The display name set by `/name`, i.e. the most recent `session_info` entry.
    public var displayName: String? {
        entries.last(where: { $0.kind == .sessionInfo })?.sessionName
    }

    public var sessionID: String? { header?.id }
    public var workingDirectory: String? { header?.cwd }
}

// MARK: - Parsing

public enum SessionParser {
    /// Parses JSONL session bytes.
    ///
    /// Unparsable or unknown lines are skipped rather than failing the file: a session
    /// being appended to by a live pi process can be read mid-write, and a session
    /// written by a newer pi may carry entry types this build predates. Losing the
    /// tail of a transcript is far better than showing the user nothing.
    public static func parse(data: Data, url: URL) -> SessionFile {
        var header: SessionHeader?
        var entries: [SessionEntry] = []

        var framer = JSONLFramer()
        var records = (try? framer.append(data)) ?? []
        if let trailing = framer.flush() {
            records.append(trailing)
        }

        let decoder = JSONDecoder()
        for record in records {
            guard let value = try? decoder.decode(JSONValue.self, from: record),
                  let type = value["type"]?.stringValue else { continue }

            if type == "session" {
                header = SessionHeader(
                    version: value["version"]?.intValue ?? 1,
                    id: value["id"]?.stringValue ?? "",
                    timestamp: value["timestamp"]?.stringValue.flatMap(SessionTimestamp.parse),
                    cwd: value["cwd"]?.stringValue ?? "",
                    parentSession: value["parentSession"]?.stringValue
                )
                continue
            }

            guard let id = value["id"]?.stringValue else { continue }
            entries.append(
                SessionEntry(
                    id: id,
                    parentID: value["parentId"]?.stringValue,
                    kind: SessionEntry.Kind(rawValue: type),
                    timestamp: value["timestamp"]?.stringValue.flatMap(SessionTimestamp.parse),
                    payload: value
                )
            )
        }

        return SessionFile(url: url, header: header, entries: entries)
    }

    public static func parse(contentsOf url: URL) throws -> SessionFile {
        parse(data: try Data(contentsOf: url), url: url)
    }
}

public enum SessionTimestamp {
    /// pi writes ISO-8601 with fractional seconds; older files may omit them.
    public static func parse(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
