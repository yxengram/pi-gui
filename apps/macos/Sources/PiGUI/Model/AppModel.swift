import Foundation
import PiCore

/// A project folder the user has opened.
public struct Workspace: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var path: String
    public var name: String

    public init(id: UUID = UUID(), path: String, name: String? = nil) {
        self.id = id
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

/// How a new thread gets its working directory.
public enum ThreadLocation: String, CaseIterable, Identifiable, Sendable {
    /// Run directly in the workspace folder.
    case local
    /// Run in a dedicated git worktree so parallel threads never collide.
    case worktree

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .local: return "Local"
        case .worktree: return "Worktree"
        }
    }

    public var explanation: String {
        switch self {
        case .local: return "Runs in the workspace folder itself."
        case .worktree: return "Runs in a separate git worktree, so parallel threads don't collide."
        }
    }
}

/// Top-level app state: workspaces, their threads, and the current selection.
///
/// Threads are backed by pi's own session files. This model discovers them rather
/// than keeping its own database, which is what lets a session started in the
/// terminal show up here and vice versa.
@MainActor
public final class AppModel: ObservableObject {
    @Published public var workspaces: [Workspace] = []
    @Published public var selectedWorkspaceID: Workspace.ID?
    @Published public var threads: [SessionStore.Summary] = []
    @Published public var selectedThreadPath: String?
    @Published public var activeSession: ThreadSession?
    @Published public var startupError: String?
    @Published public var isLoadingThreads = false

    /// Session files archived by the user, hidden from the thread list.
    @Published public var archivedThreadPaths: Set<String> = []

    private let sessionStore: SessionStore
    private let preferences: Preferences
    private var git: GitCommand?

    public init(
        sessionStore: SessionStore = SessionStore(),
        preferences: Preferences = .shared
    ) {
        self.sessionStore = sessionStore
        self.preferences = preferences
        git = try? GitCommand()
        workspaces = preferences.workspaces
        archivedThreadPaths = preferences.archivedThreadPaths
        selectedWorkspaceID = workspaces.first?.id
    }

    public var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    /// Threads shown in the sidebar: everything discovered, minus archived ones.
    public var visibleThreads: [SessionStore.Summary] {
        threads.filter { !archivedThreadPaths.contains($0.url.path) }
    }

    // MARK: - Workspaces

    public func addWorkspace(path: String) {
        let standardized = (path as NSString).standardizingPath
        guard !workspaces.contains(where: { $0.path == standardized }) else {
            selectedWorkspaceID = workspaces.first { $0.path == standardized }?.id
            return
        }
        let workspace = Workspace(path: standardized)
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        preferences.workspaces = workspaces
        Task { await reloadThreads() }
    }

    public func removeWorkspace(_ workspace: Workspace) {
        workspaces.removeAll { $0.id == workspace.id }
        preferences.workspaces = workspaces
        if selectedWorkspaceID == workspace.id {
            selectedWorkspaceID = workspaces.first?.id
            Task { await reloadThreads() }
        }
    }

    public func selectWorkspace(_ workspace: Workspace) {
        guard selectedWorkspaceID != workspace.id else { return }
        selectedWorkspaceID = workspace.id
        selectedThreadPath = nil
        Task {
            await closeActiveSession()
            await reloadThreads()
        }
    }

    // MARK: - Threads

    /// Rescans pi's session directory for the selected workspace.
    public func reloadThreads() async {
        guard let workspace = selectedWorkspace else {
            threads = []
            return
        }
        isLoadingThreads = true
        defer { isLoadingThreads = false }

        // pi files sessions by the directory the agent ran in, so a thread started in
        // a worktree lives under that worktree's directory, not the workspace's.
        // Scanning only the workspace would make worktree threads disappear from the
        // sidebar on relaunch.
        let directories = [workspace.path] + worktreeDirectories(for: workspace)
        let store = sessionStore

        // Reading and parsing every session file is I/O plus JSON work; keeping it
        // off the main actor stops the sidebar from stuttering on a large history.
        let found = await Task.detached { () -> [SessionStore.Summary] in
            var seen = Set<String>()
            var summaries: [SessionStore.Summary] = []
            for directory in directories {
                for summary in (try? store.listSessions(forWorkingDirectory: directory)) ?? [] {
                    guard seen.insert(summary.url.path).inserted else { continue }
                    summaries.append(summary)
                }
            }
            return summaries.sorted { $0.modifiedAt > $1.modifiedAt }
        }.value
        threads = found
    }

    /// Worktrees of the workspace's repository that this app created.
    private func worktreeDirectories(for workspace: Workspace) -> [String] {
        guard let git, git.isRepository(workspace.url) else { return [] }
        let manager = WorktreeManager(git: git, worktreeRoot: preferences.worktreeRoot)
        let worktrees = (try? manager.listWorktrees(repository: workspace.url)) ?? []
        return worktrees.filter { !$0.isPrimary }.map(\.path.path)
    }

    public func openThread(_ summary: SessionStore.Summary) async {
        guard let workspace = selectedWorkspace else { return }
        await closeActiveSession()

        selectedThreadPath = summary.url.path

        // Resume in the directory the session was recorded against. pi refuses to
        // resume a session whose stored cwd is missing, and a worktree thread's cwd
        // is the worktree — not the workspace.
        let runDirectory = summary.workingDirectory.map(URL.init(fileURLWithPath:)) ?? workspace.url
        let worktree = worktreeForDirectory(runDirectory, workspace: workspace)

        let session = ThreadSession(
            id: summary.sessionID,
            title: summary.title,
            workingDirectory: runDirectory,
            worktree: worktree,
            configuration: PiRPCClient.Configuration(
                workingDirectory: runDirectory,
                sessionFile: summary.url,
                executableOverride: preferences.piExecutablePath
            )
        )
        activeSession = session
        await session.start()
        await session.refreshState()
        propagateStartupFailure(from: session)
    }

    /// Starts a new thread, optionally in a fresh git worktree.
    public func createThread(title: String, location: ThreadLocation) async {
        guard let workspace = selectedWorkspace else { return }
        await closeActiveSession()
        startupError = nil

        let threadID = UUID().uuidString
        var runDirectory = workspace.url
        var worktree: Worktree?

        if location == .worktree {
            do {
                worktree = try makeWorktree(for: workspace, threadID: threadID, title: title)
                if let worktree { runDirectory = worktree.path }
            } catch {
                startupError = "Couldn't create a worktree: \(error)"
                return
            }
        }

        let session = ThreadSession(
            id: threadID,
            title: title,
            workingDirectory: runDirectory,
            worktree: worktree,
            configuration: PiRPCClient.Configuration(
                workingDirectory: runDirectory,
                sessionName: title,
                executableOverride: preferences.piExecutablePath
            )
        )
        activeSession = session
        selectedThreadPath = nil
        await session.start()
        await session.refreshState()
        propagateStartupFailure(from: session)
        await reloadThreads()
    }

    /// The worktree a directory corresponds to, so a reopened thread still shows its
    /// branch in the header.
    private func worktreeForDirectory(_ directory: URL, workspace: Workspace) -> Worktree? {
        guard let git, git.isRepository(workspace.url) else { return nil }
        let manager = WorktreeManager(git: git, worktreeRoot: preferences.worktreeRoot)
        let worktrees = (try? manager.listWorktrees(repository: workspace.url)) ?? []
        let target = directory.standardizedFileURL.path
        return worktrees.first { !$0.isPrimary && $0.path.standardizedFileURL.path == target }
    }

    private func makeWorktree(for workspace: Workspace, threadID: String, title: String) throws -> Worktree {
        guard let git else { throw GitCommand.Failure.gitUnavailable }
        guard git.isRepository(workspace.url) else {
            throw WorktreeManager.Failure.notARepository(workspace.url)
        }
        let manager = WorktreeManager(git: git, worktreeRoot: preferences.worktreeRoot)
        return try manager.createWorktree(repository: workspace.url, threadID: threadID, title: title)
    }

    private func propagateStartupFailure(from session: ThreadSession) {
        if case let .failed(message) = session.runState {
            startupError = message
        }
    }

    public func closeActiveSession() async {
        guard let session = activeSession else { return }
        await session.shutdown()
        activeSession = nil
    }

    /// Hides a thread from the sidebar. The session file itself is left untouched —
    /// archiving is a view preference, not a deletion.
    public func archiveThread(_ summary: SessionStore.Summary) {
        archivedThreadPaths.insert(summary.url.path)
        preferences.archivedThreadPaths = archivedThreadPaths
        if selectedThreadPath == summary.url.path {
            selectedThreadPath = nil
            Task { await closeActiveSession() }
        }
    }

    public func unarchiveThread(path: String) {
        archivedThreadPaths.remove(path)
        preferences.archivedThreadPaths = archivedThreadPaths
    }

    // MARK: - Changed files

    /// Changed files for the directory the active thread runs in.
    public func changedFiles() async -> [ChangedFile] {
        guard let git, let directory = activeSession?.workingDirectory ?? selectedWorkspace?.url else { return [] }
        return await Task.detached { () -> [ChangedFile] in
            (try? git.changedFiles(in: directory)) ?? []
        }.value
    }

    public func diff(for file: ChangedFile) async -> UnifiedDiff {
        guard let git, let directory = activeSession?.workingDirectory ?? selectedWorkspace?.url else {
            return UnifiedDiff(lines: [])
        }
        let text = await Task.detached { () -> String in
            (try? git.diff(forFile: file.path, in: directory, isUntracked: file.status == .untracked)) ?? ""
        }.value
        return UnifiedDiff.parse(text)
    }
}
