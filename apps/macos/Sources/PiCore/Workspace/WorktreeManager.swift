import Foundation

/// A git worktree backing one thread.
public struct Worktree: Sendable, Hashable, Identifiable {
    public let path: URL
    public let branch: String?
    public let head: String?
    /// True for the repository's own working copy, which must never be removed.
    public let isPrimary: Bool

    public var id: String { path.path }

    public init(path: URL, branch: String?, head: String?, isPrimary: Bool) {
        self.path = path
        self.branch = branch
        self.head = head
        self.isPrimary = isPrimary
    }
}

/// Creates and removes the per-thread git worktrees that let parallel threads work
/// on the same repository without colliding.
///
/// Worktrees live outside the repository, under the app's own support directory, so
/// a thread's checkout never shows up as clutter inside the user's project.
public struct WorktreeManager: Sendable {
    private let git: GitCommand
    /// Root that holds every worktree this app creates.
    public let worktreeRoot: URL
    private let fileManager: FileManager

    public init(git: GitCommand, worktreeRoot: URL, fileManager: FileManager = .default) {
        self.git = git
        self.worktreeRoot = worktreeRoot
        self.fileManager = fileManager
    }

    public enum Failure: Error, CustomStringConvertible {
        case notARepository(URL)
        case refusingToRemovePrimary(URL)
        case pathOutsideWorktreeRoot(URL)

        public var description: String {
            switch self {
            case let .notARepository(url):
                return "\(url.path) is not a git repository"
            case let .refusingToRemovePrimary(url):
                return "Refusing to remove \(url.path): it is the repository's main working copy"
            case let .pathOutsideWorktreeRoot(url):
                return "Refusing to remove \(url.path): it is outside the app's worktree directory"
            }
        }
    }

    /// Turns a thread title into a filesystem- and git-safe slug.
    public static func slug(for title: String, fallback: String) -> String {
        let allowed = title.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let trimmed = String(collapsed.prefix(40))
        return trimmed.isEmpty ? fallback : trimmed
    }

    public func listWorktrees(repository: URL) throws -> [Worktree] {
        let result = try git.run(["worktree", "list", "--porcelain"], in: repository)
        guard result.succeeded else { return [] }
        return Self.parseWorktreeList(result.standardOutput)
    }

    /// Parses `git worktree list --porcelain`: blank-line separated records, each
    /// starting with `worktree <path>`. The first record is the primary checkout.
    static func parseWorktreeList(_ output: String) -> [Worktree] {
        var worktrees: [Worktree] = []
        var path: URL?
        var branch: String?
        var head: String?

        func flush() {
            guard let path else { return }
            worktrees.append(Worktree(
                path: path,
                branch: branch,
                head: head,
                isPrimary: worktrees.isEmpty
            ))
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                flush()
                path = nil; branch = nil; head = nil
                continue
            }
            if line.hasPrefix("worktree ") {
                path = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("branch ") {
                // Reported as a full ref; the short name is what the UI shows.
                let ref = String(line.dropFirst("branch ".count))
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            }
        }
        flush()
        return worktrees
    }

    /// Creates a worktree on a new branch for a thread.
    ///
    /// - Parameters:
    ///   - repository: any directory inside the target repository.
    ///   - threadID: stable id used to keep the directory unique across threads with
    ///     the same title.
    public func createWorktree(repository: URL, threadID: String, title: String) throws -> Worktree {
        guard let root = try git.repositoryRoot(repository) else {
            throw Failure.notARepository(repository)
        }

        let shortID = String(threadID.replacingOccurrences(of: "-", with: "").prefix(8))
        let name = "\(Self.slug(for: title, fallback: "thread"))-\(shortID)"
        let destination = worktreeRoot.appendingPathComponent(name)

        try fileManager.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)

        // `-b` fails if the branch already exists, which is exactly right: silently
        // reusing someone else's branch would put two threads on one ref.
        try git.require(["worktree", "add", "-b", name, destination.path], in: root)

        return Worktree(path: destination, branch: name, head: nil, isPrimary: false)
    }

    /// Removes a worktree created by this app.
    ///
    /// Refuses to touch the primary checkout or anything outside the app's worktree
    /// root — a wrong path here would delete a user's actual project.
    public func removeWorktree(repository: URL, worktree: Worktree, force: Bool = false) throws {
        guard !worktree.isPrimary else {
            throw Failure.refusingToRemovePrimary(worktree.path)
        }
        let root = worktreeRoot.standardizedFileURL.path
        let target = worktree.path.standardizedFileURL.path
        guard target.hasPrefix(root + "/") else {
            throw Failure.pathOutsideWorktreeRoot(worktree.path)
        }
        guard let repositoryRoot = try git.repositoryRoot(repository) else {
            throw Failure.notARepository(repository)
        }

        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(worktree.path.path)
        try git.require(arguments, in: repositoryRoot)
    }

    /// Drops git's records of worktrees whose directories are gone.
    public func prune(repository: URL) throws {
        guard let root = try git.repositoryRoot(repository) else { return }
        try git.run(["worktree", "prune"], in: root)
    }
}
