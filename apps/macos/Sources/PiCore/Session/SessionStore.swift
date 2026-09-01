import Foundation

/// Discovers and reads the session files pi writes.
///
/// pi's JSONL files are the source of truth for transcripts. This app keeps no
/// parallel copy of a conversation: it reads what pi wrote, which is what lets a
/// session opened in the GUI and the same session opened in `pi` on the terminal
/// agree with each other.
public struct SessionStore: Sendable {
    /// Root of pi's agent data, `~/.pi/agent` by default.
    public let agentDirectory: URL
    private let fileManager: FileManager

    public init(
        agentDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.agentDirectory = agentDirectory
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".pi")
                .appendingPathComponent("agent")
        self.fileManager = fileManager
    }

    public var sessionsDirectory: URL {
        agentDirectory.appendingPathComponent("sessions")
    }

    /// Encodes a working directory into pi's per-project session directory name.
    ///
    /// Mirrors pi's own `getDefaultSessionDirPath`: drop the leading separator, then
    /// replace `/`, `\` and `:` with `-`, wrapped in double dashes. Getting this wrong
    /// means the GUI silently shows an empty thread list for a real project, so it is
    /// covered by tests.
    public static func encodedDirectoryName(forWorkingDirectory path: String) -> String {
        let resolved = (path as NSString).standardizingPath
        var trimmed = Substring(resolved)
        if let first = trimmed.first, first == "/" || first == "\\" {
            trimmed = trimmed.dropFirst()
        }
        let replaced = String(trimmed).map { character -> Character in
            (character == "/" || character == "\\" || character == ":") ? "-" : character
        }
        return "--" + String(replaced) + "--"
    }

    public func sessionDirectory(forWorkingDirectory path: String) -> URL {
        sessionsDirectory.appendingPathComponent(
            Self.encodedDirectoryName(forWorkingDirectory: path)
        )
    }

    /// A session file plus the metadata the sidebar needs, without holding the
    /// whole transcript in memory.
    public struct Summary: Sendable, Identifiable, Hashable {
        public let url: URL
        public let sessionID: String
        public let displayName: String?
        public let workingDirectory: String?
        public let modifiedAt: Date
        public let messageCount: Int
        /// First user message, used as the sidebar preview when unnamed.
        public let preview: String?

        public var id: String { url.path }

        /// What the sidebar shows: the explicit name, else the first prompt, else the file's date.
        public var title: String {
            if let displayName, !displayName.isEmpty { return displayName }
            if let preview, !preview.isEmpty { return preview }
            return "Untitled thread"
        }
    }

    /// Lists the sessions belonging to a working directory, newest first.
    public func listSessions(forWorkingDirectory path: String) throws -> [Summary] {
        let directory = sessionDirectory(forWorkingDirectory: path)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }

        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let summaries = contents
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { summarize(url: $0) }

        return summaries.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Reads one session file into a summary, or `nil` if it cannot be read.
    public func summarize(url: URL) -> Summary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let file = SessionParser.parse(data: data, url: url)

        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? file.header?.timestamp ?? .distantPast

        let messages = file.entries.filter { $0.kind == .message }
        let preview = messages
            .first { $0.messageRole == "user" }
            .flatMap { AgentMessageText.plainText(from: $0.message) }

        return Summary(
            url: url,
            sessionID: file.sessionID ?? url.deletingPathExtension().lastPathComponent,
            displayName: file.displayName,
            workingDirectory: file.workingDirectory,
            modifiedAt: modifiedAt,
            messageCount: messages.count,
            preview: preview.map { $0.singleLinePreview(limit: 140) }
        )
    }

    public func loadSession(at url: URL) throws -> SessionFile {
        try SessionParser.parse(contentsOf: url)
    }
}

extension String {
    /// Collapses whitespace to one line and truncates, for sidebar previews.
    func singleLinePreview(limit: Int) -> String {
        let collapsed = split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return collapsed.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}
