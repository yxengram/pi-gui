import Foundation

/// A file changed relative to HEAD, for the diff panel's changed-files list.
public struct ChangedFile: Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable {
        case added, modified, deleted, renamed, copied, untracked, conflicted, typeChanged, unknown(String)

        /// Maps a porcelain status letter. `X` and `Y` are the index and worktree
        /// columns; either may carry the interesting state.
        static func from(code: Character) -> Status {
            switch code {
            case "A": return .added
            case "M": return .modified
            case "D": return .deleted
            case "R": return .renamed
            case "C": return .copied
            case "T": return .typeChanged
            case "U": return .conflicted
            case "?": return .untracked
            default: return .unknown(String(code))
            }
        }

        public var label: String {
            switch self {
            case .added: return "Added"
            case .modified: return "Modified"
            case .deleted: return "Deleted"
            case .renamed: return "Renamed"
            case .copied: return "Copied"
            case .untracked: return "Untracked"
            case .conflicted: return "Conflicted"
            case .typeChanged: return "Type changed"
            case let .unknown(code): return code
            }
        }
    }

    /// Repo-relative path.
    public let path: String
    public let status: Status
    public let isStaged: Bool
    /// Previous path for a rename or copy.
    public let originalPath: String?

    public var id: String { path }

    public init(path: String, status: Status, isStaged: Bool, originalPath: String? = nil) {
        self.path = path
        self.status = status
        self.isStaged = isStaged
        self.originalPath = originalPath
    }

    public var fileName: String { (path as NSString).lastPathComponent }
    public var directory: String { (path as NSString).deletingLastPathComponent }
}

extension GitCommand {
    /// Lists changed files using `status --porcelain=v1 -z`.
    ///
    /// The NUL-separated form is what makes this correct for paths containing
    /// spaces, quotes or newlines — the newline-delimited form quotes and escapes
    /// such paths, and parsing that back is a guessing game.
    public func changedFiles(in directory: URL) throws -> [ChangedFile] {
        let result = try run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: directory)
        guard result.succeeded else { return [] }
        return Self.parsePorcelainZ(result.standardOutput)
    }

    static func parsePorcelainZ(_ output: String) -> [ChangedFile] {
        // Records are NUL-terminated: "XY <path>\0", and a rename/copy is followed by
        // an extra "<original>\0" record that belongs to the entry before it.
        var fields = output.components(separatedBy: "\0")
        if fields.last?.isEmpty == true { fields.removeLast() }

        var files: [ChangedFile] = []
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard field.count >= 3 else { continue }

            let characters = Array(field)
            let indexCode = characters[0]
            let worktreeCode = characters[1]
            let path = String(characters[3...])

            var originalPath: String?
            if indexCode == "R" || indexCode == "C" || worktreeCode == "R" || worktreeCode == "C" {
                if index < fields.count {
                    originalPath = fields[index]
                    index += 1
                }
            }

            let isStaged = indexCode != " " && indexCode != "?"
            // The worktree column describes unstaged state and is the one the user is
            // usually reviewing; fall back to the index column when it is clean.
            let effectiveCode = worktreeCode != " " ? worktreeCode : indexCode

            files.append(ChangedFile(
                path: path,
                status: ChangedFile.Status.from(code: effectiveCode),
                isStaged: isStaged,
                originalPath: originalPath
            ))
        }
        return files
    }

    /// Unified diff for one file. Untracked files have no diff against HEAD, so they
    /// are shown via `--no-index` against /dev/null to render as an all-added file.
    public func diff(forFile path: String, in directory: URL, isUntracked: Bool) throws -> String {
        if isUntracked {
            let result = try run(["diff", "--no-index", "--", "/dev/null", path], in: directory)
            // `--no-index` exits 1 when files differ, which is the normal case here.
            return result.standardOutput
        }
        let result = try run(["diff", "HEAD", "--", path], in: directory)
        guard result.succeeded else { return "" }
        return result.standardOutput
    }
}

// MARK: - Unified diff parsing

/// A parsed unified diff, for rendering with per-line gutters.
public struct UnifiedDiff: Sendable, Hashable {
    public struct Line: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable {
            case context, addition, deletion, hunkHeader, fileHeader
        }

        public let id: Int
        public let kind: Kind
        public let text: String
        public let oldLineNumber: Int?
        public let newLineNumber: Int?

        public init(id: Int, kind: Kind, text: String, oldLineNumber: Int?, newLineNumber: Int?) {
            self.id = id
            self.kind = kind
            self.text = text
            self.oldLineNumber = oldLineNumber
            self.newLineNumber = newLineNumber
        }
    }

    public let lines: [Line]
    public var additions: Int { lines.filter { $0.kind == .addition }.count }
    public var deletions: Int { lines.filter { $0.kind == .deletion }.count }

    public init(lines: [Line]) {
        self.lines = lines
    }

    /// Parses unified diff text, tracking line numbers from each hunk header so the
    /// gutter shows real file positions rather than an offset within the diff.
    public static func parse(_ text: String) -> UnifiedDiff {
        var lines: [Line] = []
        var oldLine = 0
        var newLine = 0
        var identifier = 0

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            defer { identifier += 1 }

            if line.hasPrefix("@@") {
                let numbers = parseHunkHeader(line)
                oldLine = numbers.old
                newLine = numbers.new
                lines.append(Line(id: identifier, kind: .hunkHeader, text: line, oldLineNumber: nil, newLineNumber: nil))
            } else if line.hasPrefix("diff ") || line.hasPrefix("index ")
                        || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                        || line.hasPrefix("new file") || line.hasPrefix("deleted file")
                        || line.hasPrefix("similarity index") || line.hasPrefix("rename ") {
                lines.append(Line(id: identifier, kind: .fileHeader, text: line, oldLineNumber: nil, newLineNumber: nil))
            } else if line.hasPrefix("+") {
                lines.append(Line(id: identifier, kind: .addition, text: String(line.dropFirst()), oldLineNumber: nil, newLineNumber: newLine))
                newLine += 1
            } else if line.hasPrefix("-") {
                lines.append(Line(id: identifier, kind: .deletion, text: String(line.dropFirst()), oldLineNumber: oldLine, newLineNumber: nil))
                oldLine += 1
            } else if line.hasPrefix("\\") {
                // "\ No newline at end of file" — a marker, not content.
                lines.append(Line(id: identifier, kind: .fileHeader, text: line, oldLineNumber: nil, newLineNumber: nil))
            } else {
                let content = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                lines.append(Line(id: identifier, kind: .context, text: content, oldLineNumber: oldLine, newLineNumber: newLine))
                oldLine += 1
                newLine += 1
            }
        }

        return UnifiedDiff(lines: lines)
    }

    /// Reads the starting line numbers out of `@@ -a,b +c,d @@`.
    static func parseHunkHeader(_ header: String) -> (old: Int, new: Int) {
        var old = 0
        var new = 0
        for token in header.split(separator: " ") {
            guard token.count > 1 else { continue }
            let digits = token.dropFirst().prefix { $0.isNumber }
            guard let value = Int(digits) else { continue }
            if token.hasPrefix("-") { old = value }
            if token.hasPrefix("+") { new = value }
        }
        return (old, new)
    }
}
